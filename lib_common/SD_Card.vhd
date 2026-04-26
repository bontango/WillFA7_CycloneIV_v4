--
-- SD_Card.vhd
-- read SD card in 'raw' Mode to move code to RAM/ROM
-- version with reset_l and 12KByte read
-- for WillFA
-- bontango 12.2022
--
-- v01 added feedback on successfull SD card read
-- v02 synchronous reset
-- v03 extended CMD to 14 bytes, added second R1 position (needed for some cards), added error state
-- v04 added error blinkcode
-- v05 reset_l & 10Kbyte read
-- v06 wait 0.5 ec before start cpu
-- v07 12Kbyte read
-- v08 robustness Stage A: watchdogs on all wait states, distinct error blink
--     codes (1=SPI hang, 2=CMD0 fail, 3=CMD8 unsupported, 4=ACMD41 timeout,
--     5=data token timeout), ACMD41 retry cap reduced 5000->100
-- v09 ROM read size made configurable via generic Read_Bytes (default 12288)
-- v10 Stage A reste: R1 response located via priority search across all 7
--     response bytes (handles cards with Ncr > 2 byte latency); data-error-
--     token (0000 xxxx, low nibble != 0) detected during sector polling
--     instead of waiting for the FE-token watchdog. New error code 6 = data
--     error token. R1_response_2 obsolete and removed.

library IEEE;
use IEEE.std_logic_1164.all;
--use IEEE.std_logic_arith.all;
--use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

	entity SD_Card is
		generic (
			-- Number of bytes to read from SD card (must be a multiple of 512).
			-- Default 12288 = 12 KByte = 24 sectors, matches the legacy behaviour.
			-- The address bus address_sd_card is 14 bit wide, so the practical
			-- upper limit without further changes is 16384 bytes.
			Read_Bytes : integer := 12288
		);
		port(
		i_Clk		: IN STD_LOGIC  := '1';
		-- Control/Data Signals,
		i_Rst_L : in std_logic;     -- FPGA Reset		
		-- PMOD SPI Interface
		o_SPI_Clk  : out std_logic;
		i_SPI_MISO : in std_logic;
		o_SPI_MOSI : out std_logic;
		o_SPI_CS_n : out std_logic;
		-- selektion
		selection : in std_logic_vector(7 downto 0);
		-- sd card
		address_sd_card	: buffer  std_logic_vector(13 downto 0);
		data_sd_card	: out std_logic_vector(7 downto 0);
		wr_rom :  out std_logic;		
		-- start CPU
		cpu_reset_l : out STD_LOGIC;
		-- feedback
		SDcard_error : out STD_LOGIC
		);
    end SD_Card;
	 
   architecture Behavioral of SD_Card is		
		type STATE_T is ( Startdelay, send_read_request, wait_for_read, continue, 
								initiate_read_sector, wait_for_begin_of_data,check_for_FE_flag, sector_read, wait_for_byte_read,
								check_sector_byte, inc_addr_and_unset_wr, stop_read, delay_and_repeat, all_done, error, stop );
		signal state_A : STATE_T;       
		
		
		-- SPI stuff for SD card commands	
		signal TX_Data_A : std_LOGIC_VECTOR ( 111 downto 0); -- 14 Bytes ( 6 cmd bytes, 1 NCR ,1 Return ,4 CMD Echo )
		signal RX_Data_A : std_LOGIC_VECTOR ( 111 downto 0);  -- we also send 0xFF with CS disable before and after
		signal TX_Start_A : std_LOGIC;
		signal TX_Done_A : std_LOGIC;
		signal MOSI_A : std_LOGIC;
		signal SS_A :  std_LOGIC;
		signal SPI_Clk_A :  std_LOGIC;

		-- SPI stuff for SD card read, byte by byte
		signal TX_Data_R : std_LOGIC_VECTOR ( 7 downto 0); 
		signal RX_Data_R : std_LOGIC_VECTOR ( 7 downto 0);
		signal TX_Start_R : std_LOGIC;
		signal TX_Done_R : std_LOGIC;
		signal MOSI_R : std_LOGIC;
		signal SS_R :  std_LOGIC;
		signal SPI_Clk_R :  std_LOGIC;
		
		-----		
		signal cmd_count : integer range 0 to 16; 
		signal R1_response : std_LOGIC_VECTOR (7 downto 0);
		-- position of R1 within the 7 response bytes (0..6); 7 = none found.
		-- For CMD8, valid echo is only available for R1_pos <= 2.
		signal R1_pos : integer range 0 to 7;
		signal Echo_response : std_LOGIC_VECTOR (7 downto 0);
		signal active_master : std_LOGIC_VECTOR (1 downto 0) := "00";
		signal do_not_disable_SS : std_LOGIC;		
		signal do_not_enable_SS : std_LOGIC;	
		signal sector : unsigned (15 downto 0);	
		
		signal byte_count : integer range 0 to 520;

		signal attempts : integer range 0 to 5000;
		signal counter  : integer range 0 to 100000000;   -- delay, for 10ms use 500.000

		-- Stufe-A robustness: watchdog + distinct error codes
		-- Error blink codes (visible on SDcard_error LED):
		--   1 = SPI transfer hang  (TX_Done never asserted within 1 s)
		--   2 = CMD0 reset failed  (8 attempts exhausted)
		--   3 = CMD8 unsupported   (likely old SDv1 card; not implemented)
		--   4 = ACMD41 init timeout (card never left idle)
		--   5 = Sector data token timeout (no 0xFE within 500 ms)
		--   6 = Data error token received (card aborted the sector read)
		signal wd_count        : integer range 0 to 100000000; -- general watchdog (~2 s headroom @ 50 MHz)
		signal err_code        : integer range 0 to 15;
		signal blink_remaining : integer range 0 to 15;
	begin
		
		-- signals for the two SPI Master
	o_SPI_MOSI <=	
	MOSI_A when active_master = "01" else
	MOSI_R when active_master = "10" else
	'0';

	o_SPI_Clk <=
	SPI_Clk_A when active_master = "01"  else
	SPI_Clk_R when active_master = "10"  else
	'0';

	o_SPI_CS_n <=
	SS_A when active_master = "01"  else
	'0' when active_master = "10" else
	'1';
	
	
