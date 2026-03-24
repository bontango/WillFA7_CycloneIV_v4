-- control blanking line
-- input display strobe
-- output
-- blanking after 1sec
-- trigger for cmos/eeprom after 3 secs
-- part of WillFA version
-- bontango 03.01.2023

Library IEEE;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity ctrl_blanking is 
   port(
	    strobe     : in std_logic; -- display strobe (C) clock is appr 120HZ (strobe(2)
		blanking : out  std_logic; -- active low
		trigger :out  std_logic;    -- trigger output, active high
		rst 		: in  STD_LOGIC --reset_l 
   );
end ctrl_blanking;
architecture Behavioral of ctrl_blanking is  
		signal counter : integer range 0 to 1000 := 0;		
begin 
 
 process(strobe, rst)
		begin
			if rst = '0' then --Reset condidition (reset_l)
				 trigger <= '0';				 				 
				 blanking <= '1';				 				 
				 counter <= 0;
			elsif rising_edge(strobe)then				
				if (counter < 1000) then
					counter <= counter +1;								
				end if;
				
				if (counter > 100) then
					blanking <= '0';
				end if;
				
				if (counter > 300) then
					trigger <= '1';
				end if;

				end if;
		end process;
    end Behavioral;				
