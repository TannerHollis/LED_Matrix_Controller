// ============================================================================
// File Name   : led_panel_controller_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM-backed visual demo for the top-level led_panel_controller. A synthetic
//   SPI master writes rotating test patterns through spi_slave and
//   command_processor, flips the framebuffer, then holds each image for a few
//   seconds before advancing. No HUB75 self-check; use for bench visual verify.
//
// Parameters  :
//   SysClkHz             - Input clock frequency in Hz (Default: 50 MHz)
//   RefreshRateHz        - Display refresh target used by DUT timing
//   NumPanelRows         - Parallel HUB75 rows instantiated in DUT
//   NumPanelsPerRow      - Daisy-chained panels per row
//   PanelWidth           - Width of one physical panel in pixels
//   PanelHeight          - Height of one physical panel in pixels
//   ColorDepth           - Color bit depth per channel
//   SpiHalfPeriodCycles  - Synthetic SPI half-period in clk_50mhz cycles
//   CommandSettleCycles  - Inter-command wait for SDRAM write completion
//   PatternHoldSec       - Seconds to show each pattern before advancing
//   PatternCount         - Number of patterns in bist_frame_patterns
//
// Dependencies:
//   - led_panel_controller.sv
//   - bist_frame_patterns.sv
// ============================================================================
// Revision History:
//   Current - Rotating visual patterns only (no checker).
// ============================================================================

