    # 
	# https://forums.intel.com/s/question/0D50P00003yyTEnSAM/getting-timing-requirements-not-met-as-critical-warning?language=de
	#
    #  Design Timing Constraints Definitions
    # 
    set_time_format -unit ns -decimal_places 3
    # #############################################################################
    #  Create Input reference clocks
    create_clock -name {clk_50} -period 20.000 -waveform { 0.000 10.000 } [get_ports {clk_50}]	
    # #############################################################################
	#Here I create a clock called "clkin_50" (you can name it whatever you like), 
	#specify that it is 50MHz (20ns period), specify it is 50% duty cycle
	#(rising edge at 0ns, falling edge at 10ns), and instruct that the port 
	#that the clock is located at (e.g. FPGA pin) is called "clkin_50" via the "[get_ports ]" command. 
	#The clock name doesn't have to match the port name, but I find it useful to do so.
	#
	# generated clocks (400KHz CPU clock)
	# create_generated_clock -name cpu_clk -divide_by 125 -source clk_50 cpu_clk_gen:clock_gen|cpu_clk_out
	

	#create_clock -name {cpu_clk} -period 1118.880 -waveform { 0.000 559.440 } [get_registers {cpu_clk}]
    #  Now that we have created the custom clocks which will be base clocks,
    #  derive_pll_clock is used to calculate all remaining clocks for PLLs
    
	derive_pll_clocks -create_base_clocks
   derive_clock_uncertainty

	# cpu_clk: PLL c0 (14.28 MHz) divided by 16 -> ~894 KHz
	create_generated_clock -name cpu_clk \
		-source [get_pins {PLL|altpll_component|auto_generated|pll1|clk[0]}] \
		-divide_by 16 \
		[get_registers {cpu_clk_gen:clock_gen|clk_out}]

	# mem_clk: phase-shifted cpu_clk, same divide from PLL c0
	create_generated_clock -name mem_clk \
		-source [get_pins {PLL|altpll_component|auto_generated|pll1|clk[0]}] \
		-divide_by 16 \
		[get_registers {cpu_clk_gen:clock_gen|shift_clk_out}]

	# flipflop clk_div2: cpu_clk divided by 2
	create_generated_clock -name ff_sols_clk_div2 \
		-source [get_registers {cpu_clk_gen:clock_gen|clk_out}] \
		-divide_by 2 \
		[get_registers {flipflops:FF_SOLS|clk_div2}]

	create_generated_clock -name ff_lamps_clk_div2 \
		-source [get_registers {cpu_clk_gen:clock_gen|clk_out}] \
		-divide_by 2 \
		[get_registers {flipflops:FF_LAMPSS|clk_div2}]
	
	#
	# example second clock
	#create_clock -name {clk} -period 400.000 -waveform { 0.000 200.000 } [get_registers {clk}]
	#
	# if output clock pins exist
	#
	# Create a generated clock: -name = name of new clock, -divide_by = output frequency is input divided by this, 
	# -source = original clock, then end of line is the target signal where output clock is.
	#
	
	# Cross-clock domain: clk_50 and cpu_clk/mem_clk are asynchronous.
	# Domain crossings are handled by Cross_Slow_To_Fast_Clock synchronizers.
	set_clock_groups -asynchronous \
		-group {clk_50} \
		-group {cpu_clk mem_clk ff_sols_clk_div2 ff_lamps_clk_div2}

	# Constrain IOs (don't care...)
	set_input_delay -clock clk_50 0 [all_inputs]
	set_output_delay -clock clk_50 0 [all_outputs]