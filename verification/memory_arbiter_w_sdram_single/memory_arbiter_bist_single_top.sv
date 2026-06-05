// ============================================================================
// File Name   : memory_arbiter_bist_single_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Single-client hardware BIST exercising the full production memory stack
//   (memory_arbiter, sdram_arbiter_adapter, sdram_controller). One button press
//   write/read-verifies 0..LastTestAddr against external SDRAM.
//
// Parameters  :
//   AddrWidth       - Width of the memory address bus (Default: 24)
//   DataWidth       - Width of the client data bus (Default: 12)
//   LastTestAddr   - Last address in the write/read sweep (Default: 24'h00FF_FFFF)
//   SdramRowWidth  - SDRAM row address width (Default: 13)
//   SdramColWidth  - SDRAM column address width (Default: 9)
//   SdramBankWidth - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - Single-client SDRAM write/read sweep with burst-8 verify reads.
// ============================================================================

module memory_arbiter_bist_single_top #(
  parameter int unsigned AddrWidth      = 24,
  parameter int unsigned DataWidth      = 12,
  parameter logic [23:0] LastTestAddr   = 24'h00FF_FFFF,
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

    localparam S_IDLE       = 3'd0;
    localparam S_WR_REQ     = 3'd1;
    localparam S_WR_WAIT    = 3'd2;
    localparam S_RD_REQ     = 3'd3;
    localparam S_RD_WAIT    = 3'd4;
    localparam S_RD_DV_WAIT = 3'd5;

    // Must exceed sdram_arbiter_adapter WR_TURNAROUND_WAIT (default 64) for first-write grant.
    localparam OP_WAIT_TIMEOUT = 24'd10_000_000;
    // Host-side guard for sdram_controller INIT_PER (24000 SDRAM clocks @ 100 MHz).
    localparam SDRAM_HOST_INIT_CYCLES = 24'd50_000;
    localparam READ_BURST_LEN  = 8;
    localparam RD_BEAT_BITS    = 3;

    localparam [AddrWidth-1:0] LAST_ADDR = LastTestAddr[AddrWidth-1:0];
    wire [AddrWidth-1:0] burst_last_addr = curr_addr + READ_BURST_LEN - 1;
    wire at_last_burst = (burst_last_addr >= LAST_ADDR);

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [2:0] state;
    reg [AddrWidth-1:0] curr_addr;
    reg [23:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;
    reg [23:0] sdram_init_countdown;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg client_mem_req;
    reg client_mem_write;
    reg [AddrWidth-1:0] client_mem_addr;
    reg [DataWidth-1:0] client_mem_write_data;
    wire client_mem_grant;
    wire [DataWidth-1:0] client_mem_read_data;
    wire client_mem_read_data_valid;

    wire master_mem_req;
    wire master_mem_write;
    wire [AddrWidth-1:0] master_mem_addr;
    wire [DataWidth-1:0] master_mem_write_data;
    wire master_mem_ready;
    wire [3:0] master_mem_read_length;
    wire [3:0] master_mem_write_length;
    wire [DataWidth-1:0] master_mem_read_data;
    wire master_mem_read_data_valid;

    reg  [3:0] client_mem_read_length;
    wire [3:0] client_mem_write_length = 4'd1;
    reg  [RD_BEAT_BITS-1:0] rd_beat_idx;

    localparam SDRAM_ADDR_WIDTH = SdramBankWidth + SdramRowWidth + SdramColWidth;

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

    function [DataWidth-1:0] mem_pattern;
        input [AddrWidth-1:0] addr_in;
        reg [15:0] full_pat;
        begin
            full_pat    = addr_in[15:0] ^ 16'hA5C3;
            mem_pattern = full_pat[DataWidth-1:0];
        end
    endfunction

    initial begin
        if (((LAST_ADDR + 1) % READ_BURST_LEN) != 0) begin
            $display("ERROR: memory_arbiter_bist_single_top LastTestAddr+1 must be multiple of %0d",
                     READ_BURST_LEN);
            $finish;
        end
    end

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
            state                 <= S_IDLE;
            curr_addr             <= {AddrWidth{1'b0}};
            wait_counter          <= 24'd0;
            blink_counter         <= 25'd0;
            bist_done             <= 1'b0;
            fail_latched          <= 1'b0;
            sdram_init_countdown  <= SDRAM_HOST_INIT_CYCLES;
            led_status            <= 1'b1;
            client_mem_req        <= 1'b0;
            client_mem_write      <= 1'b0;
            client_mem_addr       <= {AddrWidth{1'b0}};
            client_mem_write_data <= {DataWidth{1'b0}};
            client_mem_read_length <= 4'd1;
            rd_beat_idx           <= {RD_BEAT_BITS{1'b0}};
        end else begin
            blink_counter <= blink_counter + 25'd1;

            if (fail_latched) begin
                led_status <= ~blink_counter[24];
            end else if (state != S_IDLE) begin
                led_status <= ~blink_counter[21];
            end else if (bist_done) begin
                led_status <= 1'b0;
            end else begin
                led_status <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    client_mem_req <= 1'b0;
                    wait_counter   <= 24'd0;
                    if (sdram_init_countdown != 24'd0)
                        sdram_init_countdown <= sdram_init_countdown - 24'd1;
                    else if (start_event) begin
                        curr_addr    <= {AddrWidth{1'b0}};
                        bist_done    <= 1'b0;
                        fail_latched <= 1'b0;
                        state        <= S_WR_REQ;
                    end
                end

                S_WR_REQ: begin
                    client_mem_req        <= 1'b1;
                    client_mem_read_length <= 4'd1;
                    client_mem_write      <= 1'b1;
                    client_mem_addr       <= curr_addr;
                    client_mem_write_data <= mem_pattern(curr_addr);
                    wait_counter          <= 24'd0;
                    state                 <= S_WR_WAIT;
                end

                S_WR_WAIT: begin
                    if (client_mem_grant) begin
                        client_mem_req <= 1'b0;
                        if (curr_addr == LAST_ADDR) begin
                            curr_addr <= {AddrWidth{1'b0}};
                            state     <= S_RD_REQ;
                        end else begin
                            curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                            state     <= S_WR_REQ;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_RD_REQ: begin
                    client_mem_req         <= 1'b1;
                    client_mem_write       <= 1'b0;
                    client_mem_read_length <= READ_BURST_LEN[3:0];
                    client_mem_addr        <= curr_addr;
                    wait_counter           <= 24'd0;
                    state                  <= S_RD_WAIT;
                end

                S_RD_WAIT: begin
                    if (client_mem_grant) begin
                        client_mem_req <= 1'b0;
                        rd_beat_idx    <= {RD_BEAT_BITS{1'b0}};
                        wait_counter   <= 24'd0;
                        state          <= S_RD_DV_WAIT;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_RD_DV_WAIT: begin
                    if (client_mem_read_data_valid) begin
                        if (client_mem_read_data != mem_pattern(
                                curr_addr + {{(AddrWidth-RD_BEAT_BITS){1'b0}}, rd_beat_idx}))
                            fail_latched <= 1'b1;
                        if (rd_beat_idx == (READ_BURST_LEN - 1)) begin
                            if (at_last_burst) begin
                                bist_done <= 1'b1;
                                state     <= S_IDLE;
                            end else begin
                                curr_addr   <= curr_addr + READ_BURST_LEN;
                                rd_beat_idx <= {RD_BEAT_BITS{1'b0}};
                                state       <= S_RD_REQ;
                            end
                        end else begin
                            rd_beat_idx <= rd_beat_idx + 1'b1;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    memory_arbiter #(
        .NumClients(1),
        .NumLowPriClients(1),
        .AddrWidth(AddrWidth),
        .DataWidth(DataWidth)
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
        .DataWidth(DataWidth),
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
        .write_addr_i({1'b0, sdram_write_addr}),
        .write_length_i(sdram_write_length),
        .write_load_i(sdram_write_load),
        .write_full_o(sdram_write_full),
        .write_used_o(sdram_write_used),
        .read_data_o(sdram_read_data),
        .read_request_i(sdram_read_request),
        .read_addr_i({1'b0, sdram_read_addr}),
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
