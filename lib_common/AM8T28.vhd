-- Am8T28 Schottky three-state Quad Bus Driver/Receiver
-- part of WillFA7
-- bontango 
-- v1.0 with help from chatgpt, which was not much ..
-- v1.2

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity AM8T28 is
    Port (
        
        D_in   : in  STD_LOGIC_VECTOR(3 downto 0); -- Driver inputs
		  
        B_out  : out STD_LOGIC_VECTOR(3 downto 0); -- receiver outputs		  
        B_in  :  in  STD_LOGIC_VECTOR(3 downto 0); -- receiver inputs 

        R_out  : out STD_LOGIC_VECTOR(3 downto 0); -- receiver outputs 

        B_E   : in STD_LOGIC;
        R_E   : in STD_LOGIC

    );
end AM8T28;

architecture RTL of AM8T28 is
begin

    process(D_in, B_in, B_E, R_E)
    begin

 	   if B_E = '1' then -- Bus enable input, enabled high
			B_out <= D_in; --not inverting output			
		else
			B_out <= (others => '1');  -- PIA connected, so '1' when in 'Z' state
      end if;
		
      if R_E = '0' then -- Receiver enable input, enabled low
			R_out <= B_in;	--not inverting output							
		else
			R_out <= (others => '0'); -- LEDs connected, so '0' when in 'Z' state
      end if;
		
    end process;

end RTL;