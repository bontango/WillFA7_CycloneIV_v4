--
-- EEprom.vhd
-- read/write eeprom content to and from ram
-- for BallyFA / WillFA
-- bontango 09.2020
--
-- code is specific for SPI EEPROM M95512 (64KByte, 16-bit address, 128-byte page)
-- SPI mode 0 (CPOL=0, CPHA=0)
--
-- v 0.1 .. v 094  initial implementation, byte-wise writes (see git history)
-- v 095 Stage A: WIP-poll timeout, 2-FF sync, longer debounce, SPI_Master reset
-- v 096 Stage B: single SPI master + page-write + verify-read with retry +
--                EEprom_error output (1 Hz blink while last save failed)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity EEprom is
   port(
   i_Clk             : in  std_logic;
   done              : out std_logic;
   address_eeprom    : buffer std_logic_vector(7 downto 0);
   data_eeprom       : out std_logic_vector(7 downto 0);
   q_ram             : in  std_logic_vector(7 downto 0);
   wr_ram            : out std_logic;
   i_Rst_L           : in  std_logic;
   o_SPI_Clk         : out std_logic;
   i_SPI_MISO        : in  std_logic;
   o_SPI_MOSI        : out std_logic;
   o_SPI_CS_n        : out std_logic;
   selection         : in  std_logic_vector(7 downto 0);
   w_trigger         : in  std_logic_vector(4 downto 0);
   i_init_Flag       : in  std_logic;
   o_wr_in_progress  : out std_logic;
   EEprom_error      : out std_logic
   );
end EEprom;

architecture Behavioral of EEprom is

   type STATE_T is (
      Check_dip,
      -- burst read (used both for initial read and for verify after write)
      Rd_Init,
      Rd_SendCmd,  Rd_SendCmd_W,  Rd_SendCmd_M,
      Rd_SendAdrH, Rd_SendAdrH_W, Rd_SendAdrH_M,
      Rd_SendAdrL, Rd_SendAdrL_W, Rd_SendAdrL_M,
      Rd_SendDmy,  Rd_SendDmy_W,  Rd_Hold, Rd_SendDmy_M,
      Rd_Done,
      Delay, Idle, Delay2, Delay3,
      -- per-page write
      Pg_Init,
      Pg_WREN,     Pg_WREN_W,     Pg_WREN_M,
      Pg_SendCmd,  Pg_SendCmd_W,  Pg_SendCmd_M,
      Pg_SendAdrH, Pg_SendAdrH_W, Pg_SendAdrH_M,
      Pg_SendAdrL, Pg_SendAdrL_W, Pg_SendAdrL_M,
      Pg_SendData_Settle,
      Pg_SendData, Pg_SendData_W, Pg_SendData_M,
      -- WIP polling
      Pg_PollCmd,  Pg_PollCmd_W,  Pg_PollCmd_M,
      Pg_PollDat,  Pg_PollDat_W,  Pg_PollDat_M,
      Pg_NextPage
   );

   signal state : STATE_T;

   -- single SPI master (8-bit, byte-chained via do_not_*_SS)
   signal TX_Data8       : std_logic_vector(7 downto 0);
   signal RX_Data8       : std_logic_vector(7 downto 0);
   signal TX_Start       : std_logic;
   signal TX_Done        : std_logic;
   signal not_disable_ss : std_logic;
   signal not_enable_ss  : std_logic;

   -- WIP bit captured from RDSR
   signal WIP_bit        : std_logic;

   -- triggers
   signal old_w_trigger   : std_logic_vector(4 downto 0);
   signal w_trigger_sync1 : std_logic_vector(4 downto 0);
   signal w_trigger_sync2 : std_logic_vector(4 downto 0);

   -- counters
   signal c_count        : integer range 0 to 500000000;
   -- WIP-poll timeout: ~160 us per RDSR @ 100 kHz; 500 polls => ~80 ms,
   -- well above the M95512 tWC budget (~5 ms).
   signal wip_poll_count : integer range 0 to 1023;

   -- page-write context
   signal verify_mode  : std_logic;
   signal page_idx     : integer range 0 to 1;
   signal byte_in_page : integer range 0 to 127;
   signal mismatch     : std_logic;
   signal retry_count  : integer range 0 to 3;

   -- error LED: free-running 1 Hz toggle, gated by latched-failure flag
   signal eeprom_error_latched : std_logic;
   signal blink_div            : integer range 0 to 25_000_000;
   signal blink_q              : std_logic;

begin

EEPROM_SPI: entity work.SPI_Master
   generic map (
      SPI_Taktfrequenz => 100000,
      Laenge           => 8)
   port map (
      TX_Data           => TX_Data8,
      RX_Data           => RX_Data8,
      MOSI              => o_SPI_MOSI,
      MISO              => i_SPI_MISO,
      SCLK              => o_SPI_Clk,
      SS                => o_SPI_CS_n,
      TX_Start          => TX_Start,
      TX_Done           => TX_Done,
      clk               => i_Clk,
      do_not_disable_SS => not_disable_ss,
      do_not_enable_SS  => not_enable_ss,
      i_Rst_L           => i_Rst_L
      );

   EEprom_error <= blink_q when eeprom_error_latched = '1' else '0';

