// ============================================================================
// File Name   : command_processor_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM-backed hardware BIST top for command_processor. A scripted command
//   source drives write/read/flip command bytes into command_processor, then the
//   BIST checks memory requests, SDRAM-backed read responses, and frame_ready.
//
// Parameters  :
//   TotalWidth      - Display/framebuffer width in pixels (Default: 1024)
//   TotalHeight     - Display/framebuffer height in pixels (Default: 32)
//   ColorDepth      - Color bit depth per channel (Default: 4)
//   CmdWidth        - Command byte width (Default: 8)
//   AddrWidth       - Arbiter/SDRAM client address width (Default: 24)
//   SdramRowWidth  - SDRAM row address width (Default: 13)
//   SdramColWidth  - SDRAM column address width (Default: 9)
//   SdramBankWidth - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - command_processor.sv
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - Scripted write/read/flip commands through SDRAM stack.
// ============================================================================

module command_processor_bist_top #(
  parameter int unsigned TotalWidth     = 1024,
  parameter int unsigned TotalHeight    = 32,
  parameter int unsigned ColorDepth     = 4,
  parameter int unsigned CmdWidth       = 8,
  parameter int unsigned AddrWidth      = 24,
  parameter int unsigned SdramRowWidth  = 13,
  parameter int unsigned SdramColWidth  = 9,
  parameter int unsigned SdramBankWidth = 2
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
    localparam CP_ADDR_WIDTH = (TotalWidth * TotalHeight <= 1) ?
                               1 : $clog2(TotalWidth * TotalHeight);
    localparam SDRAM_ADDR_WIDTH = SdramBankWidth + SdramRowWidth + SdramColWidth;
    localparam SCRIPT_COUNT = 4;
    localparam SCRIPT_IDX_WIDTH = 3;
    localparam BYTE_IDX_WIDTH = 4;
    localparam COUNT_WIDTH = 32;
    localparam [BYTE_IDX_WIDTH-1:0] ADDR_BYTES =
        (CP_ADDR_WIDTH <= 8)  ? 4'd1 :
        (CP_ADDR_WIDTH <= 16) ? 4'd2 :
        (CP_ADDR_WIDTH <= 24) ? 4'd3 : 4'd4;
    localparam [BYTE_IDX_WIDTH-1:0] DATA_BYTES =
        (DATA_WIDTH <= 8)  ? 4'd1 :
        (DATA_WIDTH <= 16) ? 4'd2 :
        (DATA_WIDTH <= 24) ? 4'd3 : 4'd4;
    localparam [BYTE_IDX_WIDTH-1:0] WRITE_PHASE_LEN = 4'd1 + ADDR_BYTES + DATA_BYTES;
    localparam [BYTE_IDX_WIDTH-1:0] READ_PHASE_LEN  = 4'd1 + ADDR_BYTES;
    localparam [BYTE_IDX_WIDTH-1:0] FLIP_PHASE_LEN  = 4'd1;

    localparam CMD_WRITE_PIXEL = 8'h01;
    localparam CMD_FLIP_BUFFER = 8'h02;
    localparam CMD_READ_PIXEL  = 8'h03;

    localparam PH_WRITE = 2'd0;
    localparam PH_READ  = 2'd1;
    localparam PH_FLIP  = 2'd2;

    localparam ST_IDLE        = 4'd0;
    localparam ST_SEND_BYTE   = 4'd1;
    localparam ST_BYTE_GAP    = 4'd2;
    localparam ST_WAIT_WRITE  = 4'd3;
    localparam ST_WAIT_READ   = 4'd4;
    localparam ST_WAIT_FLIP   = 4'd5;

    localparam [COUNT_WIDTH-1:0] OP_WAIT_TIMEOUT = 32'd10_000_000;
    localparam SDRAM_HOST_INIT_CYCLES = 24'd50_000;

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [3:0] state;
    reg [23:0] sdram_init_countdown;
    reg [1:0] command_phase;
    reg [SCRIPT_IDX_WIDTH-1:0] script_index;
    reg [BYTE_IDX_WIDTH-1:0] byte_index;
    reg [COUNT_WIDTH-1:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;
    reg frame_ready_seen;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg [CmdWidth-1:0] spi_data_in;
    reg spi_data_valid;
    wire frame_ready;

    wire cp_mem_req;
    wire cp_mem_write;
    wire [3:0] cp_mem_read_length;
    wire [3:0] cp_mem_write_length;
    wire [CP_ADDR_WIDTH-1:0] cp_mem_addr;
    wire [DATA_WIDTH-1:0] cp_mem_write_data;
    wire cp_mem_grant;
    wire [DATA_WIDTH-1:0] cp_mem_read_data;
    wire cp_mem_read_data_valid;
    wire [DATA_WIDTH-1:0] read_data_out;
    wire read_data_valid;

    wire [1:0] client_mem_req = {cp_mem_req, 1'b0};
    wire [1:0] client_mem_write = {cp_mem_write, 1'b0};
    wire [AddrWidth*2-1:0] client_mem_addr =
        {{(AddrWidth-CP_ADDR_WIDTH){1'b0}}, cp_mem_addr, {AddrWidth{1'b0}}};
    wire [DATA_WIDTH*2-1:0] client_mem_write_data =
        {cp_mem_write_data, {DATA_WIDTH{1'b0}}};
    wire [7:0] client_mem_read_length  = {cp_mem_read_length, 4'd1};
    wire [7:0] client_mem_write_length = {cp_mem_write_length, 4'd1};
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

    assign cp_mem_grant = client_mem_grant[1];
    assign cp_mem_read_data = client_mem_read_data[2*DATA_WIDTH-1:DATA_WIDTH];
    assign cp_mem_read_data_valid = client_mem_read_data_valid[1];

    function [CP_ADDR_WIDTH-1:0] script_addr;
        input [SCRIPT_IDX_WIDTH-1:0] idx;
        begin
            case (idx)
                3'd0: script_addr = 15'h0000;
                3'd1: script_addr = 15'h0015;
                3'd2: script_addr = 15'h0123;
                3'd3: script_addr = 15'h1FFE;
                default: script_addr = {CP_ADDR_WIDTH{1'b0}};
            endcase
        end
    endfunction

    function [DATA_WIDTH-1:0] script_data;
        input [SCRIPT_IDX_WIDTH-1:0] idx;
        begin
            case (idx)
                3'd0: script_data = 12'hA5C;
                3'd1: script_data = 12'h5A3;
                3'd2: script_data = 12'hC3F;
                3'd3: script_data = 12'h03C;
                default: script_data = {DATA_WIDTH{1'b0}};
            endcase
        end
    endfunction

    function [BYTE_IDX_WIDTH-1:0] phase_len;
        input [1:0] phase;
        begin
            case (phase)
                PH_WRITE: phase_len = WRITE_PHASE_LEN;
                PH_READ:  phase_len = READ_PHASE_LEN;
                PH_FLIP:  phase_len = FLIP_PHASE_LEN;
                default:  phase_len = FLIP_PHASE_LEN;
            endcase
        end
    endfunction

    function [CmdWidth-1:0] command_byte;
        input [1:0] phase;
        input [SCRIPT_IDX_WIDTH-1:0] idx;
        input [BYTE_IDX_WIDTH-1:0] byte_idx;
        reg [CP_ADDR_WIDTH-1:0] shifted_addr;
        reg [DATA_WIDTH-1:0] shifted_data;
        begin
            shifted_addr = {CP_ADDR_WIDTH{1'b0}};
            shifted_data = {DATA_WIDTH{1'b0}};
            if (phase == PH_WRITE) begin
                if (byte_idx == 0)
                    command_byte = CMD_WRITE_PIXEL;
                else if (byte_idx <= ADDR_BYTES) begin
                    shifted_addr = script_addr(idx) >> ((byte_idx - 1) * 8);
                    command_byte = shifted_addr[CmdWidth-1:0];
                end else begin
                    shifted_data = script_data(idx) >> ((byte_idx - 1 - ADDR_BYTES) * 8);
                    command_byte = shifted_data[CmdWidth-1:0];
                end
            end else if (phase == PH_READ) begin
                if (byte_idx == 0)
                    command_byte = CMD_READ_PIXEL;
                else begin
                    shifted_addr = script_addr(idx) >> ((byte_idx - 1) * 8);
                    command_byte = shifted_addr[CmdWidth-1:0];
                end
            end else begin
                command_byte = CMD_FLIP_BUFFER;
            end
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
            state          <= ST_IDLE;
            command_phase  <= PH_WRITE;
            script_index   <= {SCRIPT_IDX_WIDTH{1'b0}};
            byte_index     <= {BYTE_IDX_WIDTH{1'b0}};
            wait_counter   <= {COUNT_WIDTH{1'b0}};
            blink_counter  <= 25'd0;
            bist_done      <= 1'b0;
            fail_latched   <= 1'b0;
            frame_ready_seen <= 1'b0;
            sdram_init_countdown <= SDRAM_HOST_INIT_CYCLES;
            led_status     <= 1'b1;
            spi_data_in    <= {CmdWidth{1'b0}};
            spi_data_valid <= 1'b0;
        end else begin
            blink_counter  <= blink_counter + 25'd1;
            spi_data_valid <= 1'b0;
            if (frame_ready)
                frame_ready_seen <= 1'b1;

            if (fail_latched)          led_status <= ~blink_counter[24];
            else if (state != ST_IDLE) led_status <= ~blink_counter[21];
            else if (bist_done)        led_status <= 1'b0;
            else                       led_status <= 1'b1;

            case (state)
                ST_IDLE: begin
                    wait_counter <= {COUNT_WIDTH{1'b0}};
                    if (sdram_init_countdown != 24'd0)
                        sdram_init_countdown <= sdram_init_countdown - 24'd1;
                    else if (start_event) begin
                        bist_done     <= 1'b0;
                        fail_latched  <= 1'b0;
                        frame_ready_seen <= 1'b0;
                        command_phase <= PH_WRITE;
                        script_index  <= {SCRIPT_IDX_WIDTH{1'b0}};
                        byte_index    <= {BYTE_IDX_WIDTH{1'b0}};
                        state         <= ST_SEND_BYTE;
                    end
                end

                ST_SEND_BYTE: begin
                    spi_data_in    <= command_byte(command_phase, script_index, byte_index);
                    spi_data_valid <= 1'b1;
                    wait_counter   <= {COUNT_WIDTH{1'b0}};
                    state          <= ST_BYTE_GAP;
                end

                ST_BYTE_GAP: begin
                    if (byte_index == phase_len(command_phase) - 1) begin
                        byte_index   <= {BYTE_IDX_WIDTH{1'b0}};
                        wait_counter <= {COUNT_WIDTH{1'b0}};
                        if (command_phase == PH_WRITE)
                            state <= ST_WAIT_WRITE;
                        else if (command_phase == PH_READ)
                            state <= ST_WAIT_READ;
                        else begin
                            frame_ready_seen <= frame_ready_seen | frame_ready;
                            state <= ST_WAIT_FLIP;
                        end
                    end else begin
                        byte_index <= byte_index + {{(BYTE_IDX_WIDTH-1){1'b0}}, 1'b1};
                        state      <= ST_SEND_BYTE;
                    end
                end

                ST_WAIT_WRITE: begin
                    if (cp_mem_req && cp_mem_write) begin
                        if (cp_mem_addr != script_addr(script_index) ||
                            cp_mem_write_data != script_data(script_index)) begin
                            fail_latched <= 1'b1;
                        end
                    end

                    if (cp_mem_req && cp_mem_write && cp_mem_grant) begin
                        command_phase <= PH_READ;
                        byte_index    <= {BYTE_IDX_WIDTH{1'b0}};
                        wait_counter  <= {COUNT_WIDTH{1'b0}};
                        state         <= ST_SEND_BYTE;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_WAIT_READ: begin
                    if (read_data_valid) begin
                        if (read_data_out != script_data(script_index))
                            fail_latched <= 1'b1;
                        wait_counter <= {COUNT_WIDTH{1'b0}};
                        if (script_index == SCRIPT_COUNT - 1) begin
                            command_phase <= PH_FLIP;
                            script_index  <= {SCRIPT_IDX_WIDTH{1'b0}};
                        end else begin
                            command_phase <= PH_WRITE;
                            script_index  <= script_index + {{(SCRIPT_IDX_WIDTH-1){1'b0}}, 1'b1};
                        end
                        byte_index <= {BYTE_IDX_WIDTH{1'b0}};
                        state      <= ST_SEND_BYTE;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                ST_WAIT_FLIP: begin
                    if (frame_ready_seen) begin
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

    command_processor #(
        .TotalWidth(TotalWidth),
        .TotalHeight(TotalHeight),
        .ColorDepth(ColorDepth),
        .CmdWidth(CmdWidth)
    ) command_processor_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .spi_data_in_i(spi_data_in),
        .spi_data_valid_i(spi_data_valid),
        .frame_ready_o(frame_ready),
        .mem_req_o(cp_mem_req),
        .mem_write_o(cp_mem_write),
        .mem_read_length_o(cp_mem_read_length),
        .mem_write_length_o(cp_mem_write_length),
        .mem_addr_o(cp_mem_addr),
        .mem_write_data_o(cp_mem_write_data),
        .mem_grant_i(cp_mem_grant),
        .mem_read_data_i(cp_mem_read_data),
        .mem_read_data_valid_i(cp_mem_read_data_valid),
        .read_data_out_o(read_data_out),
        .read_data_valid_o(read_data_valid)
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