SD_CARD_ACCESS: entity work.SPI_Master
    generic map (      
      Laenge => 112,
		SPI_Taktfrequenz => 400000) -- 400KHz for commands
    port map (
			  TX_Data  => TX_Data_A,
           RX_Data  => RX_Data_A,
           MOSI     => MOSI_A,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_A,
           SS       => SS_A,
           TX_Start => TX_Start_A,
           TX_Done  => TX_Done_A,
           clk      => i_Clk,	  
			  do_not_disable_SS => do_not_disable_SS,
			  do_not_enable_SS => do_not_enable_SS
      );
		
SD_CARD_READ: entity work.SPI_Master --read i byte by byte (slooow)
    generic map (      
      Laenge => 8,
		SPI_Taktfrequenz => 400000) -- 400KHz for commands
    port map (
			  TX_Data  => TX_Data_R,
           RX_Data  => RX_Data_R,
           MOSI     => MOSI_R,
           MISO     => i_SPI_MISO,
           SCLK     => SPI_Clk_R,
           SS       => SS_R,
           TX_Start => TX_Start_R,
           TX_Done  => TX_Done_R,
           clk      => i_Clk,
			  do_not_disable_SS => do_not_disable_SS,
			  do_not_enable_SS => do_not_enable_SS
      );

		
		SD_Card: process (i_Clk, i_Rst_L )
			--constant all_high : std_LOGIC_VECTOR (47 downto 0) := x"FFFFFFFFFFFF";
			constant CMD0 : std_LOGIC_VECTOR (47 downto 0) := x"400000000095"; --reset			
			constant CMD8 : std_LOGIC_VECTOR (47 downto 0) := x"48000001AA87"; --check the version of SD card					
			--constant CMD1 : std_LOGIC_VECTOR (47 downto 0) := x"4100000000F9"; -- initiate the initialization process (old cards)
			--only support for 'new' Sd cards at the moment
			constant CMD55 : std_LOGIC_VECTOR (47 downto 0) := x"7700000000FF";	-- leading cmd for AMD commands 
			constant ACMD41 : std_LOGIC_VECTOR (47 downto 0) := x"6940000000FF";	-- initiate the initialization process			
			constant CMD17 : std_LOGIC_VECTOR (47 downto 0) := x"5100000000FF"; --single-read block
			constant CMD18 : std_LOGIC_VECTOR (47 downto 0) := x"5200000000FF"; --multi-read block
			constant CMD12 : std_LOGIC_VECTOR (47 downto 0) := x"4C00000000FF"; --stop to read data
			constant CMD58 : std_LOGIC_VECTOR (47 downto 0) := x"7A00000000FF"; --read OCR
			
		begin
		if rising_edge(i_Clk) then
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
				cpu_reset_l <= '0';
				TX_Start_A <= '0';		
				TX_Start_R <= '0';		
				TX_Data_R <= x"FF";				
				cmd_count <= 0;
				active_master <= "00";
				do_not_disable_SS <= '0'; --default
				do_not_enable_SS <= '0'; --default
				wr_rom <= '0';
				address_sd_card <= (others => '0');
				byte_count <= 0;
				SDcard_error <= '1'; -- active low
				counter <= 0;
				attempts <= 0;
				wd_count <= 0;
				err_code <= 0;
				blink_remaining <= 0;
				R1_pos <= 7;
				R1_response <= x"FF";
				Echo_response <= x"00";
				state_A <= Startdelay;
			else			
				case state_A is
				-- STATE MASCHINE ----------------
				 when Startdelay => 
						active_master <= "01";			
					--give SD card time to power up					
					counter <= counter +1;					
					if ( counter = 25000000 ) then --500ms 
						state_A <= send_read_request;
						counter <= 0;						
					end if;																													
				when send_read_request =>						
				   case cmd_count is
					   when 1 => TX_Data_A <= x"FF" & x"FFFFFFFFFFFF" & x"FFFFFFFFFFFFFF"; -- init 
									 do_not_enable_SS <= '1';
						when 2 => TX_Data_A <= x"FF" & CMD0 & x"FFFFFFFFFFFFFF"; --go idle state, resets SD card						
									 do_not_enable_SS <= '0';
						when 3 => TX_Data_A <= x"FF" & CMD8 & x"FFFFFFFFFFFFFF";	-- send interface condition
						when 4 => TX_Data_A <= x"FF" & CMD55 & x"FFFFFFFFFFFFFF";						
						when 5 => TX_Data_A <= x"FF" & ACMD41 & x"FFFFFFFFFFFFFF";		
						when 6 => TX_Data_A <= x"FF" & CMD58 & x"FFFFFFFFFFFFFF";		
						when 7 => TX_Data_A <= x"FF" & CMD18 & x"FFFFFFFFFFFFFF";
									 do_not_disable_SS <= '1';
									 -- special: calculate sector on WillFA SD
									 -- where to read rom depending on dip switch
									 -- first rom starts at sector 660
									 -- per game: Read_Bytes/512 sectors (default 12 KB = 24 sectors)
									 TX_Data_A(79 downto 64)  <= std_logic_vector (unsigned(selection) * (Read_Bytes/512) + 660);
						when 8 => TX_Data_A <= x"FF" & CMD12 & x"FFFFFFFFFFFFFF";	
									 do_not_disable_SS <= '0';	
						when others => TX_Data_A <= x"FF" & x"FFFFFFFFFFFF" & x"FFFFFFFFFFFFFF"; --  read
					end case;
					TX_Start_A <= '1'; -- set flag for sending byte
					wd_count <= 0;     -- watchdog: SPI transfer must complete within ~1 s
					state_A <= wait_for_read;

				when wait_for_read =>
						if (TX_Done_A = '1') then -- Master sets TX_Done when TX is done ;-)
							TX_Start_A <= '0'; -- reset flag
								-- R1 search: SD spec allows Ncr = 0..8 byte latency between command
								-- and response. 7 response bytes are captured (after the leading 0xFF
								-- and the 6 cmd bytes); first byte with bit7='0' is the R1 response.
								-- For CMD8, the 4-byte echo follows R1; the check pattern (0xAA) is at
								-- byte R1_pos + 4. Only positions 0..2 leave room for a full echo.
								if    RX_Data_A(55) = '0' then
									R1_response   <= RX_Data_A(55 downto 48);
									Echo_response <= RX_Data_A(23 downto 16);
									R1_pos        <= 0;
								elsif RX_Data_A(47) = '0' then
									R1_response   <= RX_Data_A(47 downto 40);
									Echo_response <= RX_Data_A(15 downto  8);
									R1_pos        <= 1;
								elsif RX_Data_A(39) = '0' then
									R1_response   <= RX_Data_A(39 downto 32);
									Echo_response <= RX_Data_A( 7 downto  0);
									R1_pos        <= 2;
								elsif RX_Data_A(31) = '0' then
									R1_response   <= RX_Data_A(31 downto 24);
									Echo_response <= x"00";
									R1_pos        <= 3;
								elsif RX_Data_A(23) = '0' then
									R1_response   <= RX_Data_A(23 downto 16);
									Echo_response <= x"00";
									R1_pos        <= 4;
								elsif RX_Data_A(15) = '0' then
									R1_response   <= RX_Data_A(15 downto  8);
									Echo_response <= x"00";
									R1_pos        <= 5;
								elsif RX_Data_A( 7) = '0' then
									R1_response   <= RX_Data_A( 7 downto  0);
									Echo_response <= x"00";
									R1_pos        <= 6;
								else
									R1_response   <= x"FF";
									Echo_response <= x"00";
									R1_pos        <= 7;
								end if;
							state_A <= continue;
						elsif wd_count >= 50000000 then -- 1 s @ 50 MHz: SPI never finished
							TX_Start_A <= '0';
							err_code <= 1;
							blink_remaining <= 1;
							counter <= 0;
							state_A <= error;
						else
							wd_count <= wd_count + 1;
						end if;
										
				when continue =>
					if (TX_Done_A = '0') then -- Master sets back TX_Done when ready again
								cmd_count <= cmd_count +1;
								case cmd_count is
									when 2 => --check response of CMD0
										if R1_response /= x"01" then
											if (attempts < 8) then
												cmd_count <= 2; --repeat
												attempts <= attempts +1;
												state_A <= delay_and_repeat;
											else
												err_code <= 2; -- CMD0 reset failed
												blink_remaining <= 2;
												counter <= 0;
												state_A <= error;
											end if;
										else --success
											attempts <= 0;
											state_A <= send_read_request; -- next cmd to send
										end if;
									when 3 => --check response of CMD8
										-- R1_pos > 2 means the 4-byte echo did not fit into the captured
										-- response window -> treat as unsupported (same blink code 3).
										if (R1_response /= x"01") or (Echo_response /= x"AA") or (R1_pos > 2) then
											-- Most likely: SDv1.x card answers CMD8 with illegal-command (R1 = 0x05).
											-- We do not implement the SDv1 init path -> report cleanly instead of hanging.
											err_code <= 3;
											blink_remaining <= 3;
											counter <= 0;
											state_A <= error;
										else
											state_A <= send_read_request; -- next cmd to send
										end if;
									when 5 => -- count 5 is SD card init--repeat CMD55 & ACMD41 until card is READY
										if R1_response /= x"00" then
											-- Reduced from 5000 (->500 s) to 100 (->~10 s) which is well above
											-- the ~1 s typical SD power-up time per spec.
											if (attempts < 100) then
												cmd_count <= 4; --repeat go back to CMD55
												attempts <= attempts +1;
												state_A <= delay_and_repeat;
											else
												err_code <= 4; -- ACMD41 init timeout
												blink_remaining <= 4;
												counter <= 0;
												state_A <= error;
											end if;
										else --success
											attempts <= 0;
											state_A <= send_read_request; -- next cmd to send
										end if;
									when 7 => --last command send, we now read data
										cmd_count <= 0;
										TX_Data_R <= x"FF";
										active_master <= "10";
										address_sd_card <= (others => '0');
										byte_count <= 0;
										wd_count <= 0; -- arm sector-token watchdog (~500 ms)
										state_A <= initiate_read_sector;
									when 8 => -- we send CMD12 to stop read sector, all done
										wr_rom <= '0';
										state_A <= all_done;

									when others =>
										state_A <= send_read_request; -- next cmd to send
								end case;
					end if;
					
				when delay_and_repeat =>	
					counter <= counter +1;					
					if ( counter = 5000000 ) then --100ms 
						state_A <= send_read_request;
						counter <= 0;						
					end if;					
					
		--------------------------------------
		-- second master  --------------------
		-- read 20 sectors -------------------
		--------------------------------------
		
				when initiate_read_sector =>
							TX_Start_R <= '1'; -- set flag for sending byte
							state_A <= wait_for_begin_of_data;

				when wait_for_begin_of_data =>
							if (TX_Done_R = '1') then -- Master sets TX_Done when TX is done ;-)
							TX_Start_R <= '0'; -- reset flag
							state_A <= check_for_FE_flag;
						elsif wd_count >= 25000000 then -- 500 ms: card never delivered data token
							TX_Start_R <= '0';
							err_code <= 5;
							blink_remaining <= 5;
							counter <= 0;
							state_A <= error;
						else
							wd_count <= wd_count + 1;
						end if;

				when check_for_FE_flag =>
						if (TX_Done_R = '0') then -- Master sets back TX_Done when ready again
						data_sd_card <= RX_Data_R;
						   if RX_Data_R = x"FE" then
								wd_count <= 0; -- 0xFE found: re-arm watchdog for the next sector
								state_A <= sector_read; --flag found, next byte is data
							elsif (RX_Data_R(7 downto 4) = "0000") and (RX_Data_R(3 downto 0) /= "0000") then
								-- Data error token: high nibble 0, low nibble carries the error bits
								-- (0=Error, 1=CC error, 2=ECC failed, 3=out-of-range). Card aborted
								-- the sector read; bail out cleanly instead of waiting for the watchdog.
								err_code        <= 6;
								blink_remaining <= 6;
								counter         <= 0;
								state_A         <= error;
							else
								state_A <= initiate_read_sector; --next byte to read and check
							end if;
						end if;
	
				when sector_read =>
							TX_Start_R <= '1'; -- set flag for sending byte
							wr_rom <= '0'; --stop writing to ram/rom
							wd_count <= 0; -- per-byte watchdog
							state_A <= wait_for_byte_read;

				when wait_for_byte_read =>
							if (TX_Done_R = '1') then -- Master sets TX_Done when TX is done ;-)
									TX_Start_R <= '0'; -- reset flag
									-- count byte
									byte_count <= byte_count +1;
									--assign data
									data_sd_card <= RX_Data_R;
									state_A <= check_sector_byte;
							elsif wd_count >= 5000000 then -- 100 ms per byte: SPI hang during stream
									TX_Start_R <= '0';
									err_code <= 1;
									blink_remaining <= 1;
									counter <= 0;
									state_A <= error;
							else
									wd_count <= wd_count + 1;
							end if;
							
				when check_sector_byte =>							
						if (TX_Done_R = '0') then -- Master sets back TX_Done when ready again
							-- where are we in sector read?
							if byte_count <= 512 then	-- in sector read
								wr_rom <= '1';	-- write to ram/rom with current data & address
								state_A <= inc_addr_and_unset_wr;		-- write to ram/rom
							elsif byte_count <= 514 then -- in crc read
								-- no write for crc
								state_A <= sector_read;		-- next byte						
							else -- sector read finished
								byte_count <= 0;
								wd_count <= 0;                            -- arm watchdog for next 0xFE token
								state_A <= initiate_read_sector;		-- next sector
							end if;																											
						end if;
						
				when inc_addr_and_unset_wr =>
								wr_rom <= '0';
								-- prepare address for next
								address_sd_card <= std_LOGIC_VECTOR(unsigned(address_sd_card) +1);
								-- finished? (last written address = Read_Bytes - 1)
								if unsigned(address_sd_card) = to_unsigned(Read_Bytes - 1, address_sd_card'length) then
										state_A <= stop_read;		--just read last byte
								else
										state_A <= sector_read;		-- next byte
								end if;
												
				when stop_read =>																
								cmd_count <= 8; --we use cmd counter from init routine								
								active_master <= "01"; --because sending of a command								
								state_A <= send_read_request; 
								
				when all_done =>		
					-- wait a bit, then start cpu
					if ( counter < 25000000 ) then
						counter <= counter +1;					
					else
						cpu_reset_l <= '1';						
						SDcard_error <= '1'; --active low				
					end if;
					
				when error =>
					-- Blink err_code times (LED active-low: '0' = on), then ~2 s gap, repeat forever.
					-- Per blink: 250 ms ON, 250 ms OFF.
					counter <= counter + 1;
					if blink_remaining = 0 then
						-- gap between blink groups: keep LED off ('1') for ~2 s, then re-arm.
						SDcard_error <= '1';
						if counter >= 100000000 then -- 2 s @ 50 MHz
							counter <= 0;
							blink_remaining <= err_code;
						end if;
					else
						if counter < 12500000 then       -- 0..250 ms: LED on
							SDcard_error <= '0';
						elsif counter < 25000000 then    -- 250..500 ms: LED off
							SDcard_error <= '1';
						else                              -- end of one blink
							counter <= 0;
							blink_remaining <= blink_remaining - 1;
						end if;
					end if;


				when stop =>
					if ( counter = 50000000 ) then --1s
						SDcard_error <= '0'; --active low
					else
						counter <= counter +1;
					end if;

					
				end case;	
			end if; --rst 
		end if; --rising edge					
	end process;
				
					
    end Behavioral;				