module led_panel_controller_bist_top #(
  parameter int unsigned SysClkHz            = 50_000_000,
  parameter int unsigned RefreshRateHz       = 120,
  parameter int unsigned NumPanelRows        = 1,
  parameter int unsigned NumPanelsPerRow     = 2,
  parameter int unsigned PanelWidth          = 64,
  parameter int unsigned PanelHeight         = 32,
  parameter int unsigned ColorDepth          = 4,
  parameter int unsigned CmdWidth            = 8,
  parameter int unsigned SpiHalfPeriodCycles = 4,
  parameter int unsigned CommandSettleCycles = 256,
  parameter int unsigned PatternHoldSec      = 3,
  parameter int unsigned PatternCount        = 6,
  parameter int unsigned Hub75HeaderRows     = 3,
  parameter int unsigned SdramRowWidth       = 13,
  parameter int unsigned SdramColWidth       = 9,
  parameter int unsigned SdramBankWidth      = 2
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
    output wire        sdram_we_n,
    output wire [Hub75HeaderRows-1:0]   hub75_r1,
    output wire [Hub75HeaderRows-1:0]   hub75_g1,
    output wire [Hub75HeaderRows-1:0]   hub75_b1,
    output wire [Hub75HeaderRows-1:0]   hub75_r2,
    output wire [Hub75HeaderRows-1:0]   hub75_g2,
    output wire [Hub75HeaderRows-1:0]   hub75_b2,
    output wire [5*Hub75HeaderRows-1:0] hub75_addr,
    output wire [Hub75HeaderRows-1:0]   hub75_clk,
    output wire [Hub75HeaderRows-1:0]   hub75_lat,
    output wire [Hub75HeaderRows-1:0]   hub75_oe
);

    localparam TOTAL_WIDTH = PanelWidth * NumPanelsPerRow;
    localparam TOTAL_HEIGHT = PanelHeight * NumPanelRows;
    localparam DATA_WIDTH = ColorDepth * 3;
    localparam FB_ADDR_WIDTH = (TOTAL_WIDTH * TOTAL_HEIGHT <= 1) ?
                               1 : $clog2(TOTAL_WIDTH * TOTAL_HEIGHT);
    localparam COUNT_WIDTH = 32;
    localparam BYTE_IDX_WIDTH = 4;
    localparam BIT_IDX_WIDTH = 4;
    localparam [BIT_IDX_WIDTH-1:0] LAST_SPI_BIT =
        (CmdWidth <= 1)  ? 4'd0  :
        (CmdWidth <= 2)  ? 4'd1  :
        (CmdWidth <= 3)  ? 4'd2  :
        (CmdWidth <= 4)  ? 4'd3  :
        (CmdWidth <= 5)  ? 4'd4  :
        (CmdWidth <= 6)  ? 4'd5  :
        (CmdWidth <= 7)  ? 4'd6  :
        (CmdWidth <= 8)  ? 4'd7  :
        (CmdWidth <= 9)  ? 4'd8  :
        (CmdWidth <= 10) ? 4'd9  :
        (CmdWidth <= 11) ? 4'd10 :
        (CmdWidth <= 12) ? 4'd11 :
        (CmdWidth <= 13) ? 4'd12 :
        (CmdWidth <= 14) ? 4'd13 :
        (CmdWidth <= 15) ? 4'd14 : 4'd15;
    localparam [COUNT_WIDTH-1:0] FRAME_WORDS = TOTAL_WIDTH * TOTAL_HEIGHT;
    localparam [COUNT_WIDTH-1:0] LAST_WRITE_INDEX = FRAME_WORDS - 1;
    localparam SDRAM_HOST_INIT_CYCLES = 24'd50_000;
    localparam [COUNT_WIDTH-1:0] PATTERN_HOLD_CYCLES =
        SysClkHz * PatternHoldSec;
    localparam int unsigned PatSelWidth =
        (PatternCount <= 1) ? 1 : $clog2(PatternCount);
    localparam [PatSelWidth-1:0] LastPatternIndex = PatternCount - 1;

    localparam [BYTE_IDX_WIDTH-1:0] ADDR_BYTES =
        (FB_ADDR_WIDTH <= 8)  ? 4'd1 :
        (FB_ADDR_WIDTH <= 16) ? 4'd2 :
        (FB_ADDR_WIDTH <= 24) ? 4'd3 : 4'd4;
    localparam [BYTE_IDX_WIDTH-1:0] DATA_BYTES =
        (DATA_WIDTH <= 8)  ? 4'd1 :
        (DATA_WIDTH <= 16) ? 4'd2 :
        (DATA_WIDTH <= 24) ? 4'd3 : 4'd4;
    localparam [BYTE_IDX_WIDTH-1:0] WRITE_CMD_LEN = 4'd1 + ADDR_BYTES + DATA_BYTES;
    localparam [BYTE_IDX_WIDTH-1:0] FLIP_CMD_LEN = 4'd1;

    localparam CMD_WRITE_PIXEL = 8'h01;
    localparam CMD_FLIP_BUFFER = 8'h02;

    localparam PH_WRITE = 1'b0;
    localparam PH_FLIP  = 1'b1;

    localparam ST_IDLE         = 4'd0;
    localparam ST_LOAD_WRITE   = 4'd1;
    localparam ST_LOAD_FLIP    = 4'd2;
    localparam ST_BEGIN_BYTE   = 4'd3;
    localparam ST_SETUP_BIT    = 4'd4;
    localparam ST_SCLK_HIGH    = 4'd5;
    localparam ST_SCLK_LOW     = 4'd6;
    localparam ST_FINISH_BYTE  = 4'd7;
    localparam ST_BYTE_GAP     = 4'd8;
    localparam ST_COMMAND_GAP  = 4'd9;
    localparam ST_PATTERN_HOLD = 4'd10;

    wire demo_running = (state != ST_IDLE);
    wire pattern_hold = (state == ST_PATTERN_HOLD);
    wire bist_done = pattern_hold;

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [3:0] state;
    reg [23:0] sdram_init_countdown;
    reg command_phase;
    reg [COUNT_WIDTH-1:0] write_index;
    reg [BYTE_IDX_WIDTH-1:0] byte_index;
    reg [BIT_IDX_WIDTH-1:0] bit_index;
    reg [COUNT_WIDTH-1:0] half_counter;
    reg [COUNT_WIDTH-1:0] gap_counter;
    reg [24:0] blink_counter;
    reg [PatSelWidth-1:0] pattern_id;
    reg [COUNT_WIDTH-1:0] hold_counter;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg spi_sclk;
    reg spi_cs_n;
    reg spi_mosi;
    wire spi_miso;

    wire [NumPanelRows-1:0] panel_r1;
    wire [NumPanelRows-1:0] panel_g1;
    wire [NumPanelRows-1:0] panel_b1;
    wire [NumPanelRows-1:0] panel_r2;
    wire [NumPanelRows-1:0] panel_g2;
    wire [NumPanelRows-1:0] panel_b2;
    wire [5*NumPanelRows-1:0] panel_addr;
    wire [NumPanelRows-1:0] panel_clk;
    wire [NumPanelRows-1:0] panel_lat;
    wire [NumPanelRows-1:0] panel_oe;

    localparam int unsigned Hub75PadMsb = Hub75HeaderRows - NumPanelRows;

    assign hub75_r1   = {{Hub75PadMsb{1'b0}}, panel_r1};
    assign hub75_g1   = {{Hub75PadMsb{1'b0}}, panel_g1};
    assign hub75_b1   = {{Hub75PadMsb{1'b0}}, panel_b1};
    assign hub75_r2   = {{Hub75PadMsb{1'b0}}, panel_r2};
    assign hub75_g2   = {{Hub75PadMsb{1'b0}}, panel_g2};
    assign hub75_b2   = {{Hub75PadMsb{1'b0}}, panel_b2};
    assign hub75_addr = {{(Hub75PadMsb * 5){1'b0}}, panel_addr};
    assign hub75_clk  = {{Hub75PadMsb{1'b0}}, panel_clk};
    assign hub75_lat  = {{Hub75PadMsb{1'b0}}, panel_lat};
    assign hub75_oe   = {{Hub75PadMsb{1'b0}}, panel_oe};

    wire [FB_ADDR_WIDTH-1:0] write_pattern_addr = write_index[FB_ADDR_WIDTH-1:0];
    wire [DATA_WIDTH-1:0] write_pattern_pixel;

    bist_frame_patterns #(
        .ColorDepth(ColorDepth),
        .TotalWidth(TOTAL_WIDTH),
        .TotalHeight(TOTAL_HEIGHT),
        .PatternCount(PatternCount)
    ) u_write_pattern (
        .pattern_sel_i(pattern_id),
        .addr_i(write_pattern_addr),
        .pixel_o(write_pattern_pixel)
    );

    wire [CmdWidth-1:0] current_spi_byte =
        command_byte(command_phase, write_index, byte_index, write_pattern_pixel);

    function [CmdWidth-1:0] command_byte;
        input command_phase_in;
        input [COUNT_WIDTH-1:0] addr_index;
        input [BYTE_IDX_WIDTH-1:0] byte_idx;
        input [DATA_WIDTH-1:0] data_value_in;
        reg [FB_ADDR_WIDTH-1:0] addr_value;
        reg [DATA_WIDTH-1:0] data_value;
        reg [FB_ADDR_WIDTH-1:0] shifted_addr;
        reg [DATA_WIDTH-1:0] shifted_data;
        begin
            addr_value = addr_index[FB_ADDR_WIDTH-1:0];
            data_value = data_value_in;
            shifted_addr = {FB_ADDR_WIDTH{1'b0}};
            shifted_data = {DATA_WIDTH{1'b0}};

            if (command_phase_in == PH_WRITE) begin
                if (byte_idx == {BYTE_IDX_WIDTH{1'b0}})
                    command_byte = CMD_WRITE_PIXEL;
                else if (byte_idx <= ADDR_BYTES) begin
                    shifted_addr = addr_value >> ((byte_idx - 1'b1) * 8);
                    command_byte = shifted_addr[CmdWidth-1:0];
                end else begin
                    shifted_data = data_value >> ((byte_idx - 1'b1 - ADDR_BYTES) * 8);
                    command_byte = shifted_data[CmdWidth-1:0];
                end
            end else begin
                command_byte = CMD_FLIP_BUFFER;
            end
        end
    endfunction

    function [BYTE_IDX_WIDTH-1:0] active_command_len;
        input command_phase_in;
        begin
            if (command_phase_in == PH_WRITE)
                active_command_len = WRITE_CMD_LEN;
            else
                active_command_len = FLIP_CMD_LEN;
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
            state                <= ST_IDLE;
            command_phase        <= PH_WRITE;
            write_index          <= {COUNT_WIDTH{1'b0}};
            byte_index           <= {BYTE_IDX_WIDTH{1'b0}};
            bit_index            <= {BIT_IDX_WIDTH{1'b0}};
            half_counter         <= {COUNT_WIDTH{1'b0}};
            gap_counter          <= {COUNT_WIDTH{1'b0}};
            blink_counter        <= 25'd0;
            pattern_id           <= {PatSelWidth{1'b0}};
            hold_counter         <= {COUNT_WIDTH{1'b0}};
            led_status           <= 1'b1;
            spi_sclk             <= 1'b0;
            spi_cs_n             <= 1'b1;
            spi_mosi             <= 1'b0;
            sdram_init_countdown <= SDRAM_HOST_INIT_CYCLES;
        end else begin
            blink_counter <= blink_counter + 25'd1;

            if (pattern_hold) led_status <= ~blink_counter[22];
            else if (demo_running) led_status <= ~blink_counter[21];
            else led_status <= 1'b1;

            case (state)
                ST_IDLE: begin
                    spi_sclk     <= 1'b0;
                    spi_cs_n     <= 1'b1;
                    spi_mosi     <= 1'b0;
                    if (sdram_init_countdown != 24'd0)
                        sdram_init_countdown <= sdram_init_countdown - 24'd1;
                    else if (start_event) begin
                        pattern_id   <= {PatSelWidth{1'b0}};
                        hold_counter <= {COUNT_WIDTH{1'b0}};
                        write_index  <= {COUNT_WIDTH{1'b0}};
                        state        <= ST_LOAD_WRITE;
                    end
                end

                ST_LOAD_WRITE: begin
                    command_phase <= PH_WRITE;
                    byte_index    <= {BYTE_IDX_WIDTH{1'b0}};
                    bit_index     <= LAST_SPI_BIT;
                    half_counter  <= {COUNT_WIDTH{1'b0}};
                    gap_counter   <= {COUNT_WIDTH{1'b0}};
                    state         <= ST_BEGIN_BYTE;
                end

                ST_LOAD_FLIP: begin
                    command_phase <= PH_FLIP;
                    byte_index    <= {BYTE_IDX_WIDTH{1'b0}};
                    bit_index     <= LAST_SPI_BIT;
                    half_counter  <= {COUNT_WIDTH{1'b0}};
                    gap_counter   <= {COUNT_WIDTH{1'b0}};
                    state         <= ST_BEGIN_BYTE;
                end

                ST_BEGIN_BYTE: begin
                    spi_cs_n     <= 1'b0;
                    spi_sclk     <= 1'b0;
                    bit_index    <= LAST_SPI_BIT;
                    half_counter <= {COUNT_WIDTH{1'b0}};
                    state        <= ST_SETUP_BIT;
                end

                ST_SETUP_BIT: begin
                    spi_sclk <= 1'b0;
                    spi_mosi <= current_spi_byte[bit_index];
                    if (half_counter == SpiHalfPeriodCycles - 1) begin
                        half_counter <= {COUNT_WIDTH{1'b0}};
                        state        <= ST_SCLK_HIGH;
                    end else begin
                        half_counter <= half_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_SCLK_HIGH: begin
                    spi_sclk <= 1'b1;
                    if (half_counter == SpiHalfPeriodCycles - 1) begin
                        half_counter <= {COUNT_WIDTH{1'b0}};
                        state        <= ST_SCLK_LOW;
                    end else begin
                        half_counter <= half_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_SCLK_LOW: begin
                    spi_sclk <= 1'b0;
                    if (bit_index == {BIT_IDX_WIDTH{1'b0}}) begin
                        state <= ST_FINISH_BYTE;
                    end else begin
                        bit_index <= bit_index - {{(BIT_IDX_WIDTH-1){1'b0}}, 1'b1};
                        state     <= ST_SETUP_BIT;
                    end
                end

                ST_FINISH_BYTE: begin
                    spi_sclk    <= 1'b0;
                    spi_cs_n    <= 1'b1;
                    gap_counter <= {COUNT_WIDTH{1'b0}};
                    state       <= ST_BYTE_GAP;
                end

                ST_BYTE_GAP: begin
                    if (gap_counter < 32'd16) begin
                        gap_counter <= gap_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end else if (byte_index == active_command_len(command_phase) - 1'b1) begin
                        gap_counter <= {COUNT_WIDTH{1'b0}};
                        state       <= ST_COMMAND_GAP;
                    end else begin
                        byte_index <= byte_index + {{(BYTE_IDX_WIDTH-1){1'b0}}, 1'b1};
                        state      <= ST_BEGIN_BYTE;
                    end
                end

                ST_COMMAND_GAP: begin
                    if (command_phase == PH_FLIP) begin
                        hold_counter <= {COUNT_WIDTH{1'b0}};
                        state        <= ST_PATTERN_HOLD;
                    end else if (gap_counter >= CommandSettleCycles[COUNT_WIDTH-1:0]) begin
                        gap_counter <= {COUNT_WIDTH{1'b0}};
                        if (write_index == LAST_WRITE_INDEX) begin
                            state <= ST_LOAD_FLIP;
                        end else begin
                            write_index <= write_index + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                            state       <= ST_LOAD_WRITE;
                        end
                    end else begin
                        gap_counter <= gap_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_PATTERN_HOLD: begin
                    if (hold_counter >= PATTERN_HOLD_CYCLES) begin
                        hold_counter <= {COUNT_WIDTH{1'b0}};
                        write_index  <= {COUNT_WIDTH{1'b0}};
                        if (pattern_id == LastPatternIndex)
                            pattern_id <= {PatSelWidth{1'b0}};
                        else
                            pattern_id <= pattern_id + {{(PatSelWidth-1){1'b0}}, 1'b1};
                        state <= ST_LOAD_WRITE;
                    end else begin
                        hold_counter <= hold_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    led_panel_controller #(
        .SysClkHz(SysClkHz),
        .RefreshRateHz(RefreshRateHz),
        .NumPanelRows(NumPanelRows),
        .NumPanelsPerRow(NumPanelsPerRow),
        .PanelWidth(PanelWidth),
        .PanelHeight(PanelHeight),
        .ColorDepth(ColorDepth),
        .CmdWidth(CmdWidth),
        .EnableEthernet(0),
        .SdramRowWidth(SdramRowWidth),
        .SdramColWidth(SdramColWidth),
        .SdramBankWidth(SdramBankWidth)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .spi_sclk_i(spi_sclk),
        .spi_cs_ni(spi_cs_n),
        .spi_mosi_i(spi_mosi),
        .spi_miso_o(spi_miso),
        .eth_rx_data_i(1'b0),
        .eth_rx_dv_i(1'b0),
        .eth_rx_er_i(1'b0),
        .eth_tx_data_o(),
        .eth_tx_en_o(),
        .eth_tx_er_i(1'b0),
        .eth_crs_i(1'b0),
        .eth_col_i(1'b0),
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
