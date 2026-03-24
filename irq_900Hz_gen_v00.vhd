--
-- generate 900 Hz clock for Williams IRQ
-- low pulse is 300us
-- high pulse is 1,8 ms
-- from 500KHz cpu clock 

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity irq_900Hz_gen is
		port(
                clk_in  : in std_logic;                
                clk_out : out std_logic
            );
    end irq_900Hz_gen;
	 
   architecture Behavioral of irq_900Hz_gen is
	   signal q_cpuClkCount : integer range 0 to 1600;		
    begin
		clk_400KHz_gen: process (clk_in)
			begin
				if rising_edge(clk_in) then
					if q_cpuClkCount < 600 then		
						q_cpuClkCount <= q_cpuClkCount + 1;
					else
						q_cpuClkCount <= 0;
					end if;
					if q_cpuClkCount < 300 then	
						clk_out <= '0';
					else
						clk_out <= '1';
					end if;
				end if;
			end process;
    end Behavioral;				



    