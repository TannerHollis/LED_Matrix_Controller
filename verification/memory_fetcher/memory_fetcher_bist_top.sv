// ============================================================================
// File Name   : memory_fetcher_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for memory_fetcher through the real SDRAM stack. One
//   button press preloads the SDRAM addresses that memory_fetcher will read with
//   mem_pattern(addr), pulses start_fetch, then lets memory_fetcher run as the
//   high-priority memory_arbiter client through sdram_arbiter_adapter and
//   sdram_controller.
//
//   The BIST watches memory_fetcher's buffer write port directly and verifies
//   every write enable, top/bottom buffer select, write column, and pixel data
//   value against the expected address sequence. It passes only after
//   fetch_complete arrives with all expected writes observed, and latches failure
//   on timeout, wrong address/routing/data, early completion, or missing writes.
//   This intentionally excludes buffer_controller and BRAM storage.
//
// Parameters  :
//   TotalRowWidth      - Number of pixels/words per row (Default: 1024)
//   PanelHeight        - Number of panel rows fetched per run (Default: 32)
//   ColorDepth         - Color bit depth per channel (Default: 4)
//   RowOffset          - Base row offset used by memory_fetcher (Default: 0)
//   TotalDisplayHeight - Memory_fetcher address-height parameter (Default: 4)
//   AddrWidth          - Arbiter/SDRAM client address width (Default: 24)
//   SdramRowWidth      - SDRAM row address width (Default: 13)
//   SdramColWidth      - SDRAM column address width (Default: 9)
//   SdramBankWidth     - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - memory_fetcher.sv
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style; SDRAM preload and burst row-pair fetch into line-buffer checker.
// ============================================================================

module memory_fetcher_bist_top #(
  parameter int unsigned TotalRowWidth      = 1024,
  parameter int unsigned PanelHeight        = 32,
  parameter int unsigned ColorDepth         = 4,
  parameter int unsigned RowOffset          = 0,
  parameter int unsigned TotalDisplayHeight = 4,
  parameter int unsigned AddrWidth          = 24,
  parameter int unsigned SdramRowWidth      = 13,
  parameter int unsigned SdramColWidth      = 9,
  parameter int unsigned SdramBankWidth     = 2
) (
  input  logic        clk_50mhz,
  input  logic        btn_start,
  input  logic        btn_reset,
  output logic        led_status,
  output logic [12:0] sdram_addr,
  output logic [1:0]  sdram_ba,
  output logic        sdram_cas_n,
  output logic        sdram_cke,
  output logic        sdram_clk,
  output logic        sdram_cs_n,
  inout  wire [15:0] sdram_dq,
  output logic [1:0]  sdram_dqm,
  output logic        sdram_ras_n,
  output logic        sdram_we_n
);

  typedef enum logic [3:0] {
    StIdle,
    StPreloadReq,
    StPreloadWait,
    StStartFetch,
    StFetchWait
  } bist_state_e;

  localparam int unsigned DataWidth       = ColorDepth * 3;
  localparam int unsigned FetchAddrWidth  = (TotalRowWidth * TotalDisplayHeight <= 1) ?
                                            1 : $clog2(TotalRowWidth * TotalDisplayHeight);
  localparam int unsigned RowAddrWidth    = (TotalRowWidth <= 1) ? 1 : $clog2(TotalRowWidth);
  localparam int unsigned RowPairCount    = PanelHeight / 2;
  localparam int unsigned FetchWords      = TotalRowWidth * 2;
  localparam int unsigned LastPreloadIndex = FetchWords - 1;
  localparam int unsigned LastWriteIndex  = FetchWords - 1;
  localparam int unsigned RowPairAddrWidth = (RowPairCount <= 1) ? 1 : $clog2(RowPairCount);
  localparam int unsigned SdramAddrWidth  = SdramBankWidth + SdramRowWidth + SdramColWidth;
  localparam logic [23:0] OpWaitTimeout   = 24'd10_000_000;

  logic clk_i;
  logic clk_host;
  logic clk_sdram;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  sdram_clock_gen sdram_clock_gen_inst (
    .clk_board_i(clk_i),
    .rst_ni(rst_ni),
    .clk_host_o(clk_host),
    .clk_sdram_o(clk_sdram),
    .pll_locked_o()
  );

  bist_state_e state;
  logic [23:0] wait_counter;
  logic [24:0] blink_counter;
  logic        bist_done;
  logic        fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic                      preload_mem_req;
  logic [AddrWidth-1:0]      preload_mem_addr;
  logic [DataWidth-1:0]      preload_mem_write_data;
  logic [AddrWidth-1:0]      preload_index;
  logic [AddrWidth-1:0]      expected_write_index;
  logic                      start_fetch;
  logic [RowPairAddrWidth-1:0] row_pair_index;

  logic                      fetch_mem_req;
  logic [3:0]                fetch_mem_read_length;
  logic                      fetch_mem_grant;
  logic [FetchAddrWidth-1:0] fetch_mem_addr;
  logic [DataWidth-1:0]      fetch_mem_read_data;
  logic                      fetch_mem_read_data_valid;
  logic [DataWidth-1:0]      buffer_wr_data;
  logic [RowAddrWidth-1:0]   buffer_wr_addr;
  logic                      buffer_wr_en;
  logic                      buffer_sel;
  logic                      fetch_complete;
  logic                      fetch_busy;

  logic [1:0]             client_mem_req;
  logic [1:0]             client_mem_write;
  logic [AddrWidth*2-1:0] client_mem_addr;
  logic [DataWidth*2-1:0] client_mem_write_data;
  logic [7:0]             client_mem_read_length;
  logic [7:0]             client_mem_write_length;
  logic [1:0]             client_mem_grant;
  logic [DataWidth*2-1:0] client_mem_read_data;
  logic [1:0]             client_mem_read_data_valid;

  logic                      master_mem_req;
  logic                      master_mem_write;
  logic [AddrWidth-1:0]      master_mem_addr;
  logic [DataWidth-1:0]      master_mem_write_data;
  logic                      master_mem_ready;
  logic [3:0]                master_mem_read_length;
  logic [3:0]                master_mem_write_length;
  logic [DataWidth-1:0]      master_mem_read_data;
  logic                      master_mem_read_data_valid;

  logic [15:0]               sdram_write_data;
  logic                      sdram_write_request;
  logic [SdramAddrWidth-1:0] sdram_write_addr;
  logic [8:0]                sdram_write_length;
  logic                      sdram_write_load;
  logic                      sdram_write_full;
  logic [15:0]               sdram_write_used;
  logic [15:0]               sdram_read_data;
  logic                      sdram_read_request;
  logic [SdramAddrWidth-1:0] sdram_read_addr;
  logic [8:0]                sdram_read_length;
  logic                      sdram_read_load;
  logic                      sdram_read_empty;

  assign fetch_mem_grant = client_mem_grant[1];
  assign fetch_mem_read_data = client_mem_read_data[2*DataWidth-1:DataWidth];
  assign fetch_mem_read_data_valid = client_mem_read_data_valid[1];

  assign client_mem_req = {fetch_mem_req, preload_mem_req};
  assign client_mem_write = {1'b0, preload_mem_req};
  assign client_mem_addr =
      {{(AddrWidth-FetchAddrWidth){1'b0}}, fetch_mem_addr, preload_mem_addr};
  assign client_mem_write_data =
      {{DataWidth{1'b0}}, preload_mem_write_data};
  assign client_mem_read_length  = {fetch_mem_read_length, 4'd1};
  assign client_mem_write_length = {4'd1, 4'd1};

  function automatic logic [DataWidth-1:0] mem_pattern(
      input logic [AddrWidth-1:0] addr_in
  );
    logic [15:0] full_pat;
    full_pat    = addr_in[15:0] ^ 16'hA5C3;
    mem_pattern = full_pat[DataWidth-1:0];
  endfunction

  function automatic logic [AddrWidth-1:0] fetch_addr_for_write(
      input logic [AddrWidth-1:0]      write_index,
      input logic [RowPairAddrWidth-1:0] row_pair
  );
    logic [AddrWidth-1:0] phase_offset;
    logic [AddrWidth-1:0] col;
    phase_offset = write_index;
    if (phase_offset < TotalRowWidth) begin
      col = phase_offset;
      fetch_addr_for_write = (RowOffset + row_pair) * TotalRowWidth + col;
    end else begin
      col = phase_offset - TotalRowWidth;
      fetch_addr_for_write =
          (RowOffset + row_pair + RowPairCount) * TotalRowWidth + col;
    end
  endfunction

  function automatic logic [RowAddrWidth-1:0] fetch_col_for_write(
      input logic [AddrWidth-1:0] write_index
  );
    logic [AddrWidth-1:0] phase_offset;
    logic [AddrWidth-1:0] col_value;
    phase_offset = write_index % (TotalRowWidth * 2);
    if (phase_offset < TotalRowWidth)
      col_value = phase_offset;
    else
      col_value = phase_offset - TotalRowWidth;
    fetch_col_for_write = col_value[RowAddrWidth-1:0];
  endfunction

  function automatic logic expected_sel_for_write(
      input logic [AddrWidth-1:0] write_index
  );
    logic [AddrWidth-1:0] phase_offset;
    phase_offset = write_index % (TotalRowWidth * 2);
    expected_sel_for_write = (phase_offset >= TotalRowWidth);
  endfunction

  always_ff @(posedge clk_host or negedge rst_ni) begin
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

  always_ff @(posedge clk_host or negedge rst_ni) begin
    if (!rst_ni) begin
      state                  <= StIdle;
      wait_counter           <= 24'd0;
      blink_counter          <= 25'd0;
      bist_done              <= 1'b0;
      fail_latched           <= 1'b0;
      led_status             <= 1'b1;
      preload_mem_req        <= 1'b0;
      preload_mem_addr       <= {AddrWidth{1'b0}};
      preload_mem_write_data <= {DataWidth{1'b0}};
      preload_index          <= {AddrWidth{1'b0}};
      expected_write_index   <= {AddrWidth{1'b0}};
      start_fetch            <= 1'b0;
      row_pair_index         <= {RowPairAddrWidth{1'b0}};
    end else begin
      blink_counter <= blink_counter + 25'd1;
      start_fetch   <= 1'b0;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          preload_mem_req <= 1'b0;
          wait_counter    <= 24'd0;
          if (start_event) begin
            bist_done              <= 1'b0;
            fail_latched           <= 1'b0;
            preload_index          <= {AddrWidth{1'b0}};
            expected_write_index   <= {AddrWidth{1'b0}};
            preload_mem_addr       <= {AddrWidth{1'b0}};
            preload_mem_write_data <= mem_pattern({AddrWidth{1'b0}});
            state                  <= StPreloadReq;
          end
        end

        StPreloadReq: begin
          preload_mem_req        <= 1'b1;
          preload_mem_addr       <= preload_index;
          preload_mem_write_data <= mem_pattern(preload_index);
          wait_counter           <= 24'd0;
          state                  <= StPreloadWait;
        end

        StPreloadWait: begin
          if (client_mem_grant[0]) begin
            preload_mem_req <= 1'b0;
            wait_counter    <= 24'd0;
            if (preload_index == LastPreloadIndex) begin
              state <= StStartFetch;
            end else begin
              preload_index <= preload_index + {{(AddrWidth-1){1'b0}}, 1'b1};
              state         <= StPreloadReq;
            end
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StStartFetch: begin
          row_pair_index       <= {RowPairAddrWidth{1'b0}};
          start_fetch          <= 1'b1;
          expected_write_index <= {AddrWidth{1'b0}};
          wait_counter         <= 24'd0;
          state                <= StFetchWait;
        end

        StFetchWait: begin
          if (buffer_wr_en) begin
            if (buffer_wr_addr != fetch_col_for_write(expected_write_index))
              fail_latched <= 1'b1;
            if (buffer_sel != expected_sel_for_write(expected_write_index))
              fail_latched <= 1'b1;
            if (buffer_wr_data !=
                mem_pattern(fetch_addr_for_write(expected_write_index, row_pair_index)))
              fail_latched <= 1'b1;

            if (expected_write_index != LastWriteIndex)
              expected_write_index <= expected_write_index + {{(AddrWidth-1){1'b0}}, 1'b1};
          end

          if (fetch_complete) begin
            if (!buffer_wr_en ||
                (expected_write_index != LastWriteIndex) ||
                fail_latched) begin
              fail_latched <= 1'b1;
            end
            bist_done <= 1'b1;
            state     <= StIdle;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  memory_fetcher #(
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .RowOffset(RowOffset),
    .TotalDisplayHeight(TotalDisplayHeight)
  ) fetcher_inst (
    .clk_i(clk_host),
    .rst_ni(rst_ni),
    .mem_req_o(fetch_mem_req),
    .mem_read_length_o(fetch_mem_read_length),
    .mem_grant_i(fetch_mem_grant),
    .mem_addr_o(fetch_mem_addr),
    .mem_read_data_i(fetch_mem_read_data),
    .mem_read_data_valid_i(fetch_mem_read_data_valid),
    .buffer_wr_data_o(buffer_wr_data),
    .buffer_wr_addr_o(buffer_wr_addr),
    .buffer_wr_en_o(buffer_wr_en),
    .buffer_sel_o(buffer_sel),
    .fetch_complete_o(fetch_complete),
    .start_fetch_i(start_fetch),
    .row_pair_index_i(row_pair_index),
    .target_buffer_i(2'b00),
    .busy_o(fetch_busy)
  );

  memory_arbiter #(
    .NumClients(2),
    .NumLowPriClients(1),
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) mem_arbiter_inst (
    .clk_i(clk_host),
    .rst_ni(rst_ni),
    .client_mem_req_i(client_mem_req),
    .client_mem_write_i(client_mem_write),
    .client_mem_addr_i(client_mem_addr),
    .client_mem_write_data_i(client_mem_write_data),
    .client_mem_read_length_i(client_mem_read_length),
    .client_mem_write_length_i(client_mem_write_length),
    .client_mem_grant_o(client_mem_grant),
    .client_mem_read_data_o(client_mem_read_data),
    .client_mem_read_data_valid_o(client_mem_read_data_valid),
    .master_mem_req_o(master_mem_req),
    .master_mem_write_o(master_mem_write),
    .master_mem_addr_o(master_mem_addr),
    .master_mem_write_data_o(master_mem_write_data),
    .master_mem_read_length_o(master_mem_read_length),
    .master_mem_write_length_o(master_mem_write_length),
    .master_mem_ready_i(master_mem_ready),
    .master_mem_read_data_i(master_mem_read_data),
    .master_mem_read_data_valid_i(master_mem_read_data_valid)
  );

  sdram_arbiter_adapter #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .SdramAddrWidth(SdramAddrWidth),
    .MaxBurstLen(8),
    .ScBl(8)
  ) sdram_adapter_inst (
    .clk_i(clk_host),
    .rst_ni(rst_ni),
    .arbiter_mem_req_i(master_mem_req),
    .arbiter_mem_write_i(master_mem_write),
    .arbiter_mem_addr_i(master_mem_addr),
    .arbiter_mem_write_data_i(master_mem_write_data),
    .arbiter_mem_read_length_i(master_mem_read_length),
    .arbiter_mem_write_length_i(master_mem_write_length),
    .arbiter_mem_ready_o(master_mem_ready),
    .arbiter_mem_read_data_o(master_mem_read_data),
    .arbiter_mem_read_data_valid_o(master_mem_read_data_valid),
    .sdram_write_data_o(sdram_write_data),
    .sdram_write_request_o(sdram_write_request),
    .sdram_write_addr_o(sdram_write_addr),
    .sdram_write_length_o(sdram_write_length),
    .sdram_write_load_o(sdram_write_load),
    .sdram_write_full_i(sdram_write_full),
    .sdram_write_used_i(sdram_write_used),
    .sdram_read_data_i(sdram_read_data),
    .sdram_read_request_o(sdram_read_request),
    .sdram_read_addr_o(sdram_read_addr),
    .sdram_read_length_o(sdram_read_length),
    .sdram_read_load_o(sdram_read_load),
    .sdram_read_empty_i(sdram_read_empty)
  );

  sdram_controller #(
    .ScBl(8),
    .ScSingleWrite(1)
  ) sdram_ctrl_inst (
    .clk_host_i(clk_host),
    .clk_sdram_i(clk_sdram),
    .rst_ni(rst_ni),
    .write_data_i(sdram_write_data),
    .write_request_i(sdram_write_request),
    .write_addr_i(sdram_write_addr),
    .write_length_i(sdram_write_length),
    .write_load_i(sdram_write_load),
    .write_full_o(sdram_write_full),
    .write_used_o(sdram_write_used),
    .read_data_o(sdram_read_data),
    .read_request_i(sdram_read_request),
    .read_addr_i(sdram_read_addr),
    .read_length_i(sdram_read_length),
    .read_load_i(sdram_read_load),
    .read_empty_o(sdram_read_empty),
    .read_used_o(),
    .sdram_addr_o(sdram_addr),
    .sdram_ba_o(sdram_ba),
    .sdram_cas_n_o(sdram_cas_n),
    .sdram_cke_o(sdram_cke),
    .sdram_clk_o(sdram_clk),
    .sdram_cs_n_o(sdram_cs_n),
    .sdram_dq_io(sdram_dq),
    .sdram_dqm_o(sdram_dqm),
    .sdram_ras_n_o(sdram_ras_n),
    .sdram_we_n_o(sdram_we_n)
  );

endmodule
