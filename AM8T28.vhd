-- Am8T28 Schottky three-state Quad Bus Driver/Receiver
-- part of WillFA7
-- bontango 
-- v1.0
-- with help from chatgpt, which was not much ..

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

 	   if B_E = '0' then -- Bus enable input
			B_out <= (others => '0');
		else
			B_out <= D_in;
      end if;
		
      if R_E = '1' then -- Receiver enable input
			R_out <= (others => '0');
		else
			R_out <= B_in;
      end if;
		
    end process;

end RTL;