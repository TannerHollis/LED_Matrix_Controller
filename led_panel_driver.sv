// ============================================================================
// File Name   : led_panel_driver.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Integrated LED panel driver: memory_fetcher, buffer_controller, four
//   line_buffer_ram instances, and display_driver. Streams one row pair at a
//   time from SDRAM through ping-pong line buffers to HUB75 outputs.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   SysClkHz, RefreshRateHz, BrightnessWidth, TotalRowWidth, PanelHeight,
//   ColorDepth, RowOffset, TotalDisplayHeight, ReadBurstLen
//
// Dependencies:
//   - memory_fetcher.sv
//   - buffer_controller.sv
//   - line_buffer_ram.sv
//   - display_driver.sv
//   - memory_arbiter.sv (client port)
// ============================================================================
// Revision History:
//   Current - Integrated fetch, ping-pong buffers, and HUB75 display driver.
// ============================================================================

module led_panel_driver #(
  parameter int unsigned SysClkHz           = 100_000_000,
  parameter int unsigned RefreshRateHz      = 60,
  parameter int unsigned BrightnessWidth    = 8,
  parameter int unsigned TotalRowWidth      = 32,
  parameter int unsigned PanelHeight        = 32,
  parameter int unsigned ColorDepth         = 4,
  parameter int unsigned RowOffset          = 0,
  parameter int unsigned TotalDisplayHeight = 32,
  parameter int unsigned ReadBurstLen       = 8
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [BrightnessWidth-1:0] brightness_i,

  output logic                                mem_req_o,
  output logic [3:0]                          mem_read_length_o,
  input  logic                                mem_grant_i,
  output logic [$clog2(TotalRowWidth * TotalDisplayHeight) - 1:0] mem_addr_o,
  input  logic [ColorDepth*3-1:0]             mem_read_data_i,
  input  logic                                mem_read_data_valid_i,

  output logic panel_r1_o,
  output logic panel_g1_o,
  output logic panel_b1_o,
  output logic panel_r2_o,
  output logic panel_g2_o,
  output logic panel_b2_o,
  output logic [$clog2(PanelHeight/2)-1:0] panel_addr_o,
  output logic panel_clk_o,
  output logic panel_lat_o,
  output logic panel_oe_o
);

  localparam int unsigned PixelDataWidth = ColorDepth * 3;

  logic                                fetch_complete;
  logic                                fetch_busy;
  logic                                start_fetch;
  logic [PixelDataWidth-1:0]           fetch_wr_data;
  logic [$clog2(TotalRowWidth)-1:0]    fetch_wr_addr;
  logic                                fetch_wr_en;
  logic                                fetch_buffer_sel;

  logic                                display_complete;
  logic                                display_busy;
  logic                                row_pair_done;
  logic                                start_display;
  logic [PixelDataWidth-1:0]           display_rd_data_top;
  logic [PixelDataWidth-1:0]           display_rd_data_bottom;
  logic [$clog2(TotalRowWidth)-1:0]    display_rd_addr;

  localparam int unsigned RowPairCount      = PanelHeight / 2;
  localparam int unsigned RowPairAddrWidth  =
      (RowPairCount <= 1) ? 1 : $clog2(RowPairCount);
  logic [RowPairAddrWidth-1:0] fetch_row_pair_index;
  logic                                panel_ready;

  logic [PixelDataWidth-1:0]           buffer_top_0_wr_data;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_top_0_wr_addr;
  logic                                buffer_top_0_wr_en;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_top_0_rd_addr;
  logic [PixelDataWidth-1:0]           buffer_top_0_rd_data;

  logic [PixelDataWidth-1:0]           buffer_top_1_wr_data;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_top_1_wr_addr;
  logic                                buffer_top_1_wr_en;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_top_1_rd_addr;
  logic [PixelDataWidth-1:0]           buffer_top_1_rd_data;

  logic [PixelDataWidth-1:0]           buffer_bot_0_wr_data;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_bot_0_wr_addr;
  logic                                buffer_bot_0_wr_en;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_bot_0_rd_addr;
  logic [PixelDataWidth-1:0]           buffer_bot_0_rd_data;

  logic [PixelDataWidth-1:0]           buffer_bot_1_wr_data;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_bot_1_wr_addr;
  logic                                buffer_bot_1_wr_en;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_bot_1_rd_addr;
  logic [PixelDataWidth-1:0]           buffer_bot_1_rd_data;

  memory_fetcher #(
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .RowOffset(RowOffset),
    .TotalDisplayHeight(TotalDisplayHeight),
    .ReadBurstLen(ReadBurstLen)
  ) memory_fetcher_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .mem_req_o(mem_req_o),
    .mem_read_length_o(mem_read_length_o),
    .mem_grant_i(mem_grant_i),
    .mem_addr_o(mem_addr_o),
    .mem_read_data_i(mem_read_data_i),
    .mem_read_data_valid_i(mem_read_data_valid_i),
    .buffer_wr_data_o(fetch_wr_data),
    .buffer_wr_addr_o(fetch_wr_addr),
    .buffer_wr_en_o(fetch_wr_en),
    .buffer_sel_o(fetch_buffer_sel),
    .fetch_complete_o(fetch_complete),
    .start_fetch_i(start_fetch),
    .row_pair_index_i(fetch_row_pair_index),
    .target_buffer_i(2'b00),
    .busy_o(fetch_busy)
  );

  display_driver #(
    .SysClkHz(SysClkHz),
    .RefreshRateHz(RefreshRateHz),
    .BrightnessWidth(BrightnessWidth),
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth)
  ) display_driver_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .brightness_i(brightness_i),
    .buffer_rd_data_top_i(display_rd_data_top),
    .buffer_rd_data_bottom_i(display_rd_data_bottom),
    .buffer_rd_addr_o(display_rd_addr),
    .panel_r1_o(panel_r1_o),
    .panel_g1_o(panel_g1_o),
    .panel_b1_o(panel_b1_o),
    .panel_r2_o(panel_r2_o),
    .panel_g2_o(panel_g2_o),
    .panel_b2_o(panel_b2_o),
    .panel_addr_o(panel_addr_o),
    .panel_clk_o(panel_clk_o),
    .panel_lat_o(panel_lat_o),
    .panel_oe_o(panel_oe_o),
    .start_display_i(start_display),
    .display_complete_o(display_complete),
    .row_pair_done_o(row_pair_done),
    .busy_o(display_busy)
  );

  buffer_controller #(
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth)
  ) buffer_controller_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .fetch_complete_i(fetch_complete),
    .fetch_busy_i(fetch_busy),
    .start_fetch_o(start_fetch),
    .fetch_row_pair_index_o(fetch_row_pair_index),
    .fetch_wr_data_i(fetch_wr_data),
    .fetch_wr_addr_i(fetch_wr_addr),
    .fetch_wr_en_i(fetch_wr_en),
    .fetch_buffer_sel_i(fetch_buffer_sel),
    .display_complete_i(display_complete),
    .display_busy_i(display_busy),
    .row_pair_done_i(row_pair_done),
    .start_display_o(start_display),
    .display_rd_data_top_o(display_rd_data_top),
    .display_rd_data_bottom_o(display_rd_data_bottom),
    .display_rd_addr_i(display_rd_addr),
    .buffer_top_0_wr_data_o(buffer_top_0_wr_data),
    .buffer_top_0_wr_addr_o(buffer_top_0_wr_addr),
    .buffer_top_0_wr_en_o(buffer_top_0_wr_en),
    .buffer_top_0_rd_addr_o(buffer_top_0_rd_addr),
    .buffer_top_0_rd_data_i(buffer_top_0_rd_data),
    .buffer_top_1_wr_data_o(buffer_top_1_wr_data),
    .buffer_top_1_wr_addr_o(buffer_top_1_wr_addr),
    .buffer_top_1_wr_en_o(buffer_top_1_wr_en),
    .buffer_top_1_rd_addr_o(buffer_top_1_rd_addr),
    .buffer_top_1_rd_data_i(buffer_top_1_rd_data),
    .buffer_bot_0_wr_data_o(buffer_bot_0_wr_data),
    .buffer_bot_0_wr_addr_o(buffer_bot_0_wr_addr),
    .buffer_bot_0_wr_en_o(buffer_bot_0_wr_en),
    .buffer_bot_0_rd_addr_o(buffer_bot_0_rd_addr),
    .buffer_bot_0_rd_data_i(buffer_bot_0_rd_data),
    .buffer_bot_1_wr_data_o(buffer_bot_1_wr_data),
    .buffer_bot_1_wr_addr_o(buffer_bot_1_wr_addr),
    .buffer_bot_1_wr_en_o(buffer_bot_1_wr_en),
    .buffer_bot_1_rd_addr_o(buffer_bot_1_rd_addr),
    .buffer_bot_1_rd_data_i(buffer_bot_1_rd_data),
    .ready_o(panel_ready),
    .active_buffer_set_o()
  );

  line_buffer_ram #(
    .DataWidth(PixelDataWidth),
    .AddrWidth($clog2(TotalRowWidth)),
    .Depth(TotalRowWidth)
  ) line_buffer_top_0_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .wr_data_i(buffer_top_0_wr_data),
    .wr_addr_i(buffer_top_0_wr_addr),
    .wr_en_i(buffer_top_0_wr_en),
    .rd_addr_i(buffer_top_0_rd_addr),
    .rd_data_o(buffer_top_0_rd_data)
  );

  line_buffer_ram #(
    .DataWidth(PixelDataWidth),
    .AddrWidth($clog2(TotalRowWidth)),
    .Depth(TotalRowWidth)
  ) line_buffer_top_1_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .wr_data_i(buffer_top_1_wr_data),
    .wr_addr_i(buffer_top_1_wr_addr),
    .wr_en_i(buffer_top_1_wr_en),
    .rd_addr_i(buffer_top_1_rd_addr),
    .rd_data_o(buffer_top_1_rd_data)
  );

  line_buffer_ram #(
    .DataWidth(PixelDataWidth),
    .AddrWidth($clog2(TotalRowWidth)),
    .Depth(TotalRowWidth)
  ) line_buffer_bot_0_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .wr_data_i(buffer_bot_0_wr_data),
    .wr_addr_i(buffer_bot_0_wr_addr),
    .wr_en_i(buffer_bot_0_wr_en),
    .rd_addr_i(buffer_bot_0_rd_addr),
    .rd_data_o(buffer_bot_0_rd_data)
  );

  line_buffer_ram #(
    .DataWidth(PixelDataWidth),
    .AddrWidth($clog2(TotalRowWidth)),
    .Depth(TotalRowWidth)
  ) line_buffer_bot_1_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .wr_data_i(buffer_bot_1_wr_data),
    .wr_addr_i(buffer_bot_1_wr_addr),
    .wr_en_i(buffer_bot_1_wr_en),
    .rd_addr_i(buffer_bot_1_rd_addr),
    .rd_data_o(buffer_bot_1_rd_data)
  );

endmodule
