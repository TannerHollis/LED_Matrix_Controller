// ============================================================================
// File Name   : buffer_controller_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Controller-only hardware BIST top for buffer_controller on the DE2-115. Mock
//   fetch and display agents exercise start/complete handshakes, ping-pong
//   buffer swaps from priming set 0, write-port routing, read-address fanout,
//   read-data muxing, and ignored mid-run start bounce without instantiating
//   BRAMs or memory_fetcher.
//
// Parameters  :
//   TotalRowWidth - Number of pixels/words in each row (Default: 64)
//   PanelHeight   - Panel height in rows (Default: 32)
//   ColorDepth    - Color bit depth per channel (Default: 4)
//   SwapRounds    - Number of row-pair buffer swaps after priming (Default: 4)
//
// Dependencies:
//   - buffer_controller.sv
// ============================================================================
// Revision History:
//   Current - Migrated to lowRISC style (logic, enum FSM, unique case).
//   Prior   - buffer_controller ping-pong handshake BIST with mock agents.
// ============================================================================

module buffer_controller_bist_top #(
  parameter int unsigned TotalRowWidth = 64,
  parameter int unsigned PanelHeight   = 32,
  parameter int unsigned ColorDepth    = 4,
  parameter int unsigned SwapRounds    = 4
) (
  input  logic clk_50mhz,
  input  logic btn_start,
  input  logic btn_reset,
  output logic led_status
);

  localparam int unsigned PixelDataWidth = ColorDepth * 3;
  localparam int unsigned AddrWidth =
      (TotalRowWidth <= 1) ? 1 : $clog2(TotalRowWidth);
  localparam int unsigned LastIndex = TotalRowWidth - 1;

  typedef enum logic [1:0] {
    StIdle,
    StWaitReady,
    StRun
  } bist_state_e;

  typedef enum logic [1:0] {
    MfIdle,
    MfTop,
    MfBot
  } mock_fetch_state_e;

  typedef enum logic {
    MdIdle,
    MdStream
  } mock_display_state_e;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  logic dut_reset_n;
  bist_state_e state;
  logic [24:0] blink_counter;
  logic        bist_done;
  logic        fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;
  logic       bist_start_event;

  assign bist_start_event = start_event && (state == StIdle);

  // --- Mock fetch agent: simulates memory_fetcher row-pair writes ---
  mock_fetch_state_e       mf_state;
  logic                    mock_fetch_busy;
  logic                    fetch_complete;
  logic                    fetch_wr_en;
  logic                    fetch_buffer_sel;
  logic [PixelDataWidth-1:0] fetch_wr_data;
  logic [AddrWidth-1:0]    fetch_wr_addr;
  logic [7:0]              fetch_transaction;
  logic [AddrWidth-1:0]    mf_addr;

  // --- Mock display agent: simulates display_driver row-pair reads ---
  mock_display_state_e     md_state;
  logic                    mock_display_busy;
  logic                    display_complete;
  logic                    row_pair_done;
  logic [7:0]              md_row_pair_count;
  logic [AddrWidth-1:0]    display_rd_addr;

  logic [7:0] swap_count;
  logic [7:0] target_swaps;
  logic       prev_active_set;
  logic       prev_start_fetch;
  logic       prev_start_display;
  logic       ready_seen;
  logic       first_fetch_complete_seen;

  logic start_fetch;
  logic start_display;
  logic ready;
  logic [1:0] active_buffer_set;
  logic       expected_fetch_set;
  logic [PixelDataWidth-1:0] display_rd_data_top;
  logic [PixelDataWidth-1:0] display_rd_data_bottom;

  assign expected_fetch_set = fetch_transaction[0];

  logic [PixelDataWidth-1:0] b_t0_wd, b_t1_wd, b_b0_wd, b_b1_wd;
  logic [AddrWidth-1:0]      b_t0_wa, b_t1_wa, b_b0_wa, b_b1_wa;
  logic                      b_t0_we, b_t1_we, b_b0_we, b_b1_we;
  logic [AddrWidth-1:0]      b_t0_ra, b_t1_ra, b_b0_ra, b_b1_ra;
  logic [PixelDataWidth-1:0] b_t0_rd, b_t1_rd, b_b0_rd, b_b1_rd;

  function automatic logic [PixelDataWidth-1:0] fetch_pattern(
      input logic [7:0]              transaction_in,
      input logic                    row_sel,
      input logic [AddrWidth-1:0]    addr_in);
    logic [15:0] full_pat;
    full_pat      = {transaction_in, row_sel, addr_in} ^ 16'hA5C3;
    fetch_pattern = full_pat[PixelDataWidth-1:0];
  endfunction

  function automatic logic [PixelDataWidth-1:0] bank_pattern(
      input logic                 bank_sel,
      input logic                 row_sel,
      input logic [AddrWidth-1:0] addr_in);
    logic [15:0] full_pat;
    full_pat     = {4'hC, bank_sel, row_sel, addr_in, 4'h5} ^ 16'h39A7;
    bank_pattern = full_pat[PixelDataWidth-1:0];
  endfunction

  assign b_t0_rd = bank_pattern(1'b0, 1'b0, b_t0_ra);
  assign b_t1_rd = bank_pattern(1'b1, 1'b0, b_t1_ra);
  assign b_b0_rd = bank_pattern(1'b0, 1'b1, b_b0_ra);
  assign b_b1_rd = bank_pattern(1'b1, 1'b1, b_b1_ra);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_sync  <= 3'b111;
      start_armed <= 1'b1;
      start_event <= 1'b0;
    end else begin
      start_sync  <= {start_sync[1:0], btn_start};
      start_event <= 1'b0;
      if (start_sync[2]) begin
        start_armed <= 1'b1;
      end else if (start_armed) begin
        start_event <= 1'b1;
        start_armed <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mf_state          <= MfIdle;
      mock_fetch_busy   <= 1'b0;
      fetch_complete    <= 1'b0;
      fetch_wr_en       <= 1'b0;
      fetch_buffer_sel  <= 1'b0;
      fetch_wr_data     <= {PixelDataWidth{1'b0}};
      fetch_wr_addr     <= {AddrWidth{1'b0}};
      fetch_transaction <= 8'd0;
      mf_addr           <= {AddrWidth{1'b0}};
    end else if (bist_start_event) begin
      mf_state          <= MfIdle;
      mock_fetch_busy   <= 1'b0;
      fetch_complete    <= 1'b0;
      fetch_wr_en       <= 1'b0;
      fetch_buffer_sel  <= 1'b0;
      fetch_wr_data     <= {PixelDataWidth{1'b0}};
      fetch_wr_addr     <= {AddrWidth{1'b0}};
      fetch_transaction <= 8'd0;
      mf_addr           <= {AddrWidth{1'b0}};
    end else begin
      fetch_complete <= 1'b0;
      fetch_wr_en    <= 1'b0;

      unique case (mf_state)
        MfIdle: begin
          if (start_fetch) begin
            mock_fetch_busy <= 1'b1;
            mf_addr         <= {AddrWidth{1'b0}};
            mf_state        <= MfTop;
          end else begin
            mock_fetch_busy <= 1'b0;
          end
        end

        MfTop: begin
          fetch_buffer_sel <= 1'b0;
          fetch_wr_en      <= 1'b1;
          fetch_wr_addr    <= mf_addr;
          fetch_wr_data    <= fetch_pattern(fetch_transaction, 1'b0, mf_addr);

          if (mf_addr == LastIndex[AddrWidth-1:0]) begin
            mf_addr  <= {AddrWidth{1'b0}};
            mf_state <= MfBot;
          end else begin
            mf_addr <= mf_addr + 1'b1;
          end
        end

        MfBot: begin
          fetch_buffer_sel <= 1'b1;
          fetch_wr_en      <= 1'b1;
          fetch_wr_addr    <= mf_addr;
          fetch_wr_data    <= fetch_pattern(fetch_transaction, 1'b1, mf_addr);

          if (mf_addr == LastIndex[AddrWidth-1:0]) begin
            mock_fetch_busy   <= 1'b0;
            fetch_transaction <= fetch_transaction + 8'd1;
            fetch_complete    <= 1'b1;
            mf_state          <= MfIdle;
          end else begin
            mf_addr <= mf_addr + 1'b1;
          end
        end

        default: mf_state <= MfIdle;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      md_state          <= MdIdle;
      mock_display_busy <= 1'b0;
      display_complete  <= 1'b0;
      row_pair_done     <= 1'b0;
      md_row_pair_count <= 8'd0;
      display_rd_addr   <= {AddrWidth{1'b0}};
    end else if (bist_start_event) begin
      md_state          <= MdIdle;
      mock_display_busy <= 1'b0;
      display_complete  <= 1'b0;
      row_pair_done     <= 1'b0;
      md_row_pair_count <= 8'd0;
      display_rd_addr   <= {AddrWidth{1'b0}};
    end else begin
      display_complete <= 1'b0;
      row_pair_done    <= 1'b0;

      unique case (md_state)
        MdIdle: begin
          if (start_display) begin
            mock_display_busy <= 1'b1;
            display_rd_addr   <= {AddrWidth{1'b0}};
            md_row_pair_count <= 8'd0;
            md_state          <= MdStream;
          end else begin
            mock_display_busy <= 1'b0;
          end
        end

        MdStream: begin
          if (display_rd_addr == LastIndex[AddrWidth-1:0]) begin
            row_pair_done <= 1'b1;
            if ((md_row_pair_count + 8'd1) >= target_swaps) begin
              mock_display_busy <= 1'b0;
              display_complete  <= 1'b1;
              md_state          <= MdIdle;
            end else begin
              md_row_pair_count <= md_row_pair_count + 8'd1;
              display_rd_addr   <= {AddrWidth{1'b0}};
            end
          end else begin
            display_rd_addr <= display_rd_addr + 1'b1;
          end
        end

        default: md_state <= MdIdle;
      endcase
    end
  end

  // --- BIST orchestration: ping-pong handshakes and port routing checkers ---
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dut_reset_n               <= 1'b0;
      state                     <= StIdle;
      blink_counter             <= 25'd0;
      bist_done                 <= 1'b0;
      fail_latched              <= 1'b0;
      led_status                <= 1'b1;
      swap_count                <= 8'd0;
      target_swaps              <= SwapRounds[7:0];
      prev_active_set           <= 1'b0;
      prev_start_fetch          <= 1'b0;
      prev_start_display        <= 1'b0;
      ready_seen                <= 1'b0;
      first_fetch_complete_seen <= 1'b0;
    end else begin
      blink_counter <= blink_counter + 25'd1;

      if (dut_reset_n) begin
        if (start_fetch && prev_start_fetch) fail_latched <= 1'b1;
        if (start_display && prev_start_display) fail_latched <= 1'b1;
        if (start_fetch && mock_fetch_busy) fail_latched <= 1'b1;
        if (start_display && mock_display_busy) fail_latched <= 1'b1;

        if (ready && !first_fetch_complete_seen && !fetch_complete) fail_latched <= 1'b1;

        if (fetch_complete && !first_fetch_complete_seen)
          first_fetch_complete_seen <= 1'b1;

        if ((b_t0_ra != display_rd_addr) ||
            (b_t1_ra != display_rd_addr) ||
            (b_b0_ra != display_rd_addr) ||
            (b_b1_ra != display_rd_addr)) begin
          fail_latched <= 1'b1;
        end

        if (display_rd_data_top != (active_buffer_set[0] ? b_t1_rd : b_t0_rd))
          fail_latched <= 1'b1;
        if (display_rd_data_bottom != (active_buffer_set[0] ? b_b1_rd : b_b0_rd))
          fail_latched <= 1'b1;

        if (fetch_wr_en) begin
          if (!fetch_buffer_sel && !expected_fetch_set) begin
            if (!b_t0_we || b_t1_we || b_b0_we || b_b1_we ||
                (b_t0_wa != fetch_wr_addr) ||
                (b_t0_wd != fetch_wr_data)) fail_latched <= 1'b1;
          end else if (!fetch_buffer_sel && expected_fetch_set) begin
            if (b_t0_we || !b_t1_we || b_b0_we || b_b1_we ||
                (b_t1_wa != fetch_wr_addr) ||
                (b_t1_wd != fetch_wr_data)) fail_latched <= 1'b1;
          end else if (fetch_buffer_sel && !expected_fetch_set) begin
            if (b_t0_we || b_t1_we || !b_b0_we || b_b1_we ||
                (b_b0_wa != fetch_wr_addr) ||
                (b_b0_wd != fetch_wr_data)) fail_latched <= 1'b1;
          end else begin
            if (b_t0_we || b_t1_we || b_b0_we || !b_b1_we ||
                (b_b1_wa != fetch_wr_addr) ||
                (b_b1_wd != fetch_wr_data)) fail_latched <= 1'b1;
          end
        end else if (b_t0_we || b_t1_we || b_b0_we || b_b1_we) begin
          fail_latched <= 1'b1;
        end
      end

      prev_start_fetch   <= start_fetch;
      prev_start_display <= start_display;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          dut_reset_n               <= 1'b0;
          ready_seen                <= 1'b0;
          first_fetch_complete_seen <= 1'b0;
          if (bist_start_event) begin
            dut_reset_n        <= 1'b1;
            bist_done          <= 1'b0;
            fail_latched       <= 1'b0;
            swap_count         <= 8'd0;
            target_swaps       <= SwapRounds[7:0];
            prev_active_set    <= 1'b0;
            prev_start_fetch   <= 1'b0;
            prev_start_display <= 1'b0;
            state              <= StWaitReady;
          end
        end

        StWaitReady: begin
          if (fetch_complete && !ready_seen && !ready)
            fail_latched <= 1'b1;
          if (ready) begin
            if (!first_fetch_complete_seen)
              fail_latched <= 1'b1;
            ready_seen      <= 1'b1;
            prev_active_set <= active_buffer_set[0];
            state           <= StRun;
          end
        end

        StRun: begin
          if (fail_latched) begin
            dut_reset_n <= 1'b0;
            state       <= StIdle;
          end else if (active_buffer_set[0] != prev_active_set) begin
            prev_active_set <= active_buffer_set[0];
            swap_count      <= swap_count + 8'd1;
            if ((swap_count + 8'd1) >= target_swaps) begin
              bist_done   <= 1'b1;
              dut_reset_n <= 1'b0;
              state       <= StIdle;
            end
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  buffer_controller #(
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth)
  ) dut_inst (
    .clk_i(clk_i),
    .rst_ni(dut_reset_n),
    .fetch_complete_i(fetch_complete),
    .fetch_busy_i(mock_fetch_busy),
    .start_fetch_o(start_fetch),
    .fetch_row_pair_index_o(),
    .fetch_wr_data_i(fetch_wr_data),
    .fetch_wr_addr_i(fetch_wr_addr),
    .fetch_wr_en_i(fetch_wr_en),
    .fetch_buffer_sel_i(fetch_buffer_sel),
    .display_complete_i(display_complete),
    .display_busy_i(mock_display_busy),
    .row_pair_done_i(row_pair_done),
    .start_display_o(start_display),
    .display_rd_data_top_o(display_rd_data_top),
    .display_rd_data_bottom_o(display_rd_data_bottom),
    .display_rd_addr_i(display_rd_addr),

    .buffer_top_0_wr_data_o(b_t0_wd), .buffer_top_0_wr_addr_o(b_t0_wa), .buffer_top_0_wr_en_o(b_t0_we),
    .buffer_top_0_rd_addr_o(b_t0_ra), .buffer_top_0_rd_data_i(b_t0_rd),
    .buffer_top_1_wr_data_o(b_t1_wd), .buffer_top_1_wr_addr_o(b_t1_wa), .buffer_top_1_wr_en_o(b_t1_we),
    .buffer_top_1_rd_addr_o(b_t1_ra), .buffer_top_1_rd_data_i(b_t1_rd),
    .buffer_bot_0_wr_data_o(b_b0_wd), .buffer_bot_0_wr_addr_o(b_b0_wa), .buffer_bot_0_wr_en_o(b_b0_we),
    .buffer_bot_0_rd_addr_o(b_b0_ra), .buffer_bot_0_rd_data_i(b_b0_rd),
    .buffer_bot_1_wr_data_o(b_b1_wd), .buffer_bot_1_wr_addr_o(b_b1_wa), .buffer_bot_1_wr_en_o(b_b1_we),
    .buffer_bot_1_rd_addr_o(b_b1_ra), .buffer_bot_1_rd_data_i(b_b1_rd),

    .ready_o(ready),
    .active_buffer_set_o(active_buffer_set)
  );

endmodule
