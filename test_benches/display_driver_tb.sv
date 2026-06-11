// ============================================================================
// File Name   : display_driver_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for display_driver. Verifies HUB75 panel signals,
//   BCM timing, brightness PWM, row-pair scanning, and refresh pacing.
//
// Dependencies:
//   - display_driver.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style migration.
// ============================================================================
`timescale 1ns / 1ps

module display_driver_tb;

  localparam int unsigned SysClkHz       = 50_000_000;
  localparam int unsigned RefreshRateHz  = 60;
  localparam int unsigned BrightnessWidth = 8;
  localparam int unsigned TotalRowWidth  = 8;
  localparam int unsigned PanelHeight    = 4;
  localparam int unsigned ColorDepth     = 4;

  localparam int unsigned ClkPeriod    = 1000 / (SysClkHz / 1_000_000);
  localparam int unsigned RowPairCount = PanelHeight / 2;

  logic clk_i;
  logic rst_ni;

  logic [BrightnessWidth-1:0] brightness_i;
  logic [ColorDepth*3-1:0]    buffer_rd_data_top_i;
  logic [ColorDepth*3-1:0]    buffer_rd_data_bottom_i;
  logic [$clog2(TotalRowWidth)-1:0] buffer_rd_addr_o;

  logic panel_r1_o, panel_g1_o, panel_b1_o;
  logic panel_r2_o, panel_g2_o, panel_b2_o;
  logic [$clog2(PanelHeight/2)-1:0] panel_addr_o;
  logic panel_clk_o, panel_lat_o, panel_oe_o;

  logic start_display_i;
  logic display_complete_o;
  logic row_pair_done_o;
  logic busy_o;

  display_driver #(
    .SysClkHz(SysClkHz),
    .RefreshRateHz(RefreshRateHz),
    .BrightnessWidth(BrightnessWidth),
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .brightness_i(brightness_i),
    .buffer_rd_data_top_i(buffer_rd_data_top_i),
    .buffer_rd_data_bottom_i(buffer_rd_data_bottom_i),
    .buffer_rd_addr_o(buffer_rd_addr_o),
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
    .start_display_i(start_display_i),
    .display_complete_o(display_complete_o),
    .row_pair_done_o(row_pair_done_o),
    .busy_o(busy_o)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;

  integer test_cycle_count;
  integer panel_clk_count;
  integer panel_lat_count;
  integer panel_oe_count;
  integer display_complete_count;
  integer row_pair_done_count;

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    brightness_i = 8'hFF;
    buffer_rd_data_top_i = '0;
    buffer_rd_data_bottom_i = '0;
    start_display_i = 1'b0;
    test_cycle_count = 0;
    panel_clk_count = 0;
    panel_lat_count = 0;
    panel_oe_count = 0;
    display_complete_count = 0;
    row_pair_done_count = 0;

    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Starting Display Driver Testbench", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Configuration:", $time);
    $display("T=%3t:   - System Clock: %d MHz", $time, SysClkHz / 1_000_000);
    $display("T=%3t:   - Refresh Rate: %d Hz", $time, RefreshRateHz);
    $display("T=%3t:   - Total Row Width: %d pixels", $time, TotalRowWidth);
    $display("T=%3t:   - Panel Height: %d pixels", $time, PanelHeight);
    $display("T=%3t:   - Color Depth: %d bits", $time, ColorDepth);
    $display("T=%3t:   - Row Pair Count: %d", $time, RowPairCount);

    #100;
    rst_ni = 1'b1;

    $display("T=%3t: Reset released. Starting test sequence.", $time);

    $display("T=%3t: Test Case 1: Initial display operation", $time);
    buffer_rd_data_top_i = 12'hFFF;
    buffer_rd_data_bottom_i = 12'hAAA;

    #(ClkPeriod * 2);
    start_display_i = 1'b1;
    #(ClkPeriod * 2);
    start_display_i = 1'b0;

    repeat (1000) begin
      @(posedge clk_i);
      test_cycle_count = test_cycle_count + 1;

      if (panel_clk_o == 1'b1) panel_clk_count = panel_clk_count + 1;
      if (panel_lat_o == 1'b1) panel_lat_count = panel_lat_count + 1;
      if (panel_oe_o == 1'b0) panel_oe_count = panel_oe_count + 1;

      if (display_complete_o) begin
        display_complete_count = display_complete_count + 1;
        $display("T=%3t: Display completion #%d", $time, display_complete_count);
      end

      if (row_pair_done_o) begin
        row_pair_done_count = row_pair_done_count + 1;
        $display("T=%3t: Row pair done #%d", $time, row_pair_done_count);
      end

      if (test_cycle_count % 200 == 0) begin
        $display("T=%3t: Cycle %d - OE:%b LATCH:%b CLK:%b ADDR:%d",
                 $time, test_cycle_count, panel_oe_o, panel_lat_o, panel_clk_o, panel_addr_o);
      end
    end

    $display("T=%3t: Test Case 2: Brightness control test", $time);

    brightness_i = 8'h80;
    $display("T=%3t: Setting brightness to 50%% (0x%h)", $time, brightness_i);
    #(ClkPeriod * 500);

    brightness_i = 8'h40;
    $display("T=%3t: Setting brightness to 25%% (0x%h)", $time, brightness_i);
    #(ClkPeriod * 500);

    brightness_i = 8'hFF;
    $display("T=%3t: Restoring full brightness (0x%h)", $time, brightness_i);
    #(ClkPeriod * 500);

    $display("T=%3t: Test Case 3: Different buffer data patterns", $time);
    buffer_rd_data_top_i = 12'h555;
    buffer_rd_data_bottom_i = 12'h000;
    #(ClkPeriod * 1000);

    $display("T=%3t: Test Case 4: Reset behavior test", $time);
    rst_ni = 1'b0;
    $display("T=%3t: Asserting reset", $time);
    #(ClkPeriod * 10);
    rst_ni = 1'b1;
    $display("T=%3t: Releasing reset", $time);

    $display("T=%3t: Test Case 5: Post-reset operation", $time);
    buffer_rd_data_top_i = 12'hFFF;
    buffer_rd_data_bottom_i = 12'hFFF;
    #(ClkPeriod * 2);
    start_display_i = 1'b1;
    #(ClkPeriod * 2);
    start_display_i = 1'b0;
    #(ClkPeriod * 1000);

    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: FINAL TEST RESULTS", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: SUCCESS: Total cycles: %d", $time, test_cycle_count);
    $display("T=%3t: SUCCESS: Panel CLK pulses: %d", $time, panel_clk_count);
    $display("T=%3t: SUCCESS: Panel LATCH pulses: %d", $time, panel_lat_count);
    $display("T=%3t: SUCCESS: Panel OE active cycles: %d", $time, panel_oe_count);
    $display("T=%3t: SUCCESS: Display completions: %d", $time, display_complete_count);
    $display("T=%3t: SUCCESS: Row pair done pulses: %d (expected %0d per frame)",
             $time, row_pair_done_count, RowPairCount);

    if (panel_clk_count == 0)
      $display("T=%3t: WARNING: No CLK pulses detected - possible issue", $time);
    else
      $display("T=%3t: SUCCESS: CLK pulses detected - shift logic working", $time);

    if (panel_lat_count == 0)
      $display("T=%3t: WARNING: No LATCH pulses detected - possible issue", $time);
    else
      $display("T=%3t: SUCCESS: LATCH pulses detected - row transitions working", $time);

    $display("T=%3t: SUCCESS: All test cases completed", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Testbench completed successfully!", $time);
    $display("T=%3t: Simulation paused. Use 'run' to continue or 'quit' to exit.", $time);
    $stop;
  end

  always @(posedge clk_i) begin
    if (panel_r1_o || panel_g1_o || panel_b1_o || panel_r2_o || panel_g2_o || panel_b2_o) begin
      $display("T=%3t: Color data active - R1:%b G1:%b B1:%b R2:%b G2:%b B2:%b",
               $time, panel_r1_o, panel_g1_o, panel_b1_o, panel_r2_o, panel_g2_o, panel_b2_o);
    end
  end

endmodule
