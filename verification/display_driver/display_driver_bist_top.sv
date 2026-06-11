// ============================================================================
// File Name   : display_driver_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for display_driver only. Synthetic buffer data is driven
//   from the display driver's buffer read address, then an internal checker
//   verifies start/busy/complete sequencing, HUB75 shift clock count, latch and
//   row-address sequencing, OE activity, and RGB bit selection for each BCM
//   plane. HUB75 outputs are intentionally kept internal for this first BIST;
//   route them to headers later when physical panel-pin assignments are chosen.
//
// Parameters  :
//   SysClkHz        - Input clock frequency in Hz (Default: 50 MHz)
//   RefreshRateHz   - Display refresh rate used by DUT timing (Default: 60)
//   BrightnessWidth - Global brightness input width (Default: 8)
//   TotalRowWidth   - Number of pixels/words per row (Default: 1024)
//   PanelHeight     - Number of panel rows (Default: 32)
//   ColorDepth      - Color bit depth per channel (Default: 4)
//
// Dependencies:
//   - display_driver.sv
// ============================================================================
// Revision History:
//   Current - Migrated to lowRISC style (logic, enum FSM, unique case).
//   Prior   - display_driver HUB75 timing and data checker BIST.
// ============================================================================

module display_driver_bist_top #(
  parameter int unsigned SysClkHz        = 50_000_000,
  parameter int unsigned RefreshRateHz   = 240,
  parameter int unsigned BrightnessWidth = 8,
  parameter int unsigned TotalRowWidth     = 1024,
  parameter int unsigned PanelHeight     = 32,
  parameter int unsigned ColorDepth      = 4
) (
  input  logic clk_50mhz,
  input  logic btn_start,
  input  logic btn_reset,
  output logic led_status
);

  localparam int unsigned PixelDataWidth = ColorDepth * 3;
  localparam int unsigned RowPairCount   = PanelHeight / 2;
  localparam int unsigned AddrWidth =
      (TotalRowWidth <= 1) ? 1 : $clog2(TotalRowWidth);
  localparam int unsigned RowAddrWidth =
      (RowPairCount <= 1) ? 1 : $clog2(RowPairCount);
  localparam int unsigned CountWidth = 32;
  localparam logic [CountWidth-1:0] TotalGroups =
      RowPairCount * ColorDepth;
  localparam logic [CountWidth-1:0] TotalClkPulses =
      TotalGroups * TotalRowWidth;
  localparam logic [CountWidth-1:0] OpWaitTimeout =
      (SysClkHz / RefreshRateHz) + 32'd100_000;
  localparam logic [AddrWidth-1:0] LastShiftAddr = TotalRowWidth - 1;

  typedef enum logic [1:0] {
    StIdle,
    StStart,
    StRun
  } bist_state_e;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  bist_state_e state;
  logic [CountWidth-1:0] wait_counter;
  logic [24:0]           blink_counter;
  logic                  bist_done;
  logic                  fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic start_display;
  logic display_complete;
  logic row_pair_done;
  logic busy;

  logic [BrightnessWidth-1:0] brightness;
  logic [PixelDataWidth-1:0]  buffer_rd_data_top;
  logic [PixelDataWidth-1:0]  buffer_rd_data_bottom;
  logic [AddrWidth-1:0]       buffer_rd_addr;

  assign brightness = {BrightnessWidth{1'b1}};

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
  logic [AddrWidth-1:0]      expected_shift_addr;
  logic [RowAddrWidth-1:0]   expected_panel_addr;
  logic [ColorDepth-1:0]     expected_bcm;
  logic [CountWidth-1:0]     clk_pulse_count;
  logic [CountWidth-1:0]     latch_count;
  logic [CountWidth-1:0]     row_pair_done_count;
  logic                      oe_seen;

  logic panel_clk_rise;
  logic panel_lat_rise;
  assign panel_clk_rise = panel_clk && !prev_panel_clk;
  assign panel_lat_rise = panel_lat && !prev_panel_lat;

  function automatic logic [PixelDataWidth-1:0] top_pattern(
      input logic [AddrWidth-1:0] addr_in);
    logic [7:0]  addr_byte;
    logic [15:0] full_pat;
    addr_byte  = addr_in;
    full_pat   = {addr_byte, addr_byte} ^ 16'hA5C3;
    top_pattern = full_pat[PixelDataWidth-1:0];
  endfunction

  function automatic logic [PixelDataWidth-1:0] bottom_pattern(
      input logic [AddrWidth-1:0] addr_in);
    logic [7:0]  addr_byte;
    logic [15:0] full_pat;
    addr_byte     = addr_in;
    full_pat      = {addr_byte, addr_byte} ^ 16'h3C5A;
    bottom_pattern = full_pat[PixelDataWidth-1:0];
  endfunction

  logic [PixelDataWidth-1:0] expected_top_data;
  logic [PixelDataWidth-1:0] expected_bottom_data;
  assign expected_top_data    = top_pattern(buffer_rd_addr);
  assign expected_bottom_data = bottom_pattern(buffer_rd_addr);
  assign buffer_rd_data_top    = top_pattern(buffer_rd_addr);
  assign buffer_rd_data_bottom = bottom_pattern(buffer_rd_addr);

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
      state               <= StIdle;
      wait_counter        <= {CountWidth{1'b0}};
      blink_counter       <= 25'd0;
      bist_done           <= 1'b0;
      fail_latched        <= 1'b0;
      led_status          <= 1'b1;
      start_display       <= 1'b0;
      prev_panel_clk      <= 1'b0;
      prev_panel_lat      <= 1'b0;
      expected_shift_addr <= {AddrWidth{1'b0}};
      expected_panel_addr <= {RowAddrWidth{1'b0}};
      expected_bcm        <= {ColorDepth{1'b0}};
      clk_pulse_count     <= {CountWidth{1'b0}};
      latch_count         <= {CountWidth{1'b0}};
      row_pair_done_count <= {CountWidth{1'b0}};
      oe_seen             <= 1'b0;
    end else begin
      blink_counter  <= blink_counter + 25'd1;
      start_display  <= 1'b0;
      prev_panel_clk <= panel_clk;
      prev_panel_lat <= panel_lat;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          wait_counter <= {CountWidth{1'b0}};
          if (start_event) begin
            bist_done           <= 1'b0;
            fail_latched        <= 1'b0;
            expected_shift_addr <= LastShiftAddr;
            expected_panel_addr <= {RowAddrWidth{1'b0}};
            expected_bcm        <= {ColorDepth{1'b0}};
            clk_pulse_count     <= {CountWidth{1'b0}};
            latch_count         <= {CountWidth{1'b0}};
            row_pair_done_count <= {CountWidth{1'b0}};
            oe_seen             <= 1'b0;
            state               <= StStart;
          end
        end

        StStart: begin
          start_display <= 1'b1;
          wait_counter  <= {CountWidth{1'b0}};
          state         <= StRun;
        end

        // HUB75 timing checker: shift clock, latch, row addr, BCM plane, OE.
        StRun: begin
          if (!busy && wait_counter > {{(CountWidth-3){1'b0}}, 3'd4})
            fail_latched <= 1'b1;

          if (!panel_oe)
            oe_seen <= 1'b1;

          if (panel_clk_rise) begin
            if (buffer_rd_addr != expected_shift_addr)
              fail_latched <= 1'b1;
            if (panel_r1 != expected_top_data[(ColorDepth*2) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_g1 != expected_top_data[(ColorDepth*1) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_b1 != expected_top_data[(ColorDepth*0) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_r2 != expected_bottom_data[(ColorDepth*2) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_g2 != expected_bottom_data[(ColorDepth*1) + expected_bcm])
              fail_latched <= 1'b1;
            if (panel_b2 != expected_bottom_data[(ColorDepth*0) + expected_bcm])
              fail_latched <= 1'b1;

            clk_pulse_count <= clk_pulse_count + {{(CountWidth-1){1'b0}}, 1'b1};
            if (expected_shift_addr == {AddrWidth{1'b0}})
              expected_shift_addr <= LastShiftAddr;
            else
              expected_shift_addr <= expected_shift_addr - {{(AddrWidth-1){1'b0}}, 1'b1};
          end

          if (panel_lat_rise) begin
            if (panel_addr != expected_panel_addr)
              fail_latched <= 1'b1;

            latch_count <= latch_count + {{(CountWidth-1){1'b0}}, 1'b1};
            if (expected_bcm == ColorDepth - 1) begin
              expected_bcm <= {ColorDepth{1'b0}};
              if (expected_panel_addr == RowPairCount - 1)
                expected_panel_addr <= {RowAddrWidth{1'b0}};
              else
                expected_panel_addr <= expected_panel_addr + {{(RowAddrWidth-1){1'b0}}, 1'b1};
            end else begin
              expected_bcm <= expected_bcm + {{(ColorDepth-1){1'b0}}, 1'b1};
            end
          end

          if (row_pair_done)
            row_pair_done_count <= row_pair_done_count + {{(CountWidth-1){1'b0}}, 1'b1};

          if (display_complete) begin
            if ((clk_pulse_count != TotalClkPulses) ||
                (latch_count != TotalGroups) ||
                (row_pair_done_count != RowPairCount) ||
                !oe_seen ||
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
            wait_counter <= wait_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

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
    .brightness_i(brightness),
    .buffer_rd_data_top_i(buffer_rd_data_top),
    .buffer_rd_data_bottom_i(buffer_rd_data_bottom),
    .buffer_rd_addr_o(buffer_rd_addr),
    .panel_r1_o(panel_r1),
    .panel_g1_o(panel_g1),
    .panel_b1_o(panel_b1),
    .panel_r2_o(panel_r2),
    .panel_g2_o(panel_g2),
    .panel_b2_o(panel_b2),
    .panel_addr_o(panel_addr),
    .panel_clk_o(panel_clk),
    .panel_lat_o(panel_lat),
    .panel_oe_o(panel_oe),
    .start_display_i(start_display),
    .display_complete_o(display_complete),
    .row_pair_done_o(row_pair_done),
    .busy_o(busy)
  );

endmodule
