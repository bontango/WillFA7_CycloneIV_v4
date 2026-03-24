-- scan up to three 8bit inputs
-- and set flip flop accordently
-- part of  WillFA7
-- bontango 12.2022
--
-- v 1.0
-- 895KHz input clock

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity flipflops is        
        port(
            clk_in  : in std_logic;               						
				rst		: in std_logic;   
				--output 
				sel1			: out std_logic;
				sel2			: out std_logic;
				sel3			: out std_logic;				
				ff_data_out		: out std_logic_vector(7 downto 0);				
				-- input
				ff1_data_in		: in std_logic_vector(7 downto 0);				
				ff2_data_in		: in std_logic_vector(7 downto 0);				
				ff3_data_in		: in std_logic_vector(7 downto 0)				
            );
    end flipflops;
    ---------------------------------------------------
    architecture Behavioral of flipflops is
	 	type STATE_T is ( Start, Check1, Check2, Check3, Set1, Set2, Set3, Clear1, Clear2, Clear3 ); 
		signal state : STATE_T := Start;    
		signal old_ff1_data : std_logic_vector(7 downto 0);				
		signal old_ff2_data : std_logic_vector(7 downto 0);				
		signal old_ff3_data : std_logic_vector(7 downto 0);				
	begin
	
	
	 flipflops: process (clk_in, rst, ff1_data_in, ff2_data_in, ff3_data_in)
    begin
		if rising_edge(clk_in) then			
			if rst = '1' then --Reset condidition (reset_h)    
			  state <= Start;
			  sel1 <= '0';
			  sel2 <= '0';
			  sel3 <= '0';
			  old_ff1_data <= "00000000";
			  old_ff2_data <= "00000000";
			  old_ff3_data <= "00000000";
			else
				case state is
					when Start =>
					   -- Todo set all output to '0' upon start
						state <= Check1;						
					when Check1 =>
						if ( ff1_data_in /= old_ff1_data) then
							ff_data_out <= ff1_data_in;
							old_ff1_data <= ff1_data_in;
							state <= Set1;
						else
							state <= Check2;
						end if;
					when Check2 =>
						if ( ff2_data_in /= old_ff2_data) then
							ff_data_out <= ff2_data_in;
							old_ff2_data <= ff2_data_in;
							state <= Set2;
						else
							state <= Check3;
						end if;
					when Check3 =>
						if ( ff3_data_in /= old_ff3_data) then
							ff_data_out <= ff3_data_in;
							old_ff3_data <= ff3_data_in;
							state <= Set3;
						else
							state <= Check1;
						end if;						
					-- set/unset data with clk
					when  Set1 =>
						sel1 <= '1';
						state <= Clear1;						
					when  Clear1 =>
						sel1 <= '0';
						state <= Check2;
					when  Set2 =>
						sel2 <= '1';
						state <= Clear2;						
					when  Clear2 =>
						sel2 <= '0';
						state <= Check3;
					when  Set3 =>
						sel3 <= '1';
						state <= Clear3;						
					when  Clear3 =>
						sel3 <= '0';
						state <= Check1;											
				end case;
			end if; --reset				
		end if;	--rising edge		
		end process;
    end Behavioral;