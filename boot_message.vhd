-- boot message on Williams Display
-- part of  WillFA7
-- bontango 12.2022
--
-- v 1.0
-- v1.1 with error message at display4
-- v1.2 time adapted

LIBRARY ieee;
USE ieee.std_logic_1164.all;

package instruction_buffer_type is
	type DISPLAY_T is array (0 to 5) of std_logic_vector(3 downto 0);
	type DISPLAY_TS is array (0 to 3) of std_logic_vector(3 downto 0);
end package instruction_buffer_type;

LIBRARY ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

use work.instruction_buffer_type.all;

    entity boot_message is        
        port(
            clk  : in std_logic;             
				show   : in  std_logic;		
				is_error  : in  std_logic;		--active low
				-- input (display data)
			   display1			: in  DISPLAY_T;
				display2			: in  DISPLAY_T;
				display3			: in  DISPLAY_T;
				display4			: in  DISPLAY_T;
				error_disp4		: in  DISPLAY_T;
				status_d			: in  DISPLAY_TS;				
				--output (display control)
				strobe: out 	std_logic_vector(3 downto 0);
				bcd: out 	std_logic_vector(7 downto 0)				
            );
    end boot_message;
    ---------------------------------------------------
    architecture Behavioral of boot_message is
		  signal count : integer range 0 to 50001 := 0;
		  signal digit : integer range 0 to 15 := 0;
		  signal phase : integer range 0 to 23 := 0;

	 begin
	
  boot_message: process (clk, show, is_error)
    begin
			if ( show = '0') then  -- Asynchronous reset
				--   output and variable initialisation
				strobe <= "0000";
				bcd <= "11111111";
				count <= 0;
				digit <= 0;
				phase <= 0;

			elsif rising_edge(clk) then
				-- inc count for next round
				-- 50MHz input we have a clk each 20ns
				-- phases are 56uS which is a count of 2800
				-- first phase bcd 0xff (anti flicker)
				-- then 19 phases with digit 
				-- results in 1,1mS per digit strobe
				count <= count +1;
				if ( count = 2800) then 					     
					phase <= phase +1;
					count <= 0;
				end if;	
				if ( phase > 19 ) then
					strobe <= std_logic_vector( to_unsigned((digit +1),4));
					phase <= 0;
					-- overflow?
					if ( digit = 15) then
						digit <= 0;
						strobe <= "0000";
					else
						digit <= digit +1;
					end if;	
				end if;
				
				case digit is 		
				when 0 to 5 => 		
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
					else
							bcd(7 downto 4) <= display1( digit); -- player 1 
					end if;
					if ( phase = 0) then
							bcd(3 downto 0) <= "1111";
					else
							bcd(3 downto 0) <= display3( digit); -- player 3
					end if;
										
				when 6 =>
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
							bcd(3 downto 0) <= "1111"; -- RTH 
					else
							bcd(7 downto 4) <= status_d(3); -- status 0										
							bcd(3 downto 0) <= status_d(3); -- RTH
					end if;			
						
				when 7 =>
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
							bcd(3 downto 0) <= "1111"; -- RTH 
					else
							bcd(7 downto 4) <= status_d(2); -- status 1
							bcd(3 downto 0) <= status_d(2); -- RTH
					end if;			
			
			
				when 8 to 13 => 	
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
					else
							bcd(7 downto 4) <= display2( digit - 8 ); -- player 2 
					end if;		
					
					if ( phase = 0) then
							bcd(3 downto 0) <= "1111";
					else
						if ( is_error = '0' ) then						
							bcd(3 downto 0) <= error_disp4( digit - 8); -- player 4	
						else	
							bcd(3 downto 0) <= display4( digit - 8); -- player 4	
						end if;	
					end if;					
					
				when 14 =>
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
							bcd(3 downto 0) <= "1111"; --RTH
					else
							bcd(7 downto 4) <= status_d(1); -- status 2
							bcd(3 downto 0) <= status_d(1); -- RTH
					end if;	
					
				when 15 =>
					if ( phase = 0) then
							bcd(7 downto 4) <= "1111";
							bcd(3 downto 0) <= "1111"; --RTH
					else
							bcd(7 downto 4) <= status_d(0); -- status 3
							bcd(3 downto 0) <= status_d(0); -- RTH
					end if;					
					
				--when OTHERS =>
				end case;
			end if; --rising edge		
		end process;
    end Behavioral;