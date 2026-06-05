# Timing constraints for buffer_controller_bist_top (DE2-115)
#
# This project is single-clock (50 MHz board oscillator) and does not use the
# SDRAM PLL domain. Keep constraints focused so STA reports are clean.

# 50 MHz board oscillator
create_clock -name clk_50mhz -period 20.000 [get_ports clk_50mhz]

# Derived uncertainty for setup/hold analysis on this clock domain
derive_clock_uncertainty

# SignalTap/JTAG clock (altera_reserved_tck) is unrelated to user logic clock.
# Cut cross-domain analysis between debug and functional domains.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_50mhz}] \
    -group [get_clocks {altera_reserved_tck}]

# Asynchronous push-buttons are synchronized in RTL before use
set_false_path -from [get_ports {btn_start btn_reset}]

# LED output is non-timing-critical for functional verification
set_false_path -to [get_ports {led_status}]
