# LED Panel Controller - Clock Constraints
# Created for Quartus Prime 24.1

# =============================================================================
# CLOCK DEFINITIONS
# =============================================================================

# Main system clock (50MHz = 20ns period)
create_clock -name "clk" -period 20.000 -waveform {0 10} [get_ports clk]

# SPI clock (external, asynchronous to system clock)
# This is typically much slower than the system clock
create_clock -name "spi_sclk" -period 1000.000 -waveform {0 500} [get_ports spi_sclk]

# =============================================================================
# CLOCK GROUPS AND RELATIONSHIPS
# =============================================================================

# Define clock groups for asynchronous clocks
set_clock_groups -asynchronous \
    -group {clk} \
    -group {spi_sclk}

# =============================================================================
# TIMING CONSTRAINTS
# =============================================================================

# Input delay constraints
# These define when input signals are valid relative to the clock
set_input_delay -clock clk -max 2.000 [get_ports reset_n]
set_input_delay -clock clk -max 2.000 [get_ports spi_cs_n]
set_input_delay -clock clk -max 2.000 [get_ports spi_mosi]

# Ethernet interface input delays
set_input_delay -clock clk -max 2.000 [get_ports eth_rx_data]
set_input_delay -clock clk -max 2.000 [get_ports eth_rx_dv]
set_input_delay -clock clk -max 2.000 [get_ports eth_rx_er]
set_input_delay -clock clk -max 2.000 [get_ports eth_tx_er]
set_input_delay -clock clk -max 2.000 [get_ports eth_crs]
set_input_delay -clock clk -max 2.000 [get_ports eth_col]

# Output delay constraints
# These define when output signals need to be stable
set_output_delay -clock clk -max 2.000 [get_ports spi_miso]
set_output_delay -clock clk -max 2.000 [get_ports eth_tx_data]
set_output_delay -clock clk -max 2.000 [get_ports eth_tx_en]

# LED panel output delays (these are arrays)
set_output_delay -clock clk -max 2.000 [get_ports panel_r1*]
set_output_delay -clock clk -max 2.000 [get_ports panel_g1*]
set_output_delay -clock clk -max 2.000 [get_ports panel_b1*]
set_output_delay -clock clk -max 2.000 [get_ports panel_r2*]
set_output_delay -clock clk -max 2.000 [get_ports panel_g2*]
set_output_delay -clock clk -max 2.000 [get_ports panel_b2*]
set_output_delay -clock clk -max 2.000 [get_ports panel_addr*]
set_output_delay -clock clk -max 2.000 [get_ports panel_clk*]
set_output_delay -clock clk -max 2.000 [get_ports panel_lat*]
set_output_delay -clock clk -max 2.000 [get_ports panel_oe*]

# =============================================================================
# FALSE PATHS
# =============================================================================

# Mark asynchronous paths as false paths
# These are paths that don't need to meet timing requirements

# SPI interface is asynchronous
set_false_path -from [get_ports spi_sclk]
set_false_path -from [get_ports spi_cs_n]
set_false_path -from [get_ports spi_mosi]
set_false_path -to [get_ports spi_miso]

# Reset is asynchronous
set_false_path -from [get_ports reset_n]

# =============================================================================
# CLOCK UNCERTAINTY
# =============================================================================

# Add clock uncertainty for more realistic timing analysis
set_clock_uncertainty -from clk -to clk 0.100
set_clock_uncertainty -from spi_sclk -to spi_sclk 0.500

# =============================================================================
# CLOCK DOMAIN CROSSING (CDC) CONSTRAINTS
# =============================================================================

# Mark CDC paths for proper handling
# These are paths between different clock domains

# SPI to system clock crossing
set_false_path -from [get_clocks spi_sclk] -to [get_clocks clk]
set_false_path -from [get_clocks clk] -to [get_clocks spi_sclk]

# =============================================================================
# NOTES AND COMMENTS
# =============================================================================

# This SDC file provides basic timing constraints for the LED Panel Controller
# 
# Key considerations:
# 1. Adjust clock frequencies based on your target FPGA and requirements
# 2. Modify input/output delays based on your board's timing requirements
# 3. Add more specific constraints as needed for your application
# 4. Consider adding generated clock constraints if using PLLs or clock dividers
# 5. Review and adjust multicycle paths based on your design's actual timing needs
#
# For production use:
# - Validate all timing constraints with your specific hardware
# - Test with actual LED panels to ensure proper timing
# - Consider adding more specific constraints for DDR memory interface
# - Add constraints for any external memory controllers or IP cores 