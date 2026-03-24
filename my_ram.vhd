-- fpga4student.com: FPGA projects, Verilog projects, VHDL projects 
-- VHDL project: VHDL code for a single-port RAM 
--
-- Assignments => Settings => Analysis & Synthesis Settings => More Settings => Auto RAM Replacement to off. 
--
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
USE ieee.numeric_std.ALL;

-- A 1024x8 single-port RAM in VHDL using logic cells
entity logic_ram is
port(
 address: in std_logic_vector(9 downto 0); -- Address to write/read RAM
 data: in std_logic_vector(7 downto 0); -- Data to write into RAM
 wren: in std_logic; -- Write enable 
 clock: in std_logic; -- clock input for RAM
 q: out std_logic_vector(7 downto 0) -- Data output of RAM
);
end logic_ram;

architecture Behavioral of logic_ram is
-- First, declare a signal that represents a RAM 
--type memory_t is array (0 to 1023) of std_logic_vector(0 to 7);
type memory_t is array (0 to 128) of std_logic_vector(0 to 7);
signal my_ram : memory_t;
attribute ramstyle : string;
attribute ramstyle of my_ram : signal is "logic";
--https://www.intel.com/content/www/us/en/programmable/quartushelp/17.0/hdl/vhdl/vhdl_file_dir_ram.htm


begin
process(clock)
begin
 if(rising_edge(clock)) then
 if(wren='1') then -- when write enable = 1, 
 -- write input data into RAM at the provided address
 my_ram(to_integer(unsigned(address))) <= data;
 -- The index of the RAM array type needs to be integer so
 -- converts address from std_logic_vector -> Unsigned -> Interger using numeric_std library
 end if;
 end if;
end process;
 -- Data to be read out 
 q <= my_ram(to_integer(unsigned(address)));
end Behavioral;