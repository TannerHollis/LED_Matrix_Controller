// ============================================================================
// File Name   : buffer_controller.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Ping-pong line-buffer scheduler for the LED panel driver. Each buffer set
//   stores one row pair (top + bottom scan lines). Priming fills set 0 then set 1;
//   steady-state buffer swaps and SDRAM refetches are paced by row_pair_done.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   TotalRowWidth, PanelHeight, ColorDepth, AddrWidth (derived),
//   RowPairCount (derived), RowPairAddrWidth (derived)
//
// Dependencies:
//   - line_buffer_ram.sv (instantiated by led_panel_driver)
// ============================================================================
// Revision History:
//   Current - Ping-pong line-buffer scheduling paced by row_pair_done.
// ============================================================================

module buffer_controller #(
  parameter int unsigned TotalRowWidth      = 32,
  parameter int unsigned PanelHeight        = 32,
  parameter int unsigned ColorDepth         = 4,
  parameter int unsigned AddrWidth          = (TotalRowWidth <= 1) ? 1 : $clog2(TotalRowWidth),
  parameter int unsigned RowPairCount       = PanelHeight / 2,
  parameter int unsigned RowPairAddrWidth   = (RowPairCount <= 1) ? 1 : $clog2(RowPairCount)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Memory Fetcher Interface
  input  logic                            fetch_complete_i,
  input  logic                            fetch_busy_i,
  output logic                            start_fetch_o,
  output logic [RowPairAddrWidth-1:0]     fetch_row_pair_index_o,
  input  logic [(ColorDepth*3)-1:0]       fetch_wr_data_i,
  input  logic [AddrWidth-1:0]            fetch_wr_addr_i,
  input  logic                            fetch_wr_en_i,
  input  logic                            fetch_buffer_sel_i,

  // Display Driver Interface
  input  logic                            display_complete_i,
  input  logic                            display_busy_i,
  input  logic                            row_pair_done_i,
  output logic                            start_display_o,
  output logic [(ColorDepth*3)-1:0]       display_rd_data_top_o,
  output logic [(ColorDepth*3)-1:0]       display_rd_data_bottom_o,
  input  logic [AddrWidth-1:0]            display_rd_addr_i,

  // Buffer Interface (Top 0/1, Bot 0/1)
  output logic [(ColorDepth*3)-1:0]       buffer_top_0_wr_data_o,
  output logic [AddrWidth-1:0]            buffer_top_0_wr_addr_o,
  output logic                            buffer_top_0_wr_en_o,
  output logic [AddrWidth-1:0]            buffer_top_0_rd_addr_o,
  input  logic [(ColorDepth*3)-1:0]       buffer_top_0_rd_data_i,

  output logic [(ColorDepth*3)-1:0]       buffer_top_1_wr_data_o,
  output logic [AddrWidth-1:0]            buffer_top_1_wr_addr_o,
  output logic                            buffer_top_1_wr_en_o,
  output logic [AddrWidth-1:0]            buffer_top_1_rd_addr_o,
  input  logic [(ColorDepth*3)-1:0]       buffer_top_1_rd_data_i,

  output logic [(ColorDepth*3)-1:0]       buffer_bot_0_wr_data_o,
  output logic [AddrWidth-1:0]            buffer_bot_0_wr_addr_o,
  output logic                            buffer_bot_0_wr_en_o,
  output logic [AddrWidth-1:0]            buffer_bot_0_rd_addr_o,
  input  logic [(ColorDepth*3)-1:0]       buffer_bot_0_rd_data_i,

  output logic [(ColorDepth*3)-1:0]       buffer_bot_1_wr_data_o,
  output logic [AddrWidth-1:0]            buffer_bot_1_wr_addr_o,
  output logic                            buffer_bot_1_wr_en_o,
  output logic [AddrWidth-1:0]            buffer_bot_1_rd_addr_o,
  input  logic [(ColorDepth*3)-1:0]       buffer_bot_1_rd_data_i,

  // Control Interface
  output logic                            ready_o,
  output logic [1:0]                      active_buffer_set_o
);

  localparam logic [RowPairAddrWidth-1:0] LastRowPair =
      RowPairCount[RowPairAddrWidth-1:0] - {{(RowPairAddrWidth-1){1'b0}}, 1'b1};
  localparam logic [RowPairAddrWidth-1:0] RowPairOne =
      {{(RowPairAddrWidth-1){1'b0}}, 1'b1};

  typedef enum logic [1:0] {
    StInitFillA,
    StInitFillB,
    StSteady
  } sched_state_e;

  sched_state_e sched_state_d, sched_state_q;

  logic display_buffer_sel_q;
  logic fetch_buffer_set_sel_q;
  logic [RowPairAddrWidth-1:0] next_row_pair_q;
  logic fetch_in_progress_q;

  always_comb begin
    sched_state_d = sched_state_q;

    unique case (sched_state_q)
      StInitFillA: begin
        if (fetch_complete_i) begin
          sched_state_d = StInitFillB;
        end
      end

      StInitFillB: begin
        if (fetch_complete_i) begin
          sched_state_d = StSteady;
        end
      end

      default: sched_state_d = StInitFillA;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sched_state_q           <= StInitFillA;
      display_buffer_sel_q    <= 1'b0;
      fetch_buffer_set_sel_q  <= 1'b0;
      next_row_pair_q         <= {RowPairAddrWidth{1'b0}};
      fetch_in_progress_q     <= 1'b0;
      start_fetch_o           <= 1'b0;
      start_display_o         <= 1'b0;
      fetch_row_pair_index_o  <= {RowPairAddrWidth{1'b0}};
      ready_o                 <= 1'b0;
      active_buffer_set_o     <= 2'b00;
    end else begin
      start_fetch_o   <= 1'b0;
      start_display_o <= 1'b0;

      sched_state_q <= sched_state_d;

      active_buffer_set_o <= {1'b0, display_buffer_sel_q};

      if (fetch_complete_i) begin
        fetch_in_progress_q <= 1'b0;
      end

      unique case (sched_state_q)
        StInitFillA: begin
          if (!fetch_in_progress_q && !fetch_busy_i) begin
            fetch_buffer_set_sel_q <= 1'b0;
            next_row_pair_q        <= {RowPairAddrWidth{1'b0}};
            fetch_row_pair_index_o <= next_row_pair_q;
            start_fetch_o          <= 1'b1;
            fetch_in_progress_q    <= 1'b1;
          end else if (fetch_complete_i) begin
            ready_o                <= 1'b1;
            fetch_buffer_set_sel_q <= 1'b1;
            next_row_pair_q        <= RowPairOne;
          end
        end

        StInitFillB: begin
          if (!fetch_in_progress_q && !fetch_busy_i) begin
            fetch_row_pair_index_o <= next_row_pair_q;
            start_fetch_o          <= 1'b1;
            fetch_in_progress_q    <= 1'b1;
          end else if (fetch_complete_i) begin
            next_row_pair_q <= (RowPairOne == LastRowPair) ?
                {RowPairAddrWidth{1'b0}} : (RowPairOne + RowPairOne);
            start_display_o <= 1'b1;
          end
        end

        StSteady: begin
          if (display_complete_i) begin
            start_display_o <= 1'b1;
          end

          if (row_pair_done_i) begin
            fetch_buffer_set_sel_q <= display_buffer_sel_q;
            display_buffer_sel_q   <= ~display_buffer_sel_q;

            if (!fetch_in_progress_q && !fetch_busy_i) begin
              fetch_row_pair_index_o <= next_row_pair_q;
              start_fetch_o          <= 1'b1;
              fetch_in_progress_q    <= 1'b1;
              next_row_pair_q <= (next_row_pair_q == LastRowPair) ?
                  {RowPairAddrWidth{1'b0}} : (next_row_pair_q + RowPairOne);
            end
          end
        end

      endcase
    end
  end

  always_comb begin
    buffer_top_0_wr_en_o   = 1'b0;
    buffer_top_0_wr_data_o = '0;
    buffer_top_0_wr_addr_o = '0;
    buffer_top_1_wr_en_o   = 1'b0;
    buffer_top_1_wr_data_o = '0;
    buffer_top_1_wr_addr_o = '0;
    buffer_bot_0_wr_en_o   = 1'b0;
    buffer_bot_0_wr_data_o = '0;
    buffer_bot_0_wr_addr_o = '0;
    buffer_bot_1_wr_en_o   = 1'b0;
    buffer_bot_1_wr_data_o = '0;
    buffer_bot_1_wr_addr_o = '0;

    if (fetch_wr_en_i) begin
      if (fetch_buffer_set_sel_q == 1'b0) begin
        if (fetch_buffer_sel_i == 1'b0) begin
          buffer_top_0_wr_en_o   = 1'b1;
          buffer_top_0_wr_data_o = fetch_wr_data_i;
          buffer_top_0_wr_addr_o = fetch_wr_addr_i;
        end else begin
          buffer_bot_0_wr_en_o   = 1'b1;
          buffer_bot_0_wr_data_o = fetch_wr_data_i;
          buffer_bot_0_wr_addr_o = fetch_wr_addr_i;
        end
      end else begin
        if (fetch_buffer_sel_i == 1'b0) begin
          buffer_top_1_wr_en_o   = 1'b1;
          buffer_top_1_wr_data_o = fetch_wr_data_i;
          buffer_top_1_wr_addr_o = fetch_wr_addr_i;
        end else begin
          buffer_bot_1_wr_en_o   = 1'b1;
          buffer_bot_1_wr_data_o = fetch_wr_data_i;
          buffer_bot_1_wr_addr_o = fetch_wr_addr_i;
        end
      end
    end
  end

  always_comb begin
    buffer_top_0_rd_addr_o = display_rd_addr_i;
    buffer_top_1_rd_addr_o = display_rd_addr_i;
    buffer_bot_0_rd_addr_o = display_rd_addr_i;
    buffer_bot_1_rd_addr_o = display_rd_addr_i;

    if (display_buffer_sel_q == 1'b0) begin
      display_rd_data_top_o    = buffer_top_0_rd_data_i;
      display_rd_data_bottom_o = buffer_bot_0_rd_data_i;
    end else begin
      display_rd_data_top_o    = buffer_top_1_rd_data_i;
      display_rd_data_bottom_o = buffer_bot_1_rd_data_i;
    end
  end

endmodule
