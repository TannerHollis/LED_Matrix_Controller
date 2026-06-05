// ============================================================================
// File Name   : memory_arbiter_mock_slave.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Synthesizable mock memory slave for memory_arbiter hardware BIST. Asserts
//   master_mem_ready immediately and returns a deterministic read pattern; writes
//   are acknowledged without storage.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   AddrWidth - Width of the memory address bus (Default: 24)
//   DataWidth - Width of the data bus (Default: 12)
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - Synthesizable mock memory slave for arbiter BIST.
// ============================================================================

module memory_arbiter_mock_slave #(
  parameter int unsigned AddrWidth = 24,
  parameter int unsigned DataWidth = 12
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic                     master_mem_req_i,
  input  logic                     master_mem_write_i,
  input  logic [AddrWidth-1:0]     master_mem_addr_i,
  input  logic [DataWidth-1:0]     master_mem_write_data_i,
  output logic                     master_mem_ready_o,
  output logic [DataWidth-1:0]     master_mem_read_data_o,
  output logic                     master_mem_read_data_valid_o
);

  function automatic logic [DataWidth-1:0] read_pattern(
      input logic [AddrWidth-1:0] addr
  );
    logic [15:0] full;
    begin
      full         = addr[15:0] ^ 16'hA5C3 ^ addr[23:16];
      read_pattern = full[DataWidth-1:0];
    end
  endfunction

  assign master_mem_ready_o = 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      master_mem_read_data_o       <= '0;
      master_mem_read_data_valid_o <= 1'b0;
    end else begin
      master_mem_read_data_valid_o <= 1'b0;
      if (master_mem_req_i && !master_mem_write_i) begin
        master_mem_read_data_o       <= read_pattern(master_mem_addr_i);
        master_mem_read_data_valid_o <= 1'b1;
      end
    end
  end

endmodule
