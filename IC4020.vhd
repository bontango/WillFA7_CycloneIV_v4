--IC4020
--
--for use in WillFA
--output Q5,Q7,Q8,Q9 only
--bontango 01.2023
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity IC4020 is
    Port ( CLK : in  STD_LOGIC;
			MR : IN  STD_LOGIC; -- MASTER reset
         Q5 : out  STD_LOGIC;
			Q7 : out  STD_LOGIC;
			Q8 : out  STD_LOGIC;
			Q9 : out  STD_LOGIC
			 );
end IC4020;


architecture Behavioral of IC4020 is

signal counter : STD_LOGIC_VECTOR(13 downto 0) := (others => '0');


begin

Q5 <= counter(5);
Q7 <= counter(7);
Q8 <= counter(8);
Q9 <= counter(9);

count_process: process(CLK, MR)
 begin
	if MR = '1' then --Reset condidition (reset_h)  async reset  
		counter <= (others => '0');
	elsif falling_edge(CLK) then
		counter <= counter + 1;
  end if;
 end process;


end Behavioral;