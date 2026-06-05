// ============================================================================
// File Name   : line_buffer_ram.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Single-port synchronous line buffer intended to infer as M9K block RAM on
//   Cyclone IV. One instance stores either the top or bottom line of a row pair.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   DataWidth - Pixel data width in bits (Default: 12)
//   AddrWidth - Address width (Default: 5)
//   Depth     - Number of entries / pixels per line (Default: 32)
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - Synchronous single-port line buffer RAM.
// ============================================================================

module line_buffer_ram #(
  parameter int unsigned DataWidth = 12,
  parameter int unsigned AddrWidth = 5,
  parameter int unsigned Depth     = 32
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [DataWidth-1:0] wr_data_i,
  input  logic [AddrWidth-1:0] wr_addr_i,
  input  logic                 wr_en_i,

  input  logic [AddrWidth-1:0] rd_addr_i,
  output logic [DataWidth-1:0] rd_data_o
);

  (* ramstyle = "M9K" *)
  logic [DataWidth-1:0] ram_array [0:Depth-1];

  always_ff @(posedge clk_i) begin
    if (wr_en_i) begin
      ram_array[wr_addr_i] <= wr_data_i;
    end
  end

  always_ff @(posedge clk_i) begin
    rd_data_o <= ram_array[rd_addr_i];
  end

endmodule
