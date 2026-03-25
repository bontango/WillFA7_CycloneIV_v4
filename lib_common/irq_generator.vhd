-- generate IRQ
-- based on counter IC 4020
--
--for use in WillFA
--bontango 01.2023
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity irq_generator is
    Port ( 
			clk : in  STD_LOGIC;
			cpu_irq : in  STD_LOGIC;
			gen_irq : out  STD_LOGIC
			 );
end irq_generator;


architecture Behavioral of irq_generator is
signal MR	: STD_LOGIC; -- Master reset
signal Q5	: STD_LOGIC;
signal Q7	: STD_LOGIC;
signal Q8	: STD_LOGIC;
signal Q9	: STD_LOGIC;
signal counter : STD_LOGIC_VECTOR(13 downto 0) := (others => '0');


begin

Q5 <= counter(5);
Q7 <= counter(7);
Q8 <= counter(8);
Q9 <= counter(9);

count_process: process(clk, MR)
 begin
	if MR = '1' then --Reset condidition (reset_h)  async reset  
		counter <= (others => '0');
	elsif falling_edge(CLK) then
		counter <= counter + 1;
  end if;
 end process;

MR <= not(  not cpu_irq or (not Q5));
gen_irq <= ( Q7 and Q8 and Q9);


end Behavioral;