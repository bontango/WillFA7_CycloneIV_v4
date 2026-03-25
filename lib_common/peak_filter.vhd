-- peak filter
-- bontango 11.2024
-- filter unwanted peaks in signal 
-- part of WillFA7
--
-- v 0.1
-- 895KHz input clock ( 1,1uS cycle )

LIBRARY ieee;
USE ieee.std_logic_1164.all;

    entity peak_filter is       
	   generic ( 
              max_peak_len   : integer   :=   10        -- max. peak lenght we filter out
             ); 
        port(
         clk_in  : in std_logic;    
		 i_Rst_L : in std_logic;		 
		 sig_in : in std_logic;
		 sig_out : out std_logic
            );
    end peak_filter;
    ---------------------------------------------------
    architecture Behavioral of peak_filter is
	 	type STATE_T is ( st_wait4high, st_counting, st_wait4low ); 
		signal state : STATE_T := st_wait4high;     
		signal counter : integer;
	begin
	
	
	 peak_filter: process (clk_in, i_Rst_L, sig_in)
    begin
		if rising_edge(clk_in) then			
			if i_Rst_L = '0' then --Reset condidition (reset_l)    
			  state <= st_wait4high;
			  counter <= 0;
			  sig_out <= '0';
			else
				case state is
					when st_wait4high =>
					   if ( sig_in = '1') then
							counter <= 0;					   
							state <= st_counting;							
						end if;					
						
					when st_counting =>
					   if ( sig_in = '1') then
							counter <= counter +1;						
							if ( counter = max_peak_len) then 
								counter <= 0;
								sig_out <= '1';
								state <= st_wait4low; 
							end if;
						else -- sig_in is low again before max_peak_len => sig_out unchanged
							counter <= 0;
							state <= st_wait4high;	
						end if;					
					
					when st_wait4low =>
					   if ( sig_in = '0') then
							sig_out <= '0';
							state <= st_wait4high;
						end if;
						
				end case;
			end if; --reset				
		end if;	--rising edge		
		end process;
    end Behavioral;