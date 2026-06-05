// ============================================================================
// File Name   : memory_arbiter_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for memory_arbiter only (no SDRAM). Client FSM(s) drive
//   the arbiter into a mock memory slave to verify grant timing, priority, and
//   read-data routing across up to NumClients ports.
//
// Parameters  :
//   NumClients         - Number of client ports to exercise (Default: 2)
//   NumLowPriClients - Count of low-priority clients (Default: 1)
//   AddrWidth          - Width of the memory address bus (Default: 24)
//   DataWidth          - Width of the client data bus (Default: 12)
//   LastTestAddr      - Last address in each client sweep (Default: 24'h00_003F)
//   OpWaitTimeout     - FSM wait timeout in clk cycles (Default: 24'd10_000_000)
//
// Dependencies:
//   - memory_arbiter.sv
//   - memory_arbiter_mock_slave.sv
// ============================================================================
// Revision History:
//   Current - Arbiter-only BIST with mock slave and multi-client priority tests.
// ============================================================================

module memory_arbiter_bist_top #(
  parameter int unsigned NumClients        = 16,
  parameter int unsigned NumLowPriClients  = 8,
  parameter int unsigned AddrWidth         = 24,
  parameter int unsigned DataWidth         = 12,
  parameter logic [23:0] LastTestAddr      = 24'h0F_FFFF,
  parameter int unsigned OpWaitTimeout     = 24'd10_000_000
) (
    input  wire clk_50mhz,
    input  wire btn_start,
    input  wire btn_reset,
    output reg  led_status
);

    localparam CLIENT_IDX_WIDTH = (NumClients <= 1) ? 1 : $clog2(NumClients);

    localparam S_IDLE       = 4'd0;
    localparam S_WR_REQ     = 4'd1;
    localparam S_WR_WAIT    = 4'd2;
    localparam S_RD_REQ     = 4'd3;
    localparam S_RD_WAIT    = 4'd4;
    localparam S_RD_DV_WAIT = 4'd5;
    localparam S_NEXT_CLI   = 4'd6;
    localparam S_CNT_REQ    = 4'd7;
    localparam S_CNT_WAIT   = 4'd8;
    localparam S_CNT_DEASSERT = 4'd9;
    localparam S_CNT_LO_WAIT  = 4'd10;

    localparam [AddrWidth-1:0] LAST_ADDR = LastTestAddr[AddrWidth-1:0];

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [3:0] state;
    reg [CLIENT_IDX_WIDTH-1:0] active_client;
    reg [AddrWidth-1:0] curr_addr;
    reg [23:0] wait_counter;
    reg [24:0] blink_counter;
    reg bist_done;
    reg fail_latched;

    reg [2:0] start_sync;
    reg start_armed;
    reg start_event;

    reg [NumClients-1:0] client_mem_req;
    reg [NumClients-1:0] client_mem_write;
    reg [AddrWidth*NumClients-1:0] client_mem_addr;
    reg [DataWidth*NumClients-1:0] client_mem_write_data;
    reg [4*NumClients-1:0] client_mem_read_length;
    reg [4*NumClients-1:0] client_mem_write_length;
    wire [NumClients-1:0] client_mem_grant;
    wire [DataWidth*NumClients-1:0] client_mem_read_data;
    wire [NumClients-1:0] client_mem_read_data_valid;

    wire master_mem_req;
    wire master_mem_write;
    wire [AddrWidth-1:0] master_mem_addr;
    wire [DataWidth-1:0] master_mem_write_data;
    wire master_mem_ready;
    wire [DataWidth-1:0] master_mem_read_data;
    wire master_mem_read_data_valid;

    integer ci;

    function [AddrWidth-1:0] client_base_addr;
        input [CLIENT_IDX_WIDTH-1:0] client_id;
        begin
            client_base_addr = {
                {(8 - CLIENT_IDX_WIDTH){1'b0}},
                client_id,
                {(AddrWidth - 8){1'b0}}
            };
        end
    endfunction

    function [DataWidth-1:0] mem_pattern;
        input [CLIENT_IDX_WIDTH-1:0] client_id;
        input [AddrWidth-1:0]       addr_in;
        reg [15:0] full_pat;
        begin
            full_pat    = addr_in[15:0] ^ 16'hA5C3 ^ addr_in[23:16];
            mem_pattern = full_pat[DataWidth-1:0];
        end
    endfunction

    wire [AddrWidth-1:0] active_addr =
        client_base_addr(active_client) + curr_addr;

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
            active_client         <= {CLIENT_IDX_WIDTH{1'b0}};
            curr_addr             <= {AddrWidth{1'b0}};
            wait_counter          <= 24'd0;
            blink_counter         <= 25'd0;
            bist_done             <= 1'b0;
            fail_latched          <= 1'b0;
            led_status            <= 1'b1;
            client_mem_req        <= {NumClients{1'b0}};
            client_mem_write      <= {NumClients{1'b0}};
            client_mem_addr       <= {AddrWidth*NumClients{1'b0}};
            client_mem_write_data <= {DataWidth*NumClients{1'b0}};
            client_mem_read_length  <= {(4*NumClients){1'b1}};
            client_mem_write_length <= {(4*NumClients){1'b1}};
        end else begin
            for (ci = 0; ci < NumClients; ci = ci + 1) begin
                client_mem_read_length[ci*4 +: 4]  <= 4'd1;
                client_mem_write_length[ci*4 +: 4] <= 4'd1;
            end

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
                    client_mem_req   <= {NumClients{1'b0}};
                    client_mem_write <= {NumClients{1'b0}};
                    wait_counter     <= 24'd0;
                    if (start_event) begin
                        active_client <= {CLIENT_IDX_WIDTH{1'b0}};
                        curr_addr     <= {AddrWidth{1'b0}};
                        bist_done     <= 1'b0;
                        fail_latched  <= 1'b0;
                        state         <= S_WR_REQ;
                    end
                end

                S_WR_REQ: begin
                    client_mem_req[active_client] <= 1'b1;
                    client_mem_write[active_client] <= 1'b1;
                    client_mem_addr[active_client*AddrWidth +: AddrWidth] <= active_addr;
                    client_mem_write_data[active_client*DataWidth +: DataWidth] <=
                        mem_pattern(active_client, active_addr);
                    wait_counter <= 24'd0;
                    state        <= S_WR_WAIT;
                end

                S_WR_WAIT: begin
                    if (client_mem_grant[active_client]) begin
                        client_mem_req <= {NumClients{1'b0}};
                        if (curr_addr == LAST_ADDR) begin
                            curr_addr <= {AddrWidth{1'b0}};
                            state     <= S_RD_REQ;
                        end else begin
                            curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                            state     <= S_WR_REQ;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OpWaitTimeout) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_RD_REQ: begin
                    client_mem_req[active_client] <= 1'b1;
                    client_mem_write[active_client] <= 1'b0;
                    client_mem_addr[active_client*AddrWidth +: AddrWidth] <= active_addr;
                    wait_counter <= 24'd0;
                    state        <= S_RD_WAIT;
                end

                S_RD_WAIT: begin
                    if (client_mem_grant[active_client]) begin
                        client_mem_req <= {NumClients{1'b0}};
                        wait_counter   <= 24'd0;
                        state          <= S_RD_DV_WAIT;
                    end else if (wait_counter >= OpWaitTimeout) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_RD_DV_WAIT: begin
                    if (client_mem_read_data_valid[active_client]) begin
                        if (client_mem_read_data[active_client*DataWidth +: DataWidth] !=
                            mem_pattern(active_client, active_addr))
                            fail_latched <= 1'b1;

                        if (curr_addr == LAST_ADDR) begin
                            state <= S_NEXT_CLI;
                        end else begin
                            curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
                            state     <= S_RD_REQ;
                        end
                        wait_counter <= 24'd0;
                    end else if (wait_counter >= OpWaitTimeout) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_NEXT_CLI: begin
                    client_mem_req <= {NumClients{1'b0}};
                    if (active_client == NumClients - 1) begin
                        if (NumClients >= 2)
                            state <= S_CNT_REQ;
                        else begin
                            bist_done <= 1'b1;
                            state     <= S_IDLE;
                        end
                    end else begin
                        active_client <= active_client + {{(CLIENT_IDX_WIDTH-1){1'b0}}, 1'b1};
                        curr_addr     <= {AddrWidth{1'b0}};
                        state         <= S_WR_REQ;
                    end
                end

                S_CNT_REQ: begin
                    client_mem_write <= {NumClients{1'b0}};
                    for (ci = 0; ci < NumClients; ci = ci + 1) begin
                        client_mem_addr[ci*AddrWidth +: AddrWidth] <=
                            client_base_addr(ci[CLIENT_IDX_WIDTH-1:0]);
                    end
                    client_mem_req <= {NumClients{1'b1}};
                    wait_counter   <= 24'd0;
                    state          <= S_CNT_WAIT;
                end

                S_CNT_WAIT: begin
                    if (client_mem_grant[NumClients-1]) begin
                        client_mem_req <= {NumClients{1'b0}};
                        state          <= S_CNT_DEASSERT;
                        wait_counter   <= 24'd0;
                    end else if (|(client_mem_grant & ((1'b1 << NumLowPriClients) - 1'b1))) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else if (wait_counter >= OpWaitTimeout) begin
                        fail_latched <= 1'b1;
                        bist_done    <= 1'b1;
                        state        <= S_IDLE;
                    end else begin
                        wait_counter <= wait_counter + 24'd1;
                    end
                end

                S_CNT_DEASSERT: begin
                    if (NumLowPriClients == 0) begin
                        client_mem_req <= {NumClients{1'b0}};
                        bist_done      <= 1'b1;
                        state          <= S_IDLE;
                    end else begin
                        client_mem_req <= ((1'b1 << NumLowPriClients) - 1'b1);
                        wait_counter   <= 24'd0;
                        state          <= S_CNT_LO_WAIT;
                    end
                end

                S_CNT_LO_WAIT: begin
                    if (|client_mem_grant) begin
                        client_mem_req <= {NumClients{1'b0}};
                        bist_done      <= 1'b1;
                        state          <= S_IDLE;
                    end else if (wait_counter >= OpWaitTimeout) begin
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
        .NumClients(NumClients),
        .NumLowPriClients(NumLowPriClients),
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
        .master_mem_read_length_o(),
        .master_mem_write_length_o(),
        .master_mem_ready_i(master_mem_ready),
        .master_mem_read_data_i(master_mem_read_data),
        .master_mem_read_data_valid_i(master_mem_read_data_valid)
    );

    memory_arbiter_mock_slave #(
        .AddrWidth(AddrWidth),
        .DataWidth(DataWidth)
    ) mock_slave_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .master_mem_req_i(master_mem_req),
        .master_mem_write_i(master_mem_write),
        .master_mem_addr_i(master_mem_addr),
        .master_mem_write_data_i(master_mem_write_data),
        .master_mem_ready_o(master_mem_ready),
        .master_mem_read_data_o(master_mem_read_data),
        .master_mem_read_data_valid_o(master_mem_read_data_valid)
    );

endmodule
