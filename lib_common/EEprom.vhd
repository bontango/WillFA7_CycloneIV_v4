--
-- EEprom.vhd — clean-room rewrite, drop-in compatible with v097
--
-- Mirrors a 256-byte CMOS region between FPGA dual-port RAM (R5101 port B)
-- and an external SPI EEPROM (M95256 / M95512).
--
-- Behavior preserved bit-for-bit vs. v097:
--   * boot read 0x00..0xFF → R5101 + shadow cache
--   * idle until edge on w_trigger, then 1us glitch check + 1s pre-write
--   * shadow-cache scan: write only bytes where shadow /= q_ram
--   * per-byte: WREN → WRITE → poll RDSR until WIP=0 → READ → compare
--   * delayed re-verify: 100 ms wait, READ again; only second match commits
--   * up to 2 retries on mismatch, latch error, drive 1 Hz blink output
--
-- Structure changed (best-practice rewrite):
--   * generics for all timings + clock rates
--   * hierarchical FSM: top-level phase FSM + small SPI transaction sub-FSM
--   * one named SPI helper used by all four SPI_Master instances
--   * named opcode constants instead of bit literals
--   * deduplicated wait_for_Master handshake
--
-- SPI_Master.vhd is unchanged — four instances retained (32/32/16/8 bit Laenge)
-- so M95xxx sees identical frame lengths/shapes.
--

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity EEprom is
    generic (
        CLK_HZ              : integer := 50_000_000;
        SPI_HZ              : integer := 100_000;       -- v094
        INIT_DELAY_CYCLES   : integer := 100_000_000;   -- ~2 s
        PRE_WRITE_CYCLES    : integer := 50_000_000;    -- ~1 s
        GLITCH_CYCLES       : integer := 50;            -- ~1 us
        REVERIFY_CYCLES     : integer := 5_000_000;     -- ~100 ms (v097)
        HOLD_CYCLES         : integer := 1000;          -- wr_ram pulse hold
        SCAN_SETTLE_CYCLES  : integer := 5;             -- R5101 port-B settle
        MAX_RETRY           : integer := 2;             -- per-byte write retries
        BLINK_DIV_CYCLES    : integer := 25_000_000     -- 1 Hz blink (50M/25M)
    );
    port (
        i_Clk            : in    std_logic;
        done             : out   std_logic;
        address_eeprom   : buffer std_logic_vector(7 downto 0);
        data_eeprom      : out   std_logic_vector(7 downto 0);
        q_ram            : in    std_logic_vector(7 downto 0);
        wr_ram           : out   std_logic;
        i_Rst_L          : in    std_logic;
        o_SPI_Clk        : out   std_logic;
        i_SPI_MISO       : in    std_logic;
        o_SPI_MOSI       : out   std_logic;
        o_SPI_CS_n       : out   std_logic;
        selection        : in    std_logic_vector(7 downto 0);
        w_trigger        : in    std_logic_vector(4 downto 0);
        i_init_Flag      : in    std_logic;
        o_wr_in_progress : out   std_logic;
        EEprom_error     : out   std_logic
    );
end EEprom;

