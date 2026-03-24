-- boot message on Williams Display
-- part of  WillFA7
-- bontango 12.2022
--
-- v 1.0
-- 200KHz input clock

LIBRARY ieee;
USE ieee.std_logic_1164.all;

package instruction_buffer_type is
	type DISPLAY_T is array (0 to 5) of std_logic_vector(3 downto 0);
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
				-- input (display data)
			   display1			: in  DISPLAY_T;
				display2			: in  DISPLAY_T;
				display3			: in  DISPLAY_T;
				display4			: in  DISPLAY_T;
				status_d			: in  DISPLAY_T;				
				--output (display control)
				strobe: out 	std_logic_vector(3 downto 0);
				bcd: out 	std_logic_vector(7 downto 0)				
            );
    end boot_message;
    ---------------------------------------------------
    architecture Behavioral of boot_message is
		  signal count : integer range 0 to 50001 := 0;
		  signal digit : integer range 0 to 15 := 0;

	 begin
	
  boot_message: process (clk, show)
    begin
			if ( show = '0') then  -- Asynchronous reset
				--   output and variable initialisation
				strobe <= "0000";
				bcd <= "11111111";
				count <= 0;
				digit <= 0;

			elsif rising_edge(clk) then
				-- inc count for next round
				-- 50MHz input we have a clk each 20ns
				-- new refresh after 1ms, which is a count of 50.000
				count <= count +1;
				if ( count = 50000) then 					     
					strobe <= std_logic_vector( to_unsigned((digit +1),4));
					count <= 0;
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
					bcd(3 downto 0) <= display1( 5 - digit); -- player 1 ( digits 5 ...0 reverse order )
					bcd(7 downto 4) <= display3( 5 - digit); -- player 3
				when 6 =>
					bcd(3 downto 0) <= status_d(0); -- status 0										
				when 7 =>
					bcd(3 downto 0) <= status_d(1); -- status 1
				when 8 to 13 => 					
					bcd(3 downto 0) <= display2( 13 - digit ); -- player 2 ( digits 5 ...0 reverse order )
					bcd(7 downto 4) <= display4( 13 - digit ); -- player 4	
				when 14 =>
					bcd(3 downto 0) <= status_d(2); -- status 2
				when 15 =>
					bcd(3 downto 0) <= status_d(3); -- status 3
					
				--when OTHERS =>
				end case;
			end if; --rising edge		
		end process;
    end Behavioral;