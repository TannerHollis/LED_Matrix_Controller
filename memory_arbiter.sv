// ============================================================================
// File Name   : memory_arbiter.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Fixed-priority multi-client arbiter for a single-port, high-latency memory
//   system. High-priority clients (streaming) preempt low-priority clients and
//   the master interface tracks controller ready/read-valid handshaking.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   NumClients, NumLowPriClients, AddrWidth, DataWidth
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - Fixed-priority arbitration with multi-beat read grant hold and cooldown.
// ============================================================================

module memory_arbiter #(
  parameter int unsigned NumClients         = 2,
  parameter int unsigned NumLowPriClients   = 1,
  parameter int unsigned AddrWidth          = 32,
  parameter int unsigned DataWidth          = 64
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [NumClients-1:0]            client_mem_req_i,
  input  logic [NumClients-1:0]            client_mem_write_i,
  input  logic [AddrWidth*NumClients-1:0]  client_mem_addr_i,
  input  logic [DataWidth*NumClients-1:0]  client_mem_write_data_i,
  input  logic [4*NumClients-1:0]          client_mem_read_length_i,
  input  logic [4*NumClients-1:0]          client_mem_write_length_i,
  output logic [NumClients-1:0]            client_mem_grant_o,
  output logic [DataWidth*NumClients-1:0]    client_mem_read_data_o,
  output logic [NumClients-1:0]              client_mem_read_data_valid_o,

  output logic                     master_mem_req_o,
  output logic                     master_mem_write_o,
  output logic [AddrWidth-1:0]     master_mem_addr_o,
  output logic [DataWidth-1:0]     master_mem_write_data_o,
  output logic [3:0]               master_mem_read_length_o,
  output logic [3:0]               master_mem_write_length_o,
  input  logic                     master_mem_ready_i,
  input  logic [DataWidth-1:0]     master_mem_read_data_i,
  input  logic                     master_mem_read_data_valid_i
);

  localparam int unsigned ClientIdxWidth =
      $clog2(NumClients == 1 ? 2 : NumClients);

  logic [ClientIdxWidth-1:0] granted_client_idx;
  logic [ClientIdxWidth-1:0] active_client_idx_q;
  logic request_in_progress_q;
  logic read_pending_q;
  logic active_is_write_q;
  logic grant_cooldown_q;
  logic [3:0] active_read_length_q;
  logic [3:0] burst_beats_remaining_q;

  logic master_mem_req_comb;
  logic master_mem_write_comb;
  logic [AddrWidth-1:0] master_mem_addr_comb;
  logic [DataWidth-1:0] master_mem_write_data_comb;
  logic [3:0] master_mem_read_length_comb;
  logic [3:0] master_mem_write_length_comb;
  logic [ClientIdxWidth:0] grant_sel_i;

  always_comb begin
    master_mem_req_comb          = 1'b0;
    master_mem_write_comb        = 1'b0;
    master_mem_addr_comb         = {AddrWidth{1'b0}};
    master_mem_write_data_comb   = {DataWidth{1'b0}};
    master_mem_read_length_comb  = 4'd1;
    master_mem_write_length_comb = 4'd1;
    granted_client_idx           = '0;

    for (grant_sel_i = NumLowPriClients[ClientIdxWidth:0];
         grant_sel_i < NumClients[ClientIdxWidth:0];
         grant_sel_i = grant_sel_i + 1'b1) begin
      if (client_mem_req_i[grant_sel_i[ClientIdxWidth-1:0]]) begin
        master_mem_req_comb          = 1'b1;
        master_mem_write_comb        = client_mem_write_i[grant_sel_i[ClientIdxWidth-1:0]];
        master_mem_addr_comb         =
            client_mem_addr_i[grant_sel_i[ClientIdxWidth-1:0]*AddrWidth +: AddrWidth];
        master_mem_write_data_comb   =
            client_mem_write_data_i[grant_sel_i[ClientIdxWidth-1:0]*DataWidth +: DataWidth];
        master_mem_read_length_comb  =
            client_mem_read_length_i[grant_sel_i[ClientIdxWidth-1:0]*4 +: 4];
        master_mem_write_length_comb =
            client_mem_write_length_i[grant_sel_i[ClientIdxWidth-1:0]*4 +: 4];
        granted_client_idx           = grant_sel_i[ClientIdxWidth-1:0];
      end
    end

    if (master_mem_req_comb == 1'b0) begin
      for (grant_sel_i = '0;
           grant_sel_i < NumLowPriClients[ClientIdxWidth:0];
           grant_sel_i = grant_sel_i + 1'b1) begin
        if (client_mem_req_i[grant_sel_i[ClientIdxWidth-1:0]]) begin
          master_mem_req_comb          = 1'b1;
          master_mem_write_comb        = client_mem_write_i[grant_sel_i[ClientIdxWidth-1:0]];
          master_mem_addr_comb         =
              client_mem_addr_i[grant_sel_i[ClientIdxWidth-1:0]*AddrWidth +: AddrWidth];
          master_mem_write_data_comb   =
              client_mem_write_data_i[grant_sel_i[ClientIdxWidth-1:0]*DataWidth +: DataWidth];
          master_mem_read_length_comb  =
              client_mem_read_length_i[grant_sel_i[ClientIdxWidth-1:0]*4 +: 4];
          master_mem_write_length_comb =
              client_mem_write_length_i[grant_sel_i[ClientIdxWidth-1:0]*4 +: 4];
          granted_client_idx           = grant_sel_i[ClientIdxWidth-1:0];
        end
      end
    end
  end

  always_comb begin
    master_mem_req_o             = grant_cooldown_q ? 1'b0 : master_mem_req_comb;
    master_mem_write_o           = grant_cooldown_q ? 1'b0 : master_mem_write_comb;
    master_mem_addr_o            = grant_cooldown_q ? {AddrWidth{1'b0}} : master_mem_addr_comb;
    master_mem_write_data_o      = grant_cooldown_q ? {DataWidth{1'b0}} : master_mem_write_data_comb;
    master_mem_read_length_o     = grant_cooldown_q ? 4'd1 : master_mem_read_length_comb;
    master_mem_write_length_o    = grant_cooldown_q ? 4'd1 : master_mem_write_length_comb;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      request_in_progress_q   <= 1'b0;
      read_pending_q          <= 1'b0;
      active_client_idx_q     <= '0;
      active_is_write_q       <= 1'b0;
      grant_cooldown_q        <= 1'b0;
      active_read_length_q    <= 4'd1;
      burst_beats_remaining_q <= 4'd0;
    end else begin
      if (grant_cooldown_q) begin
        grant_cooldown_q <= 1'b0;
      end

      if (master_mem_read_data_valid_i) begin
        if (burst_beats_remaining_q <= 4'd1) begin
          read_pending_q   <= 1'b0;
          grant_cooldown_q <= 1'b1;
        end
        burst_beats_remaining_q <= burst_beats_remaining_q - 4'd1;
      end

      if (request_in_progress_q && master_mem_ready_i) begin
        request_in_progress_q <= 1'b0;
        if (active_is_write_q) begin
          grant_cooldown_q <= 1'b1;
        end else begin
          read_pending_q          <= 1'b1;
          burst_beats_remaining_q <= active_read_length_q;
        end
      end else if (!request_in_progress_q && !read_pending_q && !grant_cooldown_q &&
                   master_mem_req_comb) begin
        request_in_progress_q <= 1'b1;
        active_client_idx_q   <= granted_client_idx;
        active_is_write_q     <= master_mem_write_comb;
        active_read_length_q  <= master_mem_read_length_comb;
      end
    end
  end

  assign client_mem_grant_o = (request_in_progress_q && master_mem_ready_i) ?
      (1'b1 << active_client_idx_q) : {NumClients{1'b0}};

  genvar j;
  generate
    for (j = 0; j < NumClients; j = j + 1) begin : gen_read_routing
      assign client_mem_read_data_o[j*DataWidth +: DataWidth] =
          (active_client_idx_q == j[ClientIdxWidth-1:0]) ? master_mem_read_data_i :
          {DataWidth{1'b0}};
      assign client_mem_read_data_valid_o[j] =
          (active_client_idx_q == j[ClientIdxWidth-1:0] && master_mem_read_data_valid_i) ?
          1'b1 : 1'b0;
    end
  endgenerate

endmodule
