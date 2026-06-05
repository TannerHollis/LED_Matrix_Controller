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
//   BrightnessWidth     - Global brightness input width (Default: 8)
//   TotalRowWidth      - Number of pixels/words per row (Default: 1024)
//   PanelHeight         - Number of panel rows (Default: 32)
//   ColorDepth          - Color bit depth per channel (Default: 4)
//   RowOffset           - Base row offset used by memory_fetcher (Default: 0)
//   TotalDisplayHeight - Memory_fetcher address-height parameter (Default: 32)
//   AddrWidth           - Arbiter/SDRAM client address width (Default: 24)
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
//   Current - SDRAM-backed led_panel_driver with internal HUB75 checker.
// ============================================================================

module led_panel_driver_bist_top #(
  parameter int unsigned SysClkHz           = 50_000_000,
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
    input  wire        clk_50mhz,
    input  wire        btn_start,
    input  wire        btn_reset,
    output reg         led_status,
    output wire [12:0] sdram_addr,
    output wire [1:0]  sdram_ba,
    output wire        sdram_cas_n,
    output wire        sdram_cke,
    output wire        sdram_clk,
    output wire        sdram_cs_n,
    inout  wire [15:0] sdram_dq,
    output wire [1:0]  sdram_dqm,
    output wire        sdram_ras_n,
    output wire        sdram_we_n
);

    localparam DATA_WIDTH = ColorDepth * 3;
    localparam DRIVER_ADDR_WIDTH = (TotalRowWidth * TotalDisplayHeight <= 1) ?
                                   1 : $clog2(TotalRowWidth * TotalDisplayHeight);
    localparam ROW_ADDR_WIDTH = (PanelHeight / 2 <= 1) ? 1 : $clog2(PanelHeight / 2);
    localparam ROW_PAIR_COUNT = PanelHeight / 2;
    localparam SDRAM_ADDR_WIDTH = SdramBankWidth + SdramRowWidth + SdramColWidth;
    localparam COUNT_WIDTH = 32;
    localparam [COUNT_WIDTH-1:0] FETCH_WORDS = TotalRowWidth * PanelHeight;
    localparam [COUNT_WIDTH-1:0] LAST_PRELOAD_INDEX = FETCH_WORDS - 1;
    localparam [COUNT_WIDTH-1:0] TOTAL_GROUPS = ROW_PAIR_COUNT * ColorDepth;
    localparam [COUNT_WIDTH-1:0] TOTAL_CLK_PULSES = TOTAL_GROUPS * TotalRowWidth;
    localparam [COUNT_WIDTH-1:0] LAST_GROUP_PIXEL = TotalRowWidth - 1;
    localparam integer ROW_WIDTH_INDEX = TotalRowWidth;
    localparam integer LAST_ROW_PAIR_INDEX = ROW_PAIR_COUNT - 1;
    localparam integer LAST_BCM_INDEX = ColorDepth - 1;
    localparam [COUNT_WIDTH-1:0] PRELOAD_WAIT_TIMEOUT = 32'd10_000_000;
    localparam [COUNT_WIDTH-1:0] RUN_WAIT_TIMEOUT = 32'd20_000_000;

    localparam ST_IDLE         = 3'd0;
    localparam ST_PRELOAD_REQ  = 3'd1;
    localparam ST_PRELOAD_WAIT = 3'd2;
    localparam ST_RELEASE_DUT  = 3'd3;
    localparam ST_RUN          = 3'd4;

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg dut_reset_n;
    reg [2:0] state;
    reg [COUNT_WIDTH-1:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg preload_mem_req;
    reg [AddrWidth-1:0] preload_mem_addr;
    reg [DATA_WIDTH-1:0] preload_mem_write_data;
    reg [COUNT_WIDTH-1:0] preload_index;

    wire driver_mem_req;
    wire [3:0] driver_mem_read_length;
    wire driver_mem_grant;
    wire [DRIVER_ADDR_WIDTH-1:0] driver_mem_addr;
    wire [DATA_WIDTH-1:0] driver_mem_read_data;
    wire driver_mem_read_data_valid;

    wire [1:0] client_mem_req = {driver_mem_req, preload_mem_req};
    wire [1:0] client_mem_write = {1'b0, preload_mem_req};
    wire [AddrWidth*2-1:0] client_mem_addr =
        {{(AddrWidth-DRIVER_ADDR_WIDTH){1'b0}}, driver_mem_addr, preload_mem_addr};
    wire [DATA_WIDTH*2-1:0] client_mem_write_data =
        {{DATA_WIDTH{1'b0}}, preload_mem_write_data};
    wire [7:0] client_mem_read_length  = {driver_mem_read_length, 4'd1};
    wire [7:0] client_mem_write_length = {4'd1, 4'd1};
    wire [1:0] client_mem_grant;
    wire [DATA_WIDTH*2-1:0] client_mem_read_data;
    wire [1:0] client_mem_read_data_valid;

    wire master_mem_req;
    wire master_mem_write;
    wire [AddrWidth-1:0] master_mem_addr;
    wire [DATA_WIDTH-1:0] master_mem_write_data;
    wire master_mem_ready;
    wire [3:0] master_mem_read_length;
    wire [3:0] master_mem_write_length;
    wire [DATA_WIDTH-1:0] master_mem_read_data;
    wire master_mem_read_data_valid;

    wire [15:0] sdram_write_data;
    wire sdram_write_request;
    wire [SDRAM_ADDR_WIDTH-1:0] sdram_write_addr;
    wire [8:0] sdram_write_length;
    wire sdram_write_load;
    wire sdram_write_full;
    wire [15:0] sdram_write_used;
    wire [15:0] sdram_read_data;
    wire sdram_read_request;
    wire [SDRAM_ADDR_WIDTH-1:0] sdram_read_addr;
    wire [8:0] sdram_read_length;
    wire sdram_read_load;
    wire sdram_read_empty;

    wire [BrightnessWidth-1:0] brightness = {BrightnessWidth{1'b1}};
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
    reg [COUNT_WIDTH-1:0] group_pixel_index;
    reg [COUNT_WIDTH-1:0] clk_pulse_count;
    reg [COUNT_WIDTH-1:0] latch_count;
    reg [ROW_ADDR_WIDTH-1:0] expected_panel_addr;
    reg [ColorDepth-1:0] expected_bcm;
    reg oe_seen;

    wire panel_clk_rise = panel_clk && !prev_panel_clk;
    wire panel_lat_rise = panel_lat && !prev_panel_lat;
    wire [DATA_WIDTH-1:0] current_expected_top_data =
        expected_top_data(group_pixel_index, expected_panel_addr);
    wire [DATA_WIDTH-1:0] current_expected_bottom_data =
        expected_bottom_data(group_pixel_index, expected_panel_addr);

    assign driver_mem_grant = client_mem_grant[1];
    assign driver_mem_read_data = client_mem_read_data[2*DATA_WIDTH-1:DATA_WIDTH];
    assign driver_mem_read_data_valid = client_mem_read_data_valid[1];

    function [DATA_WIDTH-1:0] mem_pattern;
        input [AddrWidth-1:0] addr_in;
        reg [15:0] full_pat;
        begin
            full_pat = addr_in[15:0] ^ 16'hA5C3;
            mem_pattern = full_pat[DATA_WIDTH-1:0];
        end
    endfunction

    function [AddrWidth-1:0] display_col_for_index;
        input [COUNT_WIDTH-1:0] pixel_index;
        begin
            if (pixel_index == {COUNT_WIDTH{1'b0}})
                display_col_for_index = {AddrWidth{1'b0}};
            else
                display_col_for_index = ROW_WIDTH_INDEX[AddrWidth-1:0] - pixel_index[AddrWidth-1:0];
        end
    endfunction

    function [DATA_WIDTH-1:0] expected_top_data;
        input [COUNT_WIDTH-1:0] pixel_index;
        input [ROW_ADDR_WIDTH-1:0] row_pair;
        reg [AddrWidth-1:0] addr;
        begin
            addr = (RowOffset + row_pair) * TotalRowWidth + display_col_for_index(pixel_index);
            expected_top_data = mem_pattern(addr);
        end
    endfunction

    function [DATA_WIDTH-1:0] expected_bottom_data;
        input [COUNT_WIDTH-1:0] pixel_index;
        input [ROW_ADDR_WIDTH-1:0] row_pair;
        reg [AddrWidth-1:0] addr;
        begin
            addr = (RowOffset + row_pair + ROW_PAIR_COUNT) * TotalRowWidth +
                   display_col_for_index(pixel_index);
            expected_bottom_data = mem_pattern(addr);
        end
    endfunction

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
            state                  <= ST_IDLE;
            dut_reset_n            <= 1'b0;
            wait_counter           <= {COUNT_WIDTH{1'b0}};
            blink_counter          <= 25'd0;
            bist_done              <= 1'b0;
            fail_latched           <= 1'b0;
            led_status             <= 1'b1;
            preload_mem_req        <= 1'b0;
            preload_mem_addr       <= {AddrWidth{1'b0}};
            preload_mem_write_data <= {DATA_WIDTH{1'b0}};
            preload_index          <= {COUNT_WIDTH{1'b0}};
            prev_panel_clk         <= 1'b0;
            prev_panel_lat         <= 1'b0;
            group_pixel_index      <= {COUNT_WIDTH{1'b0}};
            clk_pulse_count        <= {COUNT_WIDTH{1'b0}};
            latch_count            <= {COUNT_WIDTH{1'b0}};
            expected_panel_addr    <= {ROW_ADDR_WIDTH{1'b0}};
            expected_bcm           <= {ColorDepth{1'b0}};
            oe_seen                <= 1'b0;
        end else begin
            blink_counter  <= blink_counter + 25'd1;
            prev_panel_clk <= panel_clk;
            prev_panel_lat <= panel_lat;

            if (fail_latched)          led_status <= ~blink_counter[24];
            else if (state != ST_IDLE) led_status <= ~blink_counter[21];
            else if (bist_done)        led_status <= 1'b0;
            else                       led_status <= 1'b1;

            case (state)
                ST_IDLE: begin
                    dut_reset_n     <= 1'b0;
                    preload_mem_req <= 1'b0;
                    wait_counter    <= {COUNT_WIDTH{1'b0}};
                    if (start_event) begin
                        bist_done              <= 1'b0;
                        fail_latched           <= 1'b0;
                        preload_index          <= {COUNT_WIDTH{1'b0}};
                        preload_mem_addr       <= {AddrWidth{1'b0}};
                        preload_mem_write_data <= mem_pattern({AddrWidth{1'b0}});
                        group_pixel_index      <= {COUNT_WIDTH{1'b0}};
                        clk_pulse_count        <= {COUNT_WIDTH{1'b0}};
                        latch_count            <= {COUNT_WIDTH{1'b0}};
                        expected_panel_addr    <= {ROW_ADDR_WIDTH{1'b0}};
                        expected_bcm           <= {ColorDepth{1'b0}};
                        oe_seen                <= 1'b0;
                        state                  <= ST_PRELOAD_REQ;
                    end
                end

                ST_PRELOAD_REQ: begin
                    preload_mem_req        <= 1'b1;
                    preload_mem_addr       <= preload_index[AddrWidth-1:0];
                    preload_mem_write_data <= mem_pattern(preload_index[AddrWidth-1:0]);
                    wait_counter           <= {COUNT_WIDTH{1'b0}};
                    state                  <= ST_PRELOAD_WAIT;
                end

                ST_PRELOAD_WAIT: begin
                    if (client_mem_grant[0]) begin
                        preload_mem_req <= 1'b0;
                        wait_counter    <= {COUNT_WIDTH{1'b0}};
                        if (preload_index == LAST_PRELOAD_INDEX) begin
                            state <= ST_RELEASE_DUT;
                        end else begin
                            preload_index <= preload_index + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                            state         <= ST_PRELOAD_REQ;
                        end
                    end else if (wait_counter >= PRELOAD_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_RELEASE_DUT: begin
                    dut_reset_n         <= 1'b1;
                    wait_counter        <= {COUNT_WIDTH{1'b0}};
                    group_pixel_index   <= {COUNT_WIDTH{1'b0}};
                    clk_pulse_count     <= {COUNT_WIDTH{1'b0}};
                    latch_count         <= {COUNT_WIDTH{1'b0}};
                    expected_panel_addr <= {ROW_ADDR_WIDTH{1'b0}};
                    expected_bcm        <= {ColorDepth{1'b0}};
                    oe_seen             <= 1'b0;
                    state               <= ST_RUN;
                end

                ST_RUN: begin
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

                        clk_pulse_count <= clk_pulse_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        if (group_pixel_index == LAST_GROUP_PIXEL)
                            group_pixel_index <= {COUNT_WIDTH{1'b0}};
                        else
                            group_pixel_index <= group_pixel_index + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end

                    if (panel_lat_rise) begin
                        if (panel_addr != expected_panel_addr)
                            fail_latched <= 1'b1;

                        latch_count       <= latch_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        group_pixel_index <= {COUNT_WIDTH{1'b0}};
                        if (expected_bcm == LAST_BCM_INDEX[ColorDepth-1:0]) begin
                            expected_bcm <= {ColorDepth{1'b0}};
                            if (expected_panel_addr == LAST_ROW_PAIR_INDEX[ROW_ADDR_WIDTH-1:0])
                                expected_panel_addr <= {ROW_ADDR_WIDTH{1'b0}};
                            else
                                expected_panel_addr <= expected_panel_addr + {{(ROW_ADDR_WIDTH-1){1'b0}}, 1'b1};
                        end else begin
                            expected_bcm <= expected_bcm + {{(ColorDepth-1){1'b0}}, 1'b1};
                        end
                    end

                    if (latch_count == TOTAL_GROUPS && clk_pulse_count == TOTAL_CLK_PULSES) begin
                        if (!oe_seen || fail_latched)
                            fail_latched <= 1'b1;
                        bist_done <= 1'b1;
                        state     <= ST_IDLE;
                    end else if (wait_counter >= RUN_WAIT_TIMEOUT) begin
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

    led_panel_driver #(
        .SysClkHz(SysClkHz),
        .RefreshRateHz(RefreshRateHz),
        .BrightnessWidth(BrightnessWidth),
        .TotalRowWidth(TotalRowWidth),
        .PanelHeight(PanelHeight),
        .ColorDepth(ColorDepth),
        .RowOffset(RowOffset),
        .TotalDisplayHeight(TotalDisplayHeight)
    ) dut (
        .clk_i(clk_i),
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
        .DataWidth(DATA_WIDTH)
    ) mem_arbiter_inst (
        .clk_i(clk_i),
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
        .DataWidth(DATA_WIDTH),
        .SdramAddrWidth(SDRAM_ADDR_WIDTH),
        .MaxBurstLen(8),
        .ScBl(8)
    ) sdram_adapter_inst (
        .clk_i(clk_i),
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
        .clk_50mhz_i(clk_i),
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
