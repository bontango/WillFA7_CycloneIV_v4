--
-- generate 900 Hz clock for WillFA7 'read the dips'
-- from 984KHz cpu clock 

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity clk_900Hz_gen is
		port(
                clk_in  : in std_logic;                
                clk_out : out std_logic
            );
    end clk_900Hz_gen;
	 
   architecture Behavioral of clk_900Hz_gen is
	   signal q_cpuClkCount : integer range 0 to 1600;		
    begin
		clk_400KHz_gen: process (clk_in)
			begin
				if rising_edge(clk_in) then
					if q_cpuClkCount < 968 then		
						q_cpuClkCount <= q_cpuClkCount + 1;
					else
						q_cpuClkCount <= 0;
					end if;
					if q_cpuClkCount < 484 then	
						clk_out <= '0';
					else
						clk_out <= '1';
					end if;
				end if;
			end process;
    end Behavioral;				



    