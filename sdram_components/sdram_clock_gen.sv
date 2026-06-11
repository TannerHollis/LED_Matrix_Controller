// ============================================================================
// File Name   : sdram_clock_gen.sv
// Project     : LED Matrix Controller
// Description :
//   Board-to-host SDRAM clock generation, instantiated above sdram_controller.
//   pll_100mhz multiplies the DE2-115 50 MHz oscillator by two (100 MHz).
//   Host and SDRAM controller logic use the same PLL output in the current plan.
//
// Dependencies:
//   - pll_100mhz.v (Altera IP)
// ============================================================================

module sdram_clock_gen (
  input  logic clk_board_i,
  input  logic rst_ni,
  output logic clk_host_o,
  output logic clk_sdram_o,
  output logic pll_locked_o
);

  logic pll_clk;

  pll_100mhz pll_inst (
    .areset(1'b0),
    .inclk0(clk_board_i),
    .c0(pll_clk),
    .locked(pll_locked_o)
  );

  assign clk_host_o  = pll_clk;
  assign clk_sdram_o = pll_clk;

endmodule