architecture Behavioral of EEprom is

    -- ------------------------------------------------------------------
    -- 256x8 single-port BRAM (M9K) for shadow cache
    -- 2-cycle read latency: registered address + registered q
    -- ------------------------------------------------------------------
    component shadow_ram
        port (
            address : in  std_logic_vector(7 downto 0);
            clock   : in  std_logic := '1';
            data    : in  std_logic_vector(7 downto 0);
            wren    : in  std_logic;
            q       : out std_logic_vector(7 downto 0)
        );
    end component;

    -- ------------------------------------------------------------------
    -- M95xxx SPI opcodes
    -- ------------------------------------------------------------------
    constant CMD_READ  : std_logic_vector(7 downto 0) := x"03";
    constant CMD_WRITE : std_logic_vector(7 downto 0) := x"02";
    constant CMD_WREN  : std_logic_vector(7 downto 0) := x"06";
    constant CMD_RDSR  : std_logic_vector(7 downto 0) := x"05";
    constant SR_WIP_BIT : integer := 0;

    -- ------------------------------------------------------------------
    -- Top-level FSM
    -- ------------------------------------------------------------------
    type phase_t is (
        PH_BOOT_CHECK,         -- decide: read or skip
        PH_BOOT_READ,          -- issue READ for current address
        PH_BOOT_LATCH,         -- write rx into RAM + shadow, hold wr_ram
        PH_BOOT_NEXT,          -- next address or finish
        PH_INIT_DELAY,         -- 2 s before accepting triggers
        PH_IDLE,               -- watch for w_trigger edge
        PH_ARMED,              -- 1 us glitch check
        PH_SAVE_PREP,          -- 1 s pre-write delay, clear error/retry
        PH_SCAN_SETTLE,        -- R5101 port-B address settle
        PH_SCAN_COMPARE,       -- shadow vs q_ram → WREN or skip
        PH_WRITE_WREN,         -- send WREN
        PH_WRITE_DATA,         -- send WRITE+addr+data, snapshot verify_byte
        PH_POLL_RDSR,          -- send RDSR
        PH_POLL_CHECK,         -- WIP=0? else loop
        PH_VERIFY_READ,        -- send READ for verify
        PH_VERIFY_CHECK,       -- compare RX vs verify_byte
        PH_REVERIFY_DELAY,     -- 100 ms idle then re-read
        PH_NEXT_BYTE           -- advance address or back to IDLE
    );
    signal phase : phase_t;

    -- ------------------------------------------------------------------
    -- SPI transaction sub-FSM (shared handshake for all four masters)
    -- ------------------------------------------------------------------
    type spi_op_t is (OP_NONE, OP_READ, OP_WRITE, OP_RDSR, OP_WREN);
    type spi_state_t is (SPI_IDLE, SPI_RUNNING, SPI_RELEASE);
    signal spi_state    : spi_state_t;
    signal spi_op       : spi_op_t;
    signal spi_start    : std_logic;     -- top FSM pulses to launch op
    signal spi_done_p   : std_logic;     -- one-cycle pulse when op finished

    -- ------------------------------------------------------------------
    -- Four SPI_Master instances (preserved 32/32/16/8 bit Laenge)
    -- ------------------------------------------------------------------
    signal TX_Data_R    : std_logic_vector(31 downto 0);
    signal RX_Data_R    : std_logic_vector(31 downto 0);
    signal TX_Start_R   : std_logic;
    signal TX_Done_R    : std_logic;
    signal MOSI_R       : std_logic;
    signal SS_R         : std_logic;
    signal SPI_Clk_R    : std_logic;

    signal TX_Data_W    : std_logic_vector(31 downto 0);
    signal RX_Data_W    : std_logic_vector(31 downto 0);
    signal TX_Start_W   : std_logic;
    signal TX_Done_W    : std_logic;
    signal MOSI_W       : std_logic;
    signal SS_W         : std_logic;
    signal SPI_Clk_W    : std_logic;

    signal TX_Data_Stat : std_logic_vector(15 downto 0);
    signal RX_Data_Stat : std_logic_vector(15 downto 0);
    signal TX_Start_Stat: std_logic;
    signal TX_Done_Stat : std_logic;
    signal MOSI_Stat    : std_logic;
    signal SS_Stat      : std_logic;
    signal SPI_Clk_Stat : std_logic;

    signal TX_Data_Cmd  : std_logic_vector(7 downto 0);
    signal RX_Data_Cmd  : std_logic_vector(7 downto 0);
    signal TX_Start_Cmd : std_logic;
    signal TX_Done_Cmd  : std_logic;
    signal MOSI_Cmd     : std_logic;
    signal SS_Cmd       : std_logic;
    signal SPI_Clk_Cmd  : std_logic;

    -- ------------------------------------------------------------------
    -- Working state
    -- ------------------------------------------------------------------
    signal old_w_trigger : std_logic_vector(4 downto 0);
    signal c_count       : integer range 0 to 500_000_000;
    signal scan_cnt      : integer range 0 to 31;

    signal verify_byte   : std_logic_vector(7 downto 0);
    signal byte_retry    : integer range 0 to 7;
    signal reverify_pass : std_logic;          -- '0'=first verify, '1'=second

    signal error_latched : std_logic;
    signal blink_div     : integer range 0 to 25_000_000;
    signal blink_q       : std_logic;

    -- 256-byte shadow cache (external single-port BRAM)
    -- Address driven directly from address_eeprom; 2-cycle read latency.
    signal sh_data       : std_logic_vector(7 downto 0);
    signal sh_wren       : std_logic;
    signal sh_q          : std_logic_vector(7 downto 0);

    signal wr_ram_i      : std_logic;

    -- '1' while we are inside the save sequence (PH_SAVE_PREP..PH_NEXT_BYTE).
    -- Used so the LED can blink during a save (visible "do not power off")
    -- without also blinking during the boot/idle phases.
    signal save_active   : std_logic;

