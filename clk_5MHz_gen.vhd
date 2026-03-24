--
-- generate 5MHz clock 

LIBRARY ieee;
USE ieee.std_logic_1164.all;

	entity clk_5MHz_gen is
		port(
                clk_in  : in std_logic;                
                clk_out : out std_logic
            );
    end clk_5MHz_gen;
	 
   architecture Behavioral of clk_5MHz_gen is
	   signal q_cpuClkCount : integer range 0 to 15;		
    begin
		clk_5MHz_gen: process (clk_in)
			begin
				if rising_edge(clk_in) then
					if q_cpuClkCount < 25 then		
						q_cpuClkCount <= q_cpuClkCount + 1;
					else
						q_cpuClkCount <= 0;
					end if;
					if q_cpuClkCount < 12 then	
						clk_out <= '0';
					else
						clk_out <= '1';
					end if;
				end if;
			end process;
    end Behavioral;				



    