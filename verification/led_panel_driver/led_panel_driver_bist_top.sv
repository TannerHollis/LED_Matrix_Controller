// ============================================================================
// File Name   : led_panel_driver_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM-backed hardware BIST top for led_panel_driver. A preload client writes
//   deterministic pixel data into external SDRAM, then led_panel_driver runs as
//   the high-priority memory client through the real arbiter/adapter/controller
//   stack. HUB75 outputs remain internal and are checked for panel clock, latch,
//   OE, row-address, and RGB data behavior.
//
// Parameters  :
//   SysClkHz           - Input clock frequency in Hz (Default: 50 MHz)
//   RefreshRateHz      - Display refresh rate used by DUT timing (Default: 60)
//   BrightnessWidth    - Global brightness input width (Default: 8)
//   TotalRowWidth      - Number of pixels/words per row (Default: 1024)
//   PanelHeight        - Number of panel rows (Default: 32)
//   ColorDepth         - Color bit depth per channel (Default: 4)
//   RowOffset          - Base row offset used by memory_fetcher (Default: 0)
//   TotalDisplayHeight - Memory_fetcher address-height parameter (Default: 32)
//   AddrWidth          - Arbiter/SDRAM client address width (Default: 24)
//   SdramRowWidth      - SDRAM row address width (Default: 13)
//   SdramColWidth      - SDRAM column address width (Default: 9)
//   SdramBankWidth     - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - led_panel_driver.sv
//   - memory_fetcher.sv
//   - buffer_controller.sv
//   - line_buffer_ram.sv
//   - display_driver.sv
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style; SDRAM-backed led_panel_driver with internal HUB75 checker.
// ============================================================================