begin

    wr_ram <= wr_ram_i;

    save_active <= '0' when (phase = PH_BOOT_CHECK or phase = PH_BOOT_READ or
                             phase = PH_BOOT_LATCH or phase = PH_BOOT_NEXT or
                             phase = PH_INIT_DELAY or phase = PH_IDLE or
                             phase = PH_ARMED)
                       else '1';

    -- ------------------------------------------------------------------
    -- SPI pin mux: which master currently owns the bus
    -- ------------------------------------------------------------------
    o_SPI_MOSI <=
        MOSI_R    when TX_Start_R    = '1' else
        MOSI_W    when TX_Start_W    = '1' else
        MOSI_Stat when TX_Start_Stat = '1' else
        MOSI_Cmd  when TX_Start_Cmd  = '1' else
        '0';

    o_SPI_Clk <=
        SPI_Clk_R    when TX_Start_R    = '1' else
        SPI_Clk_W    when TX_Start_W    = '1' else
        SPI_Clk_Stat when TX_Start_Stat = '1' else
        SPI_Clk_Cmd  when TX_Start_Cmd  = '1' else
        '0';

    o_SPI_CS_n <=
        SS_R    when TX_Start_R    = '1' else
        SS_W    when TX_Start_W    = '1' else
        SS_Stat when TX_Start_Stat = '1' else
        SS_Cmd  when TX_Start_Cmd  = '1' else
        '1';

    -- Blink at 1 Hz while a save is running OR when an error is latched.
    -- The top-level routes this to LED_active only during o_wr_in_progress='0',
    -- so the LED stays dark during boot and shows display-blanking when idle.
    EEprom_error <= blink_q when (save_active = '1' or error_latched = '1') else '0';

    -- ------------------------------------------------------------------
    -- SPI_Master instances (unchanged interface, same 100 kHz)
    -- ------------------------------------------------------------------
    EEPROM_READ : entity work.SPI_Master
        generic map (SPI_Taktfrequenz => SPI_HZ, Laenge => 32)
        port map (
            TX_Data => TX_Data_R, RX_Data => RX_Data_R,
            MOSI => MOSI_R, MISO => i_SPI_MISO,
            SCLK => SPI_Clk_R, SS => SS_R,
            TX_Start => TX_Start_R, TX_Done => TX_Done_R,
            clk => i_Clk,
            do_not_disable_SS => '0', do_not_enable_SS => '0'
        );

    EEPROM_WRITE : entity work.SPI_Master
        generic map (SPI_Taktfrequenz => SPI_HZ, Laenge => 32)
        port map (
            TX_Data => TX_Data_W, RX_Data => RX_Data_W,
            MOSI => MOSI_W, MISO => i_SPI_MISO,
            SCLK => SPI_Clk_W, SS => SS_W,
            TX_Start => TX_Start_W, TX_Done => TX_Done_W,
            clk => i_Clk,
            do_not_disable_SS => '0', do_not_enable_SS => '0'
        );

    EEPROM_STAT : entity work.SPI_Master
        generic map (SPI_Taktfrequenz => SPI_HZ, Laenge => 16)
        port map (
            TX_Data => TX_Data_Stat, RX_Data => RX_Data_Stat,
            MOSI => MOSI_Stat, MISO => i_SPI_MISO,
            SCLK => SPI_Clk_Stat, SS => SS_Stat,
            TX_Start => TX_Start_Stat, TX_Done => TX_Done_Stat,
            clk => i_Clk,
            do_not_disable_SS => '0', do_not_enable_SS => '0'
        );

    EEPROM_CMD : entity work.SPI_Master
        generic map (SPI_Taktfrequenz => SPI_HZ, Laenge => 8)
        port map (
            TX_Data => TX_Data_Cmd, RX_Data => RX_Data_Cmd,
            MOSI => MOSI_Cmd, MISO => i_SPI_MISO,
            SCLK => SPI_Clk_Cmd, SS => SS_Cmd,
            TX_Start => TX_Start_Cmd, TX_Done => TX_Done_Cmd,
            clk => i_Clk,
            do_not_disable_SS => '0', do_not_enable_SS => '0'
        );

    -- ------------------------------------------------------------------
    -- Shadow cache RAM (M9K block, 256x8, single-port)
    -- ------------------------------------------------------------------
    SHADOW_INST : shadow_ram
        port map (
            address => address_eeprom,
            clock   => i_Clk,
            data    => sh_data,
            wren    => sh_wren,
            q       => sh_q
        );

    -- ------------------------------------------------------------------
    -- SPI sub-FSM: drives the matching TX_Start_* until the master sends
    -- TX_Done='1', then releases TX_Start and waits for TX_Done='0'.
    -- Pulses spi_done_p for one clock when the operation has fully
    -- released the bus, signaling the top FSM to advance.
    -- ------------------------------------------------------------------
    SPI_SUB : process (i_Clk, i_Rst_L)
    begin
        if i_Rst_L = '0' then
            spi_state    <= SPI_IDLE;
            TX_Start_R   <= '0';
            TX_Start_W   <= '0';
            TX_Start_Stat<= '0';
            TX_Start_Cmd <= '0';
            spi_done_p   <= '0';
        elsif rising_edge(i_Clk) then
            spi_done_p <= '0';

            case spi_state is
                when SPI_IDLE =>
                    if spi_start = '1' then
                        case spi_op is
                            when OP_READ  => TX_Start_R    <= '1';
                            when OP_WRITE => TX_Start_W    <= '1';
                            when OP_RDSR  => TX_Start_Stat <= '1';
                            when OP_WREN  => TX_Start_Cmd  <= '1';
                            when others   => null;
                        end case;
                        spi_state <= SPI_RUNNING;
                    end if;

                when SPI_RUNNING =>
                    case spi_op is
                        when OP_READ =>
                            if TX_Done_R = '1' then
                                TX_Start_R <= '0';
                                spi_state  <= SPI_RELEASE;
                            end if;
                        when OP_WRITE =>
                            if TX_Done_W = '1' then
                                TX_Start_W <= '0';
                                spi_state  <= SPI_RELEASE;
                            end if;
                        when OP_RDSR =>
                            if TX_Done_Stat = '1' then
                                TX_Start_Stat <= '0';
                                spi_state     <= SPI_RELEASE;
                            end if;
                        when OP_WREN =>
                            if TX_Done_Cmd = '1' then
                                TX_Start_Cmd <= '0';
                                spi_state    <= SPI_RELEASE;
                            end if;
                        when others =>
                            spi_state <= SPI_IDLE;
                    end case;

                when SPI_RELEASE =>
                    -- wait for master to drop TX_Done before announcing done
                    case spi_op is
                        when OP_READ =>
                            if TX_Done_R = '0' then
                                spi_done_p <= '1';
                                spi_state  <= SPI_IDLE;
                            end if;
                        when OP_WRITE =>
                            if TX_Done_W = '0' then
                                spi_done_p <= '1';
                                spi_state  <= SPI_IDLE;
                            end if;
                        when OP_RDSR =>
                            if TX_Done_Stat = '0' then
                                spi_done_p <= '1';
                                spi_state  <= SPI_IDLE;
                            end if;
                        when OP_WREN =>
                            if TX_Done_Cmd = '0' then
                                spi_done_p <= '1';
                                spi_state  <= SPI_IDLE;
                            end if;
                        when others =>
                            spi_state <= SPI_IDLE;
                    end case;
            end case;
        end if;
    end process;

    -- ------------------------------------------------------------------
    -- Top-level FSM
    -- ------------------------------------------------------------------
    TOP : process (i_Clk, i_Rst_L)
    begin
        if i_Rst_L = '0' then
            phase           <= PH_BOOT_CHECK;
            address_eeprom  <= (others => '0');
            data_eeprom     <= (others => '0');
            wr_ram_i        <= '0';
            done            <= '0';
            -- '0' during boot read so the LED mux signals "EEPROM busy"
            -- until INIT_DELAY completes and we transition to PH_IDLE
            o_wr_in_progress<= '0';
            c_count         <= 0;
            scan_cnt        <= 0;
            verify_byte     <= (others => '0');
            byte_retry      <= 0;
            reverify_pass   <= '0';
            error_latched   <= '0';
            blink_div       <= 0;
            blink_q         <= '0';
            old_w_trigger   <= (others => '0');
            spi_op          <= OP_NONE;
            spi_start       <= '0';
            sh_wren         <= '0';
            sh_data         <= (others => '0');
            TX_Data_R       <= (others => '0');
            TX_Data_W       <= (others => '0');
            TX_Data_Stat    <= (others => '0');
            TX_Data_Cmd     <= (others => '0');

        elsif rising_edge(i_Clk) then
            -- 1 Hz blink generator (always free-running)
            if blink_div = BLINK_DIV_CYCLES - 1 then
                blink_div <= 0;
                blink_q   <= not blink_q;
            else
                blink_div <= blink_div + 1;
            end if;

            -- default: spi_start and sh_wren are one-cycle pulses
            spi_start <= '0';
            sh_wren   <= '0';

            case phase is

                -- ===== boot read =====
                when PH_BOOT_CHECK =>
                    if i_init_Flag = '1' then
                        phase <= PH_BOOT_READ;
                    else
                        -- skip read, RAM keeps init pattern (0x0F)
                        c_count <= 0;
                        phase   <= PH_INIT_DELAY;
                    end if;

                when PH_BOOT_READ =>
                    TX_Data_R <= CMD_READ & selection & address_eeprom & x"00";
                    spi_op    <= OP_READ;
                    spi_start <= '1';
                    phase     <= PH_BOOT_LATCH;

                when PH_BOOT_LATCH =>
                    if spi_done_p = '1' then
                        data_eeprom <= RX_Data_R(7 downto 0);
                        wr_ram_i    <= '1';
                        sh_data     <= RX_Data_R(7 downto 0);
                        sh_wren     <= '1';
                        c_count     <= 0;
                    elsif wr_ram_i = '1' then
                        if c_count < HOLD_CYCLES then
                            c_count <= c_count + 1;
                        else
                            c_count  <= 0;
                            wr_ram_i <= '0';
                            phase   <= PH_BOOT_NEXT;
                        end if;
                    end if;

                when PH_BOOT_NEXT =>
                    if address_eeprom = x"FF" then
                        c_count <= 0;
                        phase   <= PH_INIT_DELAY;
                    else
                        address_eeprom <= std_logic_vector(unsigned(address_eeprom) + 1);
                        phase          <= PH_BOOT_READ;
                    end if;

                -- ===== arm / idle =====
                when PH_INIT_DELAY =>
                    if c_count < INIT_DELAY_CYCLES then
                        c_count <= c_count + 1;
                    else
                        c_count       <= 0;
                        done          <= '1';
                        old_w_trigger <= w_trigger;
                        phase         <= PH_IDLE;
                    end if;

                when PH_IDLE =>
                    o_wr_in_progress <= '1';
                    if w_trigger /= old_w_trigger then
                        old_w_trigger  <= w_trigger;
                        address_eeprom <= (others => '0');
                        c_count        <= 0;
                        phase          <= PH_ARMED;
                    end if;

                when PH_ARMED =>
                    if c_count < GLITCH_CYCLES then
                        c_count <= c_count + 1;
                    else
                        c_count <= 0;
                        if w_trigger = old_w_trigger then
                            phase <= PH_SAVE_PREP;
                        else
                            old_w_trigger <= w_trigger;
                            phase         <= PH_IDLE;
                        end if;
                    end if;

                when PH_SAVE_PREP =>
                    o_wr_in_progress <= '0';
                    if c_count < PRE_WRITE_CYCLES then
                        c_count <= c_count + 1;
                    else
                        c_count        <= 0;
                        error_latched  <= '0';
                        byte_retry     <= 0;
                        reverify_pass  <= '0';
                        address_eeprom <= (others => '0');
                        scan_cnt       <= 0;
                        phase          <= PH_SCAN_SETTLE;
                    end if;

                -- ===== shadow scan =====
                when PH_SCAN_SETTLE =>
                    if scan_cnt < SCAN_SETTLE_CYCLES then
                        scan_cnt <= scan_cnt + 1;
                    else
                        scan_cnt <= 0;
                        phase    <= PH_SCAN_COMPARE;
                    end if;

                when PH_SCAN_COMPARE =>
                    if sh_q /= q_ram then
                        byte_retry    <= 0;
                        reverify_pass <= '0';
                        phase         <= PH_WRITE_WREN;
                    else
                        phase <= PH_NEXT_BYTE;
                    end if;

                -- ===== per-byte write + verify =====
                when PH_WRITE_WREN =>
                    TX_Data_Cmd <= CMD_WREN;
                    spi_op      <= OP_WREN;
                    spi_start   <= '1';
                    phase       <= PH_WRITE_DATA;

                when PH_WRITE_DATA =>
                    if spi_done_p = '1' then
                        TX_Data_W   <= CMD_WRITE & selection & address_eeprom & q_ram;
                        verify_byte <= q_ram;
                        spi_op      <= OP_WRITE;
                        spi_start   <= '1';
                        phase       <= PH_POLL_RDSR;
                    end if;

                when PH_POLL_RDSR =>
                    if spi_done_p = '1' then
                        TX_Data_Stat <= CMD_RDSR & x"00";
                        spi_op       <= OP_RDSR;
                        spi_start    <= '1';
                        phase        <= PH_POLL_CHECK;
                    end if;

                when PH_POLL_CHECK =>
                    if spi_done_p = '1' then
                        if RX_Data_Stat(SR_WIP_BIT) = '0' then
                            phase <= PH_VERIFY_READ;
                        else
                            -- still busy, poll again
                            TX_Data_Stat <= CMD_RDSR & x"00";
                            spi_op       <= OP_RDSR;
                            spi_start    <= '1';
                            -- stay in PH_POLL_CHECK
                        end if;
                    end if;

                when PH_VERIFY_READ =>
                    TX_Data_R <= CMD_READ & selection & address_eeprom & x"00";
                    spi_op    <= OP_READ;
                    spi_start <= '1';
                    phase     <= PH_VERIFY_CHECK;

                when PH_VERIFY_CHECK =>
                    if spi_done_p = '1' then
                        if RX_Data_R(7 downto 0) = verify_byte then
                            if reverify_pass = '0' then
                                -- first verify ok → wait then read again
                                reverify_pass <= '1';
                                c_count       <= 0;
                                phase         <= PH_REVERIFY_DELAY;
                            else
                                -- second verify ok → commit shadow
                                sh_data       <= verify_byte;
                                sh_wren       <= '1';
                                reverify_pass <= '0';
                                byte_retry    <= 0;
                                phase         <= PH_NEXT_BYTE;
                            end if;
                        elsif byte_retry < MAX_RETRY then
                            byte_retry    <= byte_retry + 1;
                            reverify_pass <= '0';
                            phase         <= PH_WRITE_WREN;
                        else
                            error_latched <= '1';
                            reverify_pass <= '0';
                            byte_retry    <= 0;
                            phase         <= PH_NEXT_BYTE;
                        end if;
                    end if;

                when PH_REVERIFY_DELAY =>
                    if c_count < REVERIFY_CYCLES then
                        c_count <= c_count + 1;
                    else
                        c_count <= 0;
                        phase   <= PH_VERIFY_READ;
                    end if;

                when PH_NEXT_BYTE =>
                    if address_eeprom = x"FF" then
                        phase <= PH_IDLE;
                    else
                        address_eeprom <= std_logic_vector(unsigned(address_eeprom) + 1);
                        scan_cnt       <= 0;
                        phase          <= PH_SCAN_SETTLE;
                    end if;

            end case;
        end if;
    end process;

end Behavioral;
