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
//   BrightnessWidth  - Global brightness input width (Default: 8)
//   TotalRowWidth   - Number of pixels/words per row (Default: 1024)
//   PanelHeight      - Number of panel rows (Default: 32)
//   ColorDepth       - Color bit depth per channel (Default: 4)
//
// Dependencies:
//   - display_driver.sv
// ============================================================================
// Revision History:
//   Current - display_driver HUB75 timing and data checker BIST.
// ============================================================================

module display_driver_bist_top #(
  parameter int unsigned SysClkHz         = 50_000_000,
  parameter int unsigned RefreshRateHz    = 240,
  parameter int unsigned BrightnessWidth  = 8,
  parameter int unsigned TotalRowWidth    = 1024,
  parameter int unsigned PanelHeight      = 32,
  parameter int unsigned ColorDepth       = 4
) (
    input  wire clk_50mhz,
    input  wire btn_start,
    input  wire btn_reset,
    output reg  led_status
);

    localparam PIXEL_DATA_WIDTH = ColorDepth * 3;
    localparam ROW_PAIR_COUNT   = PanelHeight / 2;
    localparam ADDR_WIDTH       = (TotalRowWidth <= 1) ? 1 : $clog2(TotalRowWidth);
    localparam ROW_ADDR_WIDTH   = (ROW_PAIR_COUNT <= 1) ? 1 : $clog2(ROW_PAIR_COUNT);
    localparam COUNT_WIDTH      = 32;
    localparam [COUNT_WIDTH-1:0] TOTAL_GROUPS = ROW_PAIR_COUNT * ColorDepth;
    localparam [COUNT_WIDTH-1:0] TOTAL_CLK_PULSES = TOTAL_GROUPS * TotalRowWidth;
    localparam [COUNT_WIDTH-1:0] OP_WAIT_TIMEOUT = (SysClkHz / RefreshRateHz) + 32'd100_000;
    localparam [ADDR_WIDTH-1:0] LAST_SHIFT_ADDR = TotalRowWidth - 1;

    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_RUN   = 2'd2;

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg start_display;
    wire display_complete;
    wire row_pair_done;
    wire busy;

    wire [BrightnessWidth-1:0] brightness = {BrightnessWidth{1'b1}};
    wire [PIXEL_DATA_WIDTH-1:0] buffer_rd_data_top;
    wire [PIXEL_DATA_WIDTH-1:0] buffer_rd_data_bottom;
    wire [ADDR_WIDTH-1:0] buffer_rd_addr;

    wire panel_r1;
    wire panel_g1;
    wire panel_b1;
    wire panel_r2;
    wire panel_g2;
    wire panel_b2;
    wire [ROW_ADDR_WIDTH-1:0] panel_addr;
    wire panel_clk;
    wire panel_lat;
    wire panel_oe;

    reg prev_panel_clk;
    reg prev_panel_lat;
    reg [ADDR_WIDTH-1:0] expected_shift_addr;
    reg [ROW_ADDR_WIDTH-1:0] expected_panel_addr;
    reg [ColorDepth-1:0] expected_bcm;
    reg [COUNT_WIDTH-1:0] clk_pulse_count;
    reg [COUNT_WIDTH-1:0] latch_count;
    reg [COUNT_WIDTH-1:0] row_pair_done_count;
    reg oe_seen;

    wire panel_clk_rise = panel_clk && !prev_panel_clk;
    wire panel_lat_rise = panel_lat && !prev_panel_lat;

    wire [PIXEL_DATA_WIDTH-1:0] expected_top_data = top_pattern(buffer_rd_addr);
    wire [PIXEL_DATA_WIDTH-1:0] expected_bottom_data = bottom_pattern(buffer_rd_addr);

    function [PIXEL_DATA_WIDTH-1:0] top_pattern;
        input [ADDR_WIDTH-1:0] addr_in;
        reg [7:0] addr_byte;
        reg [15:0] full_pat;
        begin
            addr_byte = addr_in;
            full_pat = {addr_byte, addr_byte} ^ 16'hA5C3;
            top_pattern = full_pat[PIXEL_DATA_WIDTH-1:0];
        end
    endfunction

    function [PIXEL_DATA_WIDTH-1:0] bottom_pattern;
        input [ADDR_WIDTH-1:0] addr_in;
        reg [7:0] addr_byte;
        reg [15:0] full_pat;
        begin
            addr_byte = addr_in;
            full_pat = {addr_byte, addr_byte} ^ 16'h3C5A;
            bottom_pattern = full_pat[PIXEL_DATA_WIDTH-1:0];
        end
    endfunction

    assign buffer_rd_data_top = top_pattern(buffer_rd_addr);
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
            state               <= ST_IDLE;
            wait_counter        <= {COUNT_WIDTH{1'b0}};
            blink_counter       <= 25'd0;
            bist_done           <= 1'b0;
            fail_latched        <= 1'b0;
            led_status          <= 1'b1;
            start_display       <= 1'b0;
            prev_panel_clk      <= 1'b0;
            prev_panel_lat      <= 1'b0;
            expected_shift_addr <= {ADDR_WIDTH{1'b0}};
            expected_panel_addr <= {ROW_ADDR_WIDTH{1'b0}};
            expected_bcm        <= {ColorDepth{1'b0}};
            clk_pulse_count     <= {COUNT_WIDTH{1'b0}};
            latch_count         <= {COUNT_WIDTH{1'b0}};
            row_pair_done_count <= {COUNT_WIDTH{1'b0}};
            oe_seen             <= 1'b0;
        end else begin
            blink_counter  <= blink_counter + 25'd1;
            start_display  <= 1'b0;
            prev_panel_clk <= panel_clk;
            prev_panel_lat <= panel_lat;

            if (fail_latched)          led_status <= ~blink_counter[24];
            else if (state != ST_IDLE) led_status <= ~blink_counter[21];
            else if (bist_done)        led_status <= 1'b0;
            else                       led_status <= 1'b1;

            case (state)
                ST_IDLE: begin
                    wait_counter <= {COUNT_WIDTH{1'b0}};
                    if (start_event) begin
                        bist_done           <= 1'b0;
                        fail_latched        <= 1'b0;
                        expected_shift_addr <= LAST_SHIFT_ADDR;
                        expected_panel_addr <= {ROW_ADDR_WIDTH{1'b0}};
                        expected_bcm        <= {ColorDepth{1'b0}};
                        clk_pulse_count     <= {COUNT_WIDTH{1'b0}};
                        latch_count         <= {COUNT_WIDTH{1'b0}};
                        row_pair_done_count <= {COUNT_WIDTH{1'b0}};
                        oe_seen             <= 1'b0;
                        state               <= ST_START;
                    end
                end

                ST_START: begin
                    start_display <= 1'b1;
                    wait_counter  <= {COUNT_WIDTH{1'b0}};
                    state         <= ST_RUN;
                end

                ST_RUN: begin
                    if (!busy && wait_counter > {{(COUNT_WIDTH-3){1'b0}}, 3'd4})
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

                        clk_pulse_count <= clk_pulse_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        if (expected_shift_addr == {ADDR_WIDTH{1'b0}})
                            expected_shift_addr <= LAST_SHIFT_ADDR;
                        else
                            expected_shift_addr <= expected_shift_addr - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
                    end

                    if (panel_lat_rise) begin
                        if (panel_addr != expected_panel_addr)
                            fail_latched <= 1'b1;

                        latch_count <= latch_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        if (expected_bcm == ColorDepth - 1) begin
                            expected_bcm <= {ColorDepth{1'b0}};
                            if (expected_panel_addr == ROW_PAIR_COUNT - 1)
                                expected_panel_addr <= {ROW_ADDR_WIDTH{1'b0}};
                            else
                                expected_panel_addr <= expected_panel_addr + {{(ROW_ADDR_WIDTH-1){1'b0}}, 1'b1};
                        end else begin
                            expected_bcm <= expected_bcm + {{(ColorDepth-1){1'b0}}, 1'b1};
                        end
                    end

                    if (row_pair_done)
                        row_pair_done_count <= row_pair_done_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};

                    if (display_complete) begin
                        if ((clk_pulse_count != TOTAL_CLK_PULSES) ||
                            (latch_count != TOTAL_GROUPS) ||
                            (row_pair_done_count != ROW_PAIR_COUNT) ||
                            !oe_seen ||
                            fail_latched) begin
                            fail_latched <= 1'b1;
                        end
                        bist_done <= 1'b1;
                        state     <= ST_IDLE;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                default: state <= ST_IDLE;
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