module led_panel_driver_bist_top #(
  parameter int unsigned SysClkHz           = 100_000_000,
  parameter int unsigned MaxPanelClkHz      = 25_000_000,
  parameter int unsigned RefreshRateHz      = 60,
  parameter int unsigned BrightnessWidth    = 8,
  parameter int unsigned TotalRowWidth      = 1024,
  parameter int unsigned PanelHeight        = 32,
  parameter int unsigned ColorDepth         = 4,
  parameter int unsigned RowOffset          = 0,
  parameter int unsigned TotalDisplayHeight = 32,
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

  typedef enum logic [2:0] {
    StIdle,
    StPreloadReq,
    StPreloadWait,
    StReleaseDut,
    StRun
  } bist_state_e;

  localparam int unsigned DataWidth        = ColorDepth * 3;
  localparam int unsigned DriverAddrWidth  = (TotalRowWidth * TotalDisplayHeight <= 1) ?
                                           1 : $clog2(TotalRowWidth * TotalDisplayHeight);
  localparam int unsigned RowAddrWidth   = (PanelHeight / 2 <= 1) ? 1 : $clog2(PanelHeight / 2);
  localparam int unsigned RowPairCount   = PanelHeight / 2;
  localparam int unsigned SdramAddrWidth = SdramBankWidth + SdramRowWidth + SdramColWidth;
  localparam int unsigned CountWidth     = 32;
  localparam logic [CountWidth-1:0] FetchWords         = TotalRowWidth * PanelHeight;
  localparam logic [CountWidth-1:0] LastPreloadIndex   = FetchWords - 1;
  localparam logic [CountWidth-1:0] TotalGroups        = RowPairCount * ColorDepth;
  localparam logic [CountWidth-1:0] TotalClkPulses     = TotalGroups * TotalRowWidth;
  localparam logic [CountWidth-1:0] LastGroupPixel     = TotalRowWidth - 1;
  localparam int unsigned RowWidthIndex  = TotalRowWidth;
  localparam int unsigned LastRowPairIndex = RowPairCount - 1;
  localparam int unsigned LastBcmIndex   = ColorDepth - 1;
  localparam logic [CountWidth-1:0] PreloadWaitTimeout = 32'd10_000_000;
  localparam logic [CountWidth-1:0] RunWaitTimeout     = 32'd20_000_000;

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
  logic        dut_reset_n;
  logic [CountWidth-1:0] wait_counter;
  logic [24:0]           blink_counter;
  logic                  bist_done;
  logic                  fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic                      preload_mem_req;
  logic [AddrWidth-1:0]      preload_mem_addr;
  logic [DataWidth-1:0]      preload_mem_write_data;
  logic [CountWidth-1:0]     preload_index;

  logic                      driver_mem_req;
  logic [3:0]                driver_mem_read_length;
  logic                      driver_mem_grant;
  logic [DriverAddrWidth-1:0] driver_mem_addr;
  logic [DataWidth-1:0]      driver_mem_read_data;
  logic                      driver_mem_read_data_valid;

  logic [1:0]                client_mem_req;
  logic [1:0]                client_mem_write;
  logic [AddrWidth*2-1:0]    client_mem_addr;
  logic [DataWidth*2-1:0]    client_mem_write_data;
  logic [7:0]                client_mem_read_length;
  logic [7:0]                client_mem_write_length;
  logic [1:0]                client_mem_grant;
  logic [DataWidth*2-1:0]    client_mem_read_data;
  logic [1:0]                client_mem_read_data_valid;

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

  logic [BrightnessWidth-1:0] brightness;
  logic panel_r1;
  logic panel_g1;
  logic panel_b1;
  logic panel_r2;
  logic panel_g2;
  logic panel_b2;
  logic [RowAddrWidth-1:0] panel_addr;
  logic panel_clk;
  logic panel_lat;
  logic panel_oe;

  logic prev_panel_clk;
  logic prev_panel_lat;
  logic [CountWidth-1:0]    group_pixel_index;
  logic [CountWidth-1:0]    clk_pulse_count;
  logic [CountWidth-1:0]    latch_count;
  logic [RowAddrWidth-1:0]  expected_panel_addr;
  logic [ColorDepth-1:0]    expected_bcm;
  logic                     oe_seen;

  logic panel_clk_rise;
  logic panel_lat_rise;
  logic [DataWidth-1:0] current_expected_top_data;
  logic [DataWidth-1:0] current_expected_bottom_data;

  assign brightness = {BrightnessWidth{1'b1}};

  assign client_mem_req = {driver_mem_req, preload_mem_req};
  assign client_mem_write = {1'b0, preload_mem_req};
  assign client_mem_addr =
      {{(AddrWidth-DriverAddrWidth){1'b0}}, driver_mem_addr, preload_mem_addr};
  assign client_mem_write_data =
      {{DataWidth{1'b0}}, preload_mem_write_data};
  assign client_mem_read_length  = {driver_mem_read_length, 4'd1};
  assign client_mem_write_length = {4'd1, 4'd1};

  assign driver_mem_grant = client_mem_grant[1];
  assign driver_mem_read_data = client_mem_read_data[2*DataWidth-1:DataWidth];
  assign driver_mem_read_data_valid = client_mem_read_data_valid[1];

  assign panel_clk_rise = panel_clk && !prev_panel_clk;
  assign panel_lat_rise = panel_lat && !prev_panel_lat;
  assign current_expected_top_data =
      expected_top_data(group_pixel_index, expected_panel_addr);
  assign current_expected_bottom_data =
      expected_bottom_data(group_pixel_index, expected_panel_addr);

  function automatic logic [DataWidth-1:0] mem_pattern(
      input logic [AddrWidth-1:0] addr_in
  );
    logic [15:0] full_pat;
    full_pat    = addr_in[15:0] ^ 16'hA5C3;
    mem_pattern = full_pat[DataWidth-1:0];
  endfunction

  function automatic logic [AddrWidth-1:0] display_col_for_index(
      input logic [CountWidth-1:0] pixel_index
  );
    if (pixel_index == {CountWidth{1'b0}})
      display_col_for_index = {AddrWidth{1'b0}};
    else
      display_col_for_index = RowWidthIndex[AddrWidth-1:0] - pixel_index[AddrWidth-1:0];
  endfunction

  function automatic logic [DataWidth-1:0] expected_top_data(
      input logic [CountWidth-1:0]   pixel_index,
      input logic [RowAddrWidth-1:0] row_pair
  );
    logic [AddrWidth-1:0] addr;
    addr = (RowOffset + row_pair) * TotalRowWidth + display_col_for_index(pixel_index);
    expected_top_data = mem_pattern(addr);
  endfunction

  function automatic logic [DataWidth-1:0] expected_bottom_data(
      input logic [CountWidth-1:0]   pixel_index,
      input logic [RowAddrWidth-1:0] row_pair
  );
    logic [AddrWidth-1:0] addr;
    addr = (RowOffset + row_pair + RowPairCount) * TotalRowWidth +
           display_col_for_index(pixel_index);
    expected_bottom_data = mem_pattern(addr);
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
      dut_reset_n            <= 1'b0;
      wait_counter           <= {CountWidth{1'b0}};
      blink_counter          <= 25'd0;
      bist_done              <= 1'b0;
      fail_latched           <= 1'b0;
      led_status             <= 1'b1;
      preload_mem_req        <= 1'b0;
      preload_mem_addr       <= {AddrWidth{1'b0}};
      preload_mem_write_data <= {DataWidth{1'b0}};
      preload_index          <= {CountWidth{1'b0}};
      prev_panel_clk         <= 1'b0;
      prev_panel_lat         <= 1'b0;
      group_pixel_index      <= {CountWidth{1'b0}};
      clk_pulse_count        <= {CountWidth{1'b0}};
      latch_count            <= {CountWidth{1'b0}};
      expected_panel_addr    <= {RowAddrWidth{1'b0}};
      expected_bcm           <= {ColorDepth{1'b0}};
      oe_seen                <= 1'b0;
    end else begin
      blink_counter  <= blink_counter + 25'd1;
      prev_panel_clk <= panel_clk;
      prev_panel_lat <= panel_lat;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          dut_reset_n     <= 1'b0;
          preload_mem_req <= 1'b0;
          wait_counter    <= {CountWidth{1'b0}};
          if (start_event) begin
            bist_done              <= 1'b0;
            fail_latched           <= 1'b0;
            preload_index          <= {CountWidth{1'b0}};
            preload_mem_addr       <= {AddrWidth{1'b0}};
            preload_mem_write_data <= mem_pattern({AddrWidth{1'b0}});
            group_pixel_index      <= {CountWidth{1'b0}};
            clk_pulse_count        <= {CountWidth{1'b0}};
            latch_count            <= {CountWidth{1'b0}};
            expected_panel_addr    <= {RowAddrWidth{1'b0}};
            expected_bcm           <= {ColorDepth{1'b0}};
            oe_seen                <= 1'b0;
            state                  <= StPreloadReq;
          end
        end

        StPreloadReq: begin
          preload_mem_req        <= 1'b1;
          preload_mem_addr       <= preload_index[AddrWidth-1:0];
          preload_mem_write_data <= mem_pattern(preload_index[AddrWidth-1:0]);
          wait_counter           <= {CountWidth{1'b0}};
          state                  <= StPreloadWait;
        end

        StPreloadWait: begin
          if (client_mem_grant[0]) begin
            preload_mem_req <= 1'b0;
            wait_counter    <= {CountWidth{1'b0}};
            if (preload_index == LastPreloadIndex) begin
              state <= StReleaseDut;
            end else begin
              preload_index <= preload_index + {{(CountWidth-1){1'b0}}, 1'b1};
              state         <= StPreloadReq;
            end
          end else if (wait_counter >= PreloadWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        StReleaseDut: begin
          dut_reset_n         <= 1'b1;
          wait_counter        <= {CountWidth{1'b0}};
          group_pixel_index   <= {CountWidth{1'b0}};
          clk_pulse_count     <= {CountWidth{1'b0}};
          latch_count         <= {CountWidth{1'b0}};
          expected_panel_addr <= {RowAddrWidth{1'b0}};
          expected_bcm        <= {ColorDepth{1'b0}};
          oe_seen             <= 1'b0;
          state               <= StRun;
        end

        StRun: begin
          if (!panel_oe)
            oe_seen <= 1'b1;

          if (panel_clk_rise) begin
            if (panel_r1 != current_expected_top_data[(ColorDepth*2) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_g1 != current_expected_top_data[(ColorDepth*1) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_b1 != current_expected_top_data[(ColorDepth*0) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_r2 != current_expected_bottom_data[(ColorDepth*2) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_g2 != current_expected_bottom_data[(ColorDepth*1) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_b2 != current_expected_bottom_data[(ColorDepth*0) + expected_bcm])
              fail_latched <= 1'b1;

            clk_pulse_count <= clk_pulse_count + {{(CountWidth-1){1'b0}}, 1'b1};
            if (group_pixel_index == LastGroupPixel)
              group_pixel_index <= {CountWidth{1'b0}};
            else
              group_pixel_index <= group_pixel_index + {{(CountWidth-1){1'b0}}, 1'b1};
          end

          if (panel_lat_rise) begin
            if (panel_addr != expected_panel_addr)
              fail_latched <= 1'b1;

            latch_count       <= latch_count + {{(CountWidth-1){1'b0}}, 1'b1};
            group_pixel_index <= {CountWidth{1'b0}};
            if (expected_bcm == LastBcmIndex[ColorDepth-1:0]) begin
              expected_bcm <= {ColorDepth{1'b0}};
              if (expected_panel_addr == LastRowPairIndex[RowAddrWidth-1:0])
                expected_panel_addr <= {RowAddrWidth{1'b0}};
              else
                expected_panel_addr <= expected_panel_addr + {{(RowAddrWidth-1){1'b0}}, 1'b1};
            end else begin
              expected_bcm <= expected_bcm + {{(ColorDepth-1){1'b0}}, 1'b1};
            end
          end

          if (latch_count == TotalGroups && clk_pulse_count == TotalClkPulses) begin
            if (!oe_seen || fail_latched)
              fail_latched <= 1'b1;
            bist_done <= 1'b1;
            state     <= StIdle;
          end else if (wait_counter >= RunWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  led_panel_driver #(
    .SysClkHz(SysClkHz),
    .MaxPanelClkHz(MaxPanelClkHz),
    .RefreshRateHz(RefreshRateHz),
    .BrightnessWidth(BrightnessWidth),
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .RowOffset(RowOffset),
    .TotalDisplayHeight(TotalDisplayHeight)
  ) dut (
    .clk_i(clk_host),
    .rst_ni(dut_reset_n),
    .brightness_i(brightness),
    .mem_req_o(driver_mem_req),
    .mem_read_length_o(driver_mem_read_length),
    .mem_grant_i(driver_mem_grant),
    .mem_addr_o(driver_mem_addr),
    .mem_read_data_i(driver_mem_read_data),
    .mem_read_data_valid_i(driver_mem_read_data_valid),
    .panel_r1_o(panel_r1),
    .panel_g1_o(panel_g1),
    .panel_b1_o(panel_b1),
    .panel_r2_o(panel_r2),
    .panel_g2_o(panel_g2),
    .panel_b2_o(panel_b2),
    .panel_addr_o(panel_addr),
    .panel_clk_o(panel_clk),
    .panel_lat_o(panel_lat),
    .panel_oe_o(panel_oe)
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