EEPROM: process (i_Clk, i_Rst_L)
begin
   if i_Rst_L = '0' then
      TX_Start             <= '0';
      not_disable_ss       <= '0';
      not_enable_ss        <= '0';
      TX_Data8             <= (others => '0');
      address_eeprom       <= (others => '0');
      wr_ram               <= '0';
      c_count              <= 0;
      done                 <= '0';
      state                <= Check_dip;
      o_wr_in_progress     <= '1';
      wip_poll_count       <= 0;
      w_trigger_sync1      <= (others => '0');
      w_trigger_sync2      <= (others => '0');
      old_w_trigger        <= (others => '0');
      verify_mode          <= '0';
      page_idx             <= 0;
      byte_in_page         <= 0;
      mismatch             <= '0';
      retry_count          <= 0;
      eeprom_error_latched <= '0';
      blink_div            <= 0;
      blink_q              <= '0';
      WIP_bit              <= '0';
      data_eeprom          <= (others => '0');
   elsif rising_edge(i_Clk) then

      -- 1 Hz blink generator (free-running)
      if blink_div = 25_000_000 - 1 then
         blink_div <= 0;
         blink_q   <= not blink_q;
      else
         blink_div <= blink_div + 1;
      end if;

      -- 2-FF synchronizer for w_trigger (consume w_trigger_sync2 below)
      w_trigger_sync1 <= w_trigger;
      w_trigger_sync2 <= w_trigger_sync1;

      case state is

      when Check_dip =>
         if i_init_Flag = '1' then
            verify_mode <= '0';
            state       <= Rd_Init;
         else
            state <= Delay;
         end if;

      ----- BURST READ (initial read or verify) -----
      when Rd_Init =>
         address_eeprom <= (others => '0');
         mismatch       <= '0';
         state          <= Rd_SendCmd;

      when Rd_SendCmd =>
         TX_Data8       <= x"03";
         not_enable_ss  <= '0';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Rd_SendCmd_W;
      when Rd_SendCmd_W =>
         if TX_Done = '1' then
            TX_Start <= '0';
            state    <= Rd_SendCmd_M;
         end if;
      when Rd_SendCmd_M =>
         if TX_Done = '0' then state <= Rd_SendAdrH; end if;

      when Rd_SendAdrH =>
         TX_Data8       <= selection;
         not_enable_ss  <= '1';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Rd_SendAdrH_W;
      when Rd_SendAdrH_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Rd_SendAdrH_M; end if;
      when Rd_SendAdrH_M =>
         if TX_Done = '0' then state <= Rd_SendAdrL; end if;

      when Rd_SendAdrL =>
         TX_Data8       <= x"00";
         not_enable_ss  <= '1';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Rd_SendAdrL_W;
      when Rd_SendAdrL_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Rd_SendAdrL_M; end if;
      when Rd_SendAdrL_M =>
         if TX_Done = '0' then state <= Rd_SendDmy; end if;

      when Rd_SendDmy =>
         TX_Data8      <= x"FF";
         not_enable_ss <= '1';
         if address_eeprom = x"FF" then
            not_disable_ss <= '0';
         else
            not_disable_ss <= '1';
         end if;
         TX_Start <= '1';
         state    <= Rd_SendDmy_W;
      when Rd_SendDmy_W =>
         if TX_Done = '1' then
            TX_Start <= '0';
            if verify_mode = '0' then
               data_eeprom <= RX_Data8;
               wr_ram      <= '1';
            else
               if RX_Data8 /= q_ram then
                  mismatch <= '1';
               end if;
            end if;
            state <= Rd_Hold;
         end if;
      when Rd_Hold =>
         if c_count < 1000 then
            c_count <= c_count + 1;
         else
            c_count <= 0;
            wr_ram  <= '0';
            state   <= Rd_SendDmy_M;
         end if;
      when Rd_SendDmy_M =>
         if TX_Done = '0' then
            if address_eeprom = x"FF" then
               state <= Rd_Done;
            else
               address_eeprom <= std_logic_vector(unsigned(address_eeprom) + 1);
               state          <= Rd_SendDmy;
            end if;
         end if;

      when Rd_Done =>
         if verify_mode = '0' then
            state <= Delay;
         else
            if mismatch = '0' then
               eeprom_error_latched <= '0';
               retry_count          <= 0;
               state                <= Idle;
            elsif retry_count < 2 then
               retry_count <= retry_count + 1;
               state       <= Pg_Init;
            else
               eeprom_error_latched <= '1';
               retry_count          <= 0;
               state                <= Idle;
            end if;
         end if;

      ----- delays -----
      when Delay =>
         if c_count < 100000000 then
            c_count <= c_count + 1;
         else
            done          <= '1';
            c_count       <= 0;
            old_w_trigger <= w_trigger_sync2;
            state         <= Idle;
         end if;

      when Idle =>
         o_wr_in_progress <= '1';
         if w_trigger_sync2 /= old_w_trigger then
            old_w_trigger  <= w_trigger_sync2;
            address_eeprom <= (others => '0');
            state          <= Delay2;
         end if;

      when Delay2 =>
         if c_count < 250000 then
            c_count <= c_count + 1;
         else
            c_count <= 0;
            if w_trigger_sync2 = old_w_trigger then
               state <= Delay3;
            else
               old_w_trigger <= w_trigger_sync2;
               state         <= Idle;
            end if;
         end if;

      when Delay3 =>
         o_wr_in_progress <= '0';
         if c_count < 50000000 then
            c_count <= c_count + 1;
         else
            c_count     <= 0;
            retry_count <= 0;
            state       <= Pg_Init;
         end if;

      ----- PAGE WRITE -----
      when Pg_Init =>
         page_idx       <= 0;
         byte_in_page   <= 0;
         address_eeprom <= (others => '0');
         state          <= Pg_WREN;

      when Pg_WREN =>
         TX_Data8       <= x"06";
         not_enable_ss  <= '0';
         not_disable_ss <= '0';
         TX_Start       <= '1';
         wip_poll_count <= 0;
         state          <= Pg_WREN_W;
      when Pg_WREN_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_WREN_M; end if;
      when Pg_WREN_M =>
         if TX_Done = '0' then state <= Pg_SendCmd; end if;

      when Pg_SendCmd =>
         TX_Data8       <= x"02";
         not_enable_ss  <= '0';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Pg_SendCmd_W;
      when Pg_SendCmd_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_SendCmd_M; end if;
      when Pg_SendCmd_M =>
         if TX_Done = '0' then state <= Pg_SendAdrH; end if;

      when Pg_SendAdrH =>
         TX_Data8       <= selection;
         not_enable_ss  <= '1';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Pg_SendAdrH_W;
      when Pg_SendAdrH_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_SendAdrH_M; end if;
      when Pg_SendAdrH_M =>
         if TX_Done = '0' then state <= Pg_SendAdrL; end if;

      when Pg_SendAdrL =>
         if page_idx = 0 then TX_Data8 <= x"00"; else TX_Data8 <= x"80"; end if;
         not_enable_ss  <= '1';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Pg_SendAdrL_W;
      when Pg_SendAdrL_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_SendAdrL_M; end if;
      when Pg_SendAdrL_M =>
         if TX_Done = '0' then
            -- give dual-port-RAM an extra cycle to settle q_ram for current address
            c_count <= 0;
            state   <= Pg_SendData_Settle;
         end if;

      when Pg_SendData_Settle =>
         if c_count < 5 then
            c_count <= c_count + 1;
         else
            c_count <= 0;
            state   <= Pg_SendData;
         end if;

      when Pg_SendData =>
         TX_Data8      <= q_ram;
         not_enable_ss <= '1';
         if byte_in_page = 127 then
            not_disable_ss <= '0';   -- last byte of page releases CS
         else
            not_disable_ss <= '1';
         end if;
         TX_Start <= '1';
         state    <= Pg_SendData_W;
      when Pg_SendData_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_SendData_M; end if;
      when Pg_SendData_M =>
         if TX_Done = '0' then
            if byte_in_page = 127 then
               state <= Pg_PollCmd;
            else
               byte_in_page   <= byte_in_page + 1;
               address_eeprom <= std_logic_vector(unsigned(address_eeprom) + 1);
               c_count        <= 0;
               state          <= Pg_SendData_Settle;
            end if;
         end if;

      ----- WIP polling (RDSR) -----
      when Pg_PollCmd =>
         TX_Data8       <= x"05";
         not_enable_ss  <= '0';
         not_disable_ss <= '1';
         TX_Start       <= '1';
         state          <= Pg_PollCmd_W;
      when Pg_PollCmd_W =>
         if TX_Done = '1' then TX_Start <= '0'; state <= Pg_PollCmd_M; end if;
      when Pg_PollCmd_M =>
         if TX_Done = '0' then state <= Pg_PollDat; end if;

      when Pg_PollDat =>
         TX_Data8       <= x"00";
         not_enable_ss  <= '1';
         not_disable_ss <= '0';
         TX_Start       <= '1';
         state          <= Pg_PollDat_W;
      when Pg_PollDat_W =>
         if TX_Done = '1' then
            TX_Start <= '0';
            WIP_bit  <= RX_Data8(0);
            state    <= Pg_PollDat_M;
         end if;
      when Pg_PollDat_M =>
         if TX_Done = '0' then
            if WIP_bit = '0' then
               state <= Pg_NextPage;
            elsif wip_poll_count >= 500 then
               eeprom_error_latched <= '1';
               state                <= Idle;
            else
               wip_poll_count <= wip_poll_count + 1;
               state          <= Pg_PollCmd;
            end if;
         end if;

      when Pg_NextPage =>
         if page_idx = 0 then
            page_idx       <= 1;
            byte_in_page   <= 0;
            address_eeprom <= x"80";
            state          <= Pg_WREN;
         else
            -- both pages written, now verify
            verify_mode <= '1';
            state       <= Rd_Init;
         end if;

      end case;
   end if;
end process;

end Behavioral;
