// ============================================================================
// File Name   : sdram_data_path.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM data-path logic connecting the host write data and read capture to the
//   external DQ bus with per-byte mask (DQM) generation.
//
// Parameters  :
//   DataWidth - SDRAM data bus width in bits
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - SDRAM DQ bidirectional data path (lowRISC port naming).
// ============================================================================

module sdr_data_path #(
  parameter int unsigned DataWidth = 16
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic [DataWidth-1:0]         data_in_i,
  input  logic [DataWidth/8-1:0]       dm_i,
  output logic [DataWidth-1:0]         dq_out_o,
  output logic [DataWidth/8-1:0]       dqm_o
);

  assign dq_out_o = data_in_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      dqm_o <= {(DataWidth/8){1'b1}};
    else
      dqm_o <= dm_i;
  end

endmodule
