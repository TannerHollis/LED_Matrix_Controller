// ============================================================================
// File Name   : memory_fetcher.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Memory arbiter client that loads one row pair (top + bottom scan lines)
//   from external memory into line buffers on each start_fetch pulse. Address
//   generation uses row_pair_index from buffer_controller.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   TotalRowWidth, PanelHeight, ColorDepth, RowOffset, TotalDisplayHeight,
//   ReadBurstLen, RowPairCount (derived), RowPairAddrWidth (derived)
//
// Dependencies:
//   - memory_arbiter.sv (client port)
// ============================================================================
// Revision History:
//   Current - Row-pair SDRAM fetch with aligned burst-length column reads.
// ============================================================================

module memory_fetcher #(
  parameter int unsigned TotalRowWidth      = 32,
  parameter int unsigned PanelHeight        = 32,
  parameter int unsigned ColorDepth         = 4,
  parameter int unsigned RowOffset          = 0,
  parameter int unsigned TotalDisplayHeight = 32,
  parameter int unsigned ReadBurstLen       = 8,
  parameter int unsigned RowPairCount       = PanelHeight / 2,
  parameter int unsigned RowPairAddrWidth   = (RowPairCount <= 1) ? 1 : $clog2(RowPairCount)
) (
  input  logic clk_i,
  input  logic rst_ni,

  output logic                                mem_req_o,
  output logic [3:0]                          mem_read_length_o,
  input  logic                                mem_grant_i,
  output logic [$clog2(TotalRowWidth * TotalDisplayHeight) - 1:0] mem_addr_o,
  input  logic [ColorDepth*3-1:0]             mem_read_data_i,
  input  logic                                mem_read_data_valid_i,

  output logic [ColorDepth*3-1:0]             buffer_wr_data_o,
  output logic [$clog2(TotalRowWidth)-1:0]    buffer_wr_addr_o,
  output logic                                buffer_wr_en_o,
  output logic                                buffer_sel_o,
  output logic                                fetch_complete_o,

  input  logic                                start_fetch_i,
  input  logic [RowPairAddrWidth-1:0]         row_pair_index_i,
  input  logic [1:0]                          target_buffer_i,
  output logic                                busy_o
);

  localparam int unsigned BurstLenBits =
      (ReadBurstLen <= 1) ? 1 : $clog2(ReadBurstLen);

  typedef enum logic [2:0] {
    StIdle,
    StReqTop,
    StWaitTop,
    StReqBot,
    StWaitBot
  } fetch_state_e;

  fetch_state_e fetch_state_d, fetch_state_q;

  logic [$clog2(TotalRowWidth)-1:0]    col_idx_q;
  logic [RowPairAddrWidth-1:0]         row_pair_idx_q;
  logic [3:0]                          burst_len_q;
  logic [BurstLenBits-1:0]             burst_idx_q;

  logic [3:0]                          burst_len_calc;

  // Use full ReadBurstLen on 8-pixel-aligned columns; single beat otherwise.
  function automatic logic [3:0] calc_burst_len(
      input logic [$clog2(TotalRowWidth)-1:0] col
  );
    logic [$clog2(TotalRowWidth):0] remaining;
    begin
      remaining = TotalRowWidth - col;
      if (col[2:0] == 3'b000 && remaining >= ReadBurstLen) begin
        calc_burst_len = ReadBurstLen[3:0];
      end else begin
        calc_burst_len = 4'd1;
      end
    end
  endfunction

  initial begin
    if (ReadBurstLen != 1 && ReadBurstLen != 2 && ReadBurstLen != 4 && ReadBurstLen != 8) begin
      $display("ERROR: memory_fetcher ReadBurstLen=%0d; legal values are 1, 2, 4, 8",
               ReadBurstLen);
    end
  end

  always_comb begin
    fetch_state_d        = fetch_state_q;
    mem_req_o            = 1'b0;
    mem_read_length_o    = 4'd1;
    mem_addr_o           = '0;
    buffer_wr_data_o     = mem_read_data_i;
    buffer_wr_addr_o     = '0;
    buffer_wr_en_o       = 1'b0;
    buffer_sel_o         = 1'b0;
    fetch_complete_o     = 1'b0;
    burst_len_calc       = calc_burst_len(col_idx_q);

    unique case (fetch_state_q)
      StIdle: begin
        if (start_fetch_i) begin
          fetch_state_d = StReqTop;
        end
      end

      StReqTop: begin
        mem_req_o         = 1'b1;
        mem_read_length_o = burst_len_calc;
        mem_addr_o        = (RowOffset + row_pair_idx_q) * TotalRowWidth + col_idx_q;
        if (mem_grant_i) begin
          fetch_state_d = StWaitTop;
        end
      end

      StWaitTop: begin
        if (mem_read_data_valid_i) begin
          buffer_wr_en_o   = 1'b1;
          buffer_wr_addr_o = col_idx_q + {{($clog2(TotalRowWidth)-BurstLenBits){1'b0}}, burst_idx_q};
          buffer_sel_o     = 1'b0;

          if (burst_idx_q == (burst_len_q - 4'd1)) begin
            if (col_idx_q >= TotalRowWidth - burst_len_q) begin
              fetch_state_d = StReqBot;
            end else begin
              fetch_state_d = StReqTop;
            end
          end
        end
      end

      StReqBot: begin
        mem_req_o         = 1'b1;
        mem_read_length_o = burst_len_calc;
        mem_addr_o        = (RowOffset + row_pair_idx_q + RowPairCount) * TotalRowWidth + col_idx_q;
        if (mem_grant_i) begin
          fetch_state_d = StWaitBot;
        end
      end

      StWaitBot: begin
        if (mem_read_data_valid_i) begin
          buffer_wr_en_o   = 1'b1;
          buffer_wr_addr_o = col_idx_q + {{($clog2(TotalRowWidth)-BurstLenBits){1'b0}}, burst_idx_q};
          buffer_sel_o     = 1'b1;

          if (burst_idx_q == (burst_len_q - 4'd1)) begin
            if (col_idx_q >= TotalRowWidth - burst_len_q) begin
              fetch_state_d = StIdle;
              fetch_complete_o = 1'b1;
            end else begin
              fetch_state_d = StReqBot;
            end
          end
        end
      end

      default: fetch_state_d = StIdle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_state_q    <= StIdle;
      col_idx_q        <= '0;
      row_pair_idx_q   <= '0;
      burst_len_q      <= 4'd1;
      burst_idx_q      <= '0;
      busy_o           <= 1'b0;
    end else begin
      fetch_state_q <= fetch_state_d;

      if (start_fetch_i && fetch_state_q == StIdle) begin
        col_idx_q      <= '0;
        row_pair_idx_q <= row_pair_index_i;
        busy_o         <= 1'b1;
      end else if (fetch_complete_o) begin
        busy_o <= 1'b0;
      end

      if (fetch_state_q == StReqTop && fetch_state_d == StWaitTop) begin
        burst_len_q <= burst_len_calc;
        burst_idx_q <= '0;
      end else if (fetch_state_q == StReqBot && fetch_state_d == StWaitBot) begin
        burst_len_q <= burst_len_calc;
        burst_idx_q <= '0;
      end else if (fetch_state_q == StWaitTop && mem_read_data_valid_i) begin
        if (burst_idx_q == (burst_len_q - 4'd1)) begin
          burst_idx_q <= '0;
          if (col_idx_q >= TotalRowWidth - burst_len_q) begin
            col_idx_q <= '0;
          end else begin
            col_idx_q <= col_idx_q + burst_len_q;
          end
        end else begin
          burst_idx_q <= burst_idx_q + {{(BurstLenBits-1){1'b0}}, 1'b1};
        end
      end else if (fetch_state_q == StWaitBot && mem_read_data_valid_i) begin
        if (burst_idx_q == (burst_len_q - 4'd1)) begin
          burst_idx_q <= '0;
          if (col_idx_q < TotalRowWidth - burst_len_q) begin
            col_idx_q <= col_idx_q + burst_len_q;
          end
        end else begin
          burst_idx_q <= burst_idx_q + {{(BurstLenBits-1){1'b0}}, 1'b1};
        end
      end
    end
  end

endmodule
