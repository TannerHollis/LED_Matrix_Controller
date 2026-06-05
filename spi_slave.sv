// ============================================================================
// File Name   : spi_slave.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Parameterized SPI Mode 0 (CPOL=0, CPHA=0) slave. Shifts Width bits on rising
//   sclk edges while cs_n is low and pulses data_valid for one clk when complete.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   Width - Serial word width in bits (Default: 8)
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - SPI mode-0 slave byte receiver.
// ============================================================================

module spi_slave #(
  parameter int unsigned Width = 8
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic spi_sclk_i,
  input  logic spi_cs_ni,
  input  logic spi_mosi_i,
  // output logic spi_miso_o, // MISO is handled upstream by the command processor/arbiter

  output logic [Width-1:0] data_o,
  output logic             data_valid_o
);

  localparam int unsigned BitCounterWidth = $clog2(Width) + 1;

  logic [Width-1:0]       shift_reg_q;
  logic [BitCounterWidth-1:0] bit_counter_q;
  logic                   sclk_rising_edge;
  logic                   sclk_prev_q;
  logic                   cs_n_prev_q;

  always_ff @(posedge clk_i) begin
    sclk_prev_q        <= spi_sclk_i;
    sclk_rising_edge   <= ~sclk_prev_q & spi_sclk_i;
    cs_n_prev_q        <= spi_cs_ni;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_o          <= '0;
      data_valid_o    <= 1'b0;
      shift_reg_q     <= '0;
      bit_counter_q   <= '0;
    end else begin
      data_valid_o <= 1'b0;

      if (~spi_cs_ni && cs_n_prev_q) begin
        bit_counter_q <= '0;
        shift_reg_q   <= '0;
      end

      if (~spi_cs_ni && sclk_rising_edge) begin
        if (bit_counter_q < Width) begin
          shift_reg_q   <= {shift_reg_q[Width-2:0], spi_mosi_i};
          bit_counter_q <= bit_counter_q + {{(BitCounterWidth-1){1'b0}}, 1'b1};
        end
      end

      if (bit_counter_q == Width) begin
        data_o        <= shift_reg_q;
        data_valid_o  <= 1'b1;
        bit_counter_q <= '0;
      end
    end
  end

endmodule
