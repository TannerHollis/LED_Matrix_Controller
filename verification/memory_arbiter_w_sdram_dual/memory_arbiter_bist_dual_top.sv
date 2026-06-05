// ============================================================================
// File Name   : memory_arbiter_bist_dual_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for two-client memory_arbiter contention through
//   sdram_arbiter_adapter and sdram_controller. Runs per-client sweeps plus
//   simultaneous priority contention rounds against external SDRAM.
//
// Parameters  :
//   AddrWidth        - Width of the memory address bus (Default: 24)
//   DataWidth        - Width of the client data bus (Default: 12)
//   LastTestAddr    - Client 0 sweep end address (Default: 24'h00FF_FFFF)
//   ProbeBase        - Client 1 probe region base address (Default: 24'h01_0000)
//   ProbeLen         - Client 1 probe region length in words (Default: 16711680)
//   ContentionRounds - Number of priority contention rounds (Default: 16)
//   SdramRowWidth   - SDRAM row address width (Default: 13)
//   SdramColWidth   - SDRAM column address width (Default: 9)
//   SdramBankWidth  - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - Dual-client SDRAM sweeps and priority contention tests.
// ============================================================================

module memory_arbiter_bist_dual_top #(
  parameter int unsigned AddrWidth        = 24,
  parameter int unsigned DataWidth        = 12,
  parameter logic [23:0] LastTestAddr     = 24'h00FF_FFFF,
  parameter logic [23:0] ProbeBase        = 24'h01_0000,
  parameter int unsigned ProbeLen         = 16711680,
  parameter int unsigned ContentionRounds = 16,
  parameter int unsigned SdramRowWidth    = 13,
  parameter int unsigned SdramColWidth    = 9,
  parameter int unsigned SdramBankWidth   = 2
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

    localparam PHASE_A = 3'd0;
    localparam PHASE_B = 3'd1;
    localparam PHASE_C = 3'd2;
    localparam PHASE_V = 3'd3;

    localparam ST_IDLE     = 4'd0;
    localparam ST_WR_REQ   = 4'd1;
    localparam ST_WR_WAIT  = 4'd2;
    localparam ST_RD_REQ   = 4'd3;
    localparam ST_RD_WAIT  = 4'd4;
    localparam ST_RD_DV    = 4'd10;
    localparam ST_C_BOTH   = 4'd5;
    localparam ST_C_HI_W   = 4'd6;
    localparam ST_C_LO_W   = 4'd7;
    localparam ST_C_RD_REQ = 4'd8;
    localparam ST_C_RD_W   = 4'd9;
    localparam ST_C_RD_DV  = 4'd11;

    localparam OP_WAIT_TIMEOUT = 24'd10_000_000;

    localparam [AddrWidth-1:0] LAST_ADDR  = LastTestAddr[AddrWidth-1:0];
    localparam [AddrWidth-1:0] PROBE_LAST = ProbeBase[AddrWidth-1:0] + ProbeLen[AddrWidth-1:0] - {{(AddrWidth-1){1'b0}}, 1'b1};
    localparam ROUND_IDX_WIDTH = (ContentionRounds <= 1) ? 1 : $clog2(ContentionRounds);

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [2:0] test_phase;
    reg [3:0] state;
    reg [AddrWidth-1:0] curr_addr;
    reg [ROUND_IDX_WIDTH-1:0] round_idx;
    reg [ROUND_IDX_WIDTH-1:0] verify_idx;
    reg [23:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;
    reg verify_is_high;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg [1:0] client_mem_req;
    reg [1:0] client_mem_write;
    reg [AddrWidth-1:0] client0_mem_addr;
    reg [AddrWidth-1:0] client1_mem_addr;
    reg [DataWidth-1:0] client0_mem_write_data;
    reg [DataWidth-1:0] client1_mem_write_data;
    wire [1:0] client_mem_grant;
    wire [DataWidth-1:0] client0_mem_read_data;
    wire [DataWidth-1:0] client1_mem_read_data;
    wire [1:0] client_mem_read_data_valid;

    wire [AddrWidth*2-1:0] client_mem_addr;
    wire [DataWidth*2-1:0] client_mem_write_data;
    wire [DataWidth*2-1:0] client_mem_read_data;

    wire master_mem_req;
    wire master_mem_write;
    wire [AddrWidth-1:0] master_mem_addr;
    wire [DataWidth-1:0] master_mem_write_data;
    wire master_mem_ready;
    wire [3:0] master_mem_read_length;
    wire [3:0] master_mem_write_length;
    wire [DataWidth-1:0] master_mem_read_data;
    wire master_mem_read_data_valid;

    wire [7:0] client_mem_read_length  = 8'h11;
    wire [7:0] client_mem_write_length = 8'h11;

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

    assign client_mem_addr = {client1_mem_addr, client0_mem_addr};
    assign client_mem_write_data = {client1_mem_write_data, client0_mem_write_data};
    assign client0_mem_read_data = client_mem_read_data[DataWidth-1:0];
    assign client1_mem_read_data = client_mem_read_data[2*DataWidth-1:DataWidth];

    wire [AddrWidth-1:0] round_idx_addr =
        {{(AddrWidth-ROUND_IDX_WIDTH){1'b0}}, round_idx};
    wire [AddrWidth-1:0] verify_idx_addr =
        {{(AddrWidth-ROUND_IDX_WIDTH){1'b0}}, verify_idx};

    function [DataWidth-1:0] mem_pattern;
        input [AddrWidth-1:0] addr_in;
        reg [15:0] full_pat;
        begin
            full_pat    = addr_in[15:0] ^ 16'hA5C3;
            mem_pattern = full_pat[DataWidth-1:0];
        end
    endfunction

    function [DataWidth-1:0] hi_mem_pattern;
        input [AddrWidth-1:0] addr_in;
        begin
            hi_mem_pattern = mem_pattern(addr_in ^ {{(AddrWidth-16){1'b0}}, 16'hA5C3});
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
            test_phase            <= PHASE_A;
            state                 <= ST_IDLE;
            curr_addr             <= {AddrWidth{1'b0}};
            round_idx             <= {ROUND_IDX_WIDTH{1'b0}};
            verify_idx            <= {ROUND_IDX_WIDTH{1'b0}};
            wait_counter          <= 24'd0;
            blink_counter         <= 25'd0;
            bist_done             <= 1'b0;
            fail_latched          <= 1'b0;
            led_status            <= 1'b1;
            client_mem_req        <= 2'b00;
            client_mem_write      <= 2'b00;
            client0_mem_addr      <= {AddrWidth{1'b0}};
            client1_mem_addr      <= {AddrWidth{1'b0}};
            client0_mem_write_data <= {DataWidth{1'b0}};
            client1_mem_write_data <= {DataWidth{1'b0}};
            verify_is_high        <= 1'b0;
        end else begin
            blink_counter <= blink_counter + 25'd1;

            if (fail_latched) begin
                led_status <= ~blink_counter[24];
            end else if (state != ST_IDLE) begin
                led_status <= ~blink_counter[21];
            end else if (bist_done) begin
                led_status <= 1'b0;
            end else begin
                led_status <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    client_mem_req <= 2'b00;
                    wait_counter   <= 24'd0;
                    if (start_event) begin
                        test_phase    <= PHASE_A;
                        curr_addr     <= {AddrWidth{1'b0}};
                        round_idx     <= {ROUND_IDX_WIDTH{1'b0}};
                        verify_idx    <= {ROUND_IDX_WIDTH{1'b0}};
                        bist_done     <= 1'b0;
                        fail_latched  <= 1'b0;
                        verify_is_high <= 1'b0;
                        state         <= ST_WR_REQ;
                    end
                end

                ST_WR_REQ: begin
                    if (test_phase == PHASE_C) begin
                        state <= ST_C_BOTH;
                    end else begin
                        if (test_phase == PHASE_A) begin
                            client_mem_req[0]        <= 1'b1;
                            client_mem_write[0]      <= 1'b1;
                            client0_mem_addr         <= curr_addr;
                            client0_mem_write_data   <= mem_pattern(curr_addr);
                        end else begin
                            client_mem_req[1]        <= 1'b1;
                            client_mem_write[1]      <= 1'b1;
                            client1_mem_addr         <= curr_addr;
                            client1_mem_write_data   <= hi_mem_pattern(curr_addr);
                        end
                        wait_counter <= 24'd0;
                        state        <= ST_WR_WAIT;
                    end
                end

                ST_WR_WAIT: begin
                    if ((test_phase == PHASE_A && client_mem_grant[0]) ||
                        (test_phase == PHASE_B && client_mem_grant[1])) begin
                        client_mem_req <= 2'b00;
                        if (test_phase == PHASE_A) begin
                            if (curr_addr == LAST_ADDR) begin
                                curr_addr    <= {AddrWidth{1'b0}};
                                wait_counter <= 24'd0;
                                state        <= ST_RD_REQ;
                            end else begin
                                curr_addr  <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                                state      <= ST_WR_REQ;
                            end
                        end else begin
                            if (curr_addr == PROBE_LAST) begin
                                curr_addr    <= ProbeBase[AddrWidth-1:0];
                                wait_counter <= 24'd0;
                                state        <= ST_RD_REQ;
                            end else begin
                                curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                                state     <= ST_WR_REQ;
                            end
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_RD_REQ: begin
                    if (test_phase == PHASE_A) begin
                        client_mem_req[0]   <= 1'b1;
                        client_mem_write[0] <= 1'b0;
                        client0_mem_addr    <= curr_addr;
                    end else begin
                        client_mem_req[1]   <= 1'b1;
                        client_mem_write[1] <= 1'b0;
                        client1_mem_addr    <= curr_addr;
                    end
                    wait_counter <= 24'd0;
                    state        <= ST_RD_WAIT;
                end

                ST_RD_WAIT: begin
                    if ((test_phase == PHASE_A && client_mem_grant[0]) ||
                        (test_phase == PHASE_B && client_mem_grant[1])) begin
                        client_mem_req <= 2'b00;
                        wait_counter   <= 24'd0;
                        state          <= ST_RD_DV;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_RD_DV: begin
                    if ((test_phase == PHASE_A && client_mem_read_data_valid[0]) ||
                        (test_phase == PHASE_B && client_mem_read_data_valid[1])) begin
                        if (test_phase == PHASE_A) begin
                            if (client0_mem_read_data != mem_pattern(curr_addr))
                                fail_latched <= 1'b1;
                            if (curr_addr == LAST_ADDR) begin
                                curr_addr  <= ProbeBase[AddrWidth-1:0];
                                test_phase <= PHASE_B;
                                state      <= ST_WR_REQ;
                            end else begin
                                curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                                state     <= ST_RD_REQ;
                            end
                        end else begin
                            if (client1_mem_read_data != hi_mem_pattern(curr_addr))
                                fail_latched <= 1'b1;
                            if (curr_addr == PROBE_LAST) begin
                                test_phase <= PHASE_C;
                                round_idx  <= {ROUND_IDX_WIDTH{1'b0}};
                                state      <= ST_WR_REQ;
                            end else begin
                                curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                                state     <= ST_RD_REQ;
                            end
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_C_BOTH: begin
                    client_mem_req[0]        <= 1'b1;
                    client_mem_req[1]        <= 1'b1;
                    client_mem_write         <= 2'b11;
                    client0_mem_addr         <= round_idx_addr;
                    client0_mem_write_data   <= mem_pattern(round_idx_addr);
                    client1_mem_addr         <= ProbeBase[AddrWidth-1:0] + round_idx_addr;
                    client1_mem_write_data   <= hi_mem_pattern(ProbeBase[AddrWidth-1:0] + round_idx_addr);
                    wait_counter             <= 24'd0;
                    state                    <= ST_C_HI_W;
                end

                ST_C_HI_W: begin
                    if (client_mem_grant[1]) begin
                        client_mem_req[1] <= 1'b0;
                        state             <= ST_C_LO_W;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_C_LO_W: begin
                    if (client_mem_grant[0]) begin
                        client_mem_req <= 2'b00;
                        if (round_idx == ContentionRounds - 1) begin
                            test_phase     <= PHASE_V;
                            verify_idx     <= {ROUND_IDX_WIDTH{1'b0}};
                            verify_is_high <= 1'b0;
                            wait_counter   <= 24'd0;
                            state          <= ST_C_RD_REQ;
                        end else begin
                            round_idx <= round_idx + {{(ROUND_IDX_WIDTH-1){1'b0}}, 1'b1};
                            state     <= ST_C_BOTH;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_C_RD_REQ: begin
                    if (verify_is_high) begin
                        client_mem_req[1]   <= 1'b1;
                        client_mem_write[1] <= 1'b0;
                        client1_mem_addr    <= ProbeBase[AddrWidth-1:0] + verify_idx_addr;
                    end else begin
                        client_mem_req[0]   <= 1'b1;
                        client_mem_write[0] <= 1'b0;
                        client0_mem_addr    <= verify_idx_addr;
                    end
                    wait_counter <= 24'd0;
                    state        <= ST_C_RD_W;
                end

                ST_C_RD_W: begin
                    if ((verify_is_high && client_mem_grant[1]) ||
                        (!verify_is_high && client_mem_grant[0])) begin
                        client_mem_req <= 2'b00;
                        wait_counter   <= 24'd0;
                        state          <= ST_C_RD_DV;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                ST_C_RD_DV: begin
                    if ((verify_is_high && client_mem_read_data_valid[1]) ||
                        (!verify_is_high && client_mem_read_data_valid[0])) begin
                        if (verify_is_high) begin
                            if (client1_mem_read_data != hi_mem_pattern(ProbeBase[AddrWidth-1:0] + verify_idx_addr))
                                fail_latched <= 1'b1;
                        end else begin
                            if (client0_mem_read_data != mem_pattern(verify_idx_addr))
                                fail_latched <= 1'b1;
                        end

                        if (!verify_is_high && verify_idx == ContentionRounds - 1) begin
                            verify_is_high <= 1'b1;
                            verify_idx     <= {ROUND_IDX_WIDTH{1'b0}};
                            state          <= ST_C_RD_REQ;
                        end else if (verify_is_high && verify_idx == ContentionRounds - 1) begin
                            bist_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            verify_idx <= verify_idx + {{(ROUND_IDX_WIDTH-1){1'b0}}, 1'b1};
                            state      <= ST_C_RD_REQ;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OP_WAIT_TIMEOUT) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    memory_arbiter #(
        .NumClients(2),
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
