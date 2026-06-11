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
//   NumLowPriClients   - Count of low-priority clients (Default: 1)
//   AddrWidth          - Width of the memory address bus (Default: 24)
//   DataWidth          - Width of the client data bus (Default: 12)
//   LastTestAddr       - Last address in each client sweep (Default: 24'h00_003F)
//   OpWaitTimeout      - FSM wait timeout in clk cycles (Default: 24'd10_000_000)
//
// Dependencies:
//   - memory_arbiter.sv
//   - memory_arbiter_mock_slave.sv
// ============================================================================
// Revision History:
//   Current - Migrated to lowRISC style (logic, enum FSM, unique case).
//   Prior   - Arbiter-only BIST with mock slave and multi-client priority tests.
// ============================================================================

module memory_arbiter_bist_top #(
  parameter int unsigned NumClients       = 16,
  parameter int unsigned NumLowPriClients = 8,
  parameter int unsigned AddrWidth        = 24,
  parameter int unsigned DataWidth        = 12,
  parameter logic [23:0] LastTestAddr     = 24'h0F_FFFF,
  parameter int unsigned OpWaitTimeout    = 24'd10_000_000
) (
  input  logic clk_50mhz,
  input  logic btn_start,
  input  logic btn_reset,
  output logic led_status
);

  localparam int unsigned ClientIdxWidth =
      (NumClients <= 1) ? 1 : $clog2(NumClients);
  localparam logic [AddrWidth-1:0] LastAddr = LastTestAddr[AddrWidth-1:0];

  typedef enum logic [3:0] {
    StIdle,
    StWrReq,
    StWrWait,
    StRdReq,
    StRdWait,
    StRdDvWait,
    StNextCli,
    StCntReq,
    StCntWait,
    StCntDeassert,
    StCntLoWait
  } bist_state_e;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  bist_state_e state;
  logic [ClientIdxWidth-1:0] active_client;
  logic [AddrWidth-1:0]      curr_addr;
  logic [23:0]               wait_counter;
  logic [24:0]               blink_counter;
  logic                      bist_done;
  logic                      fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic [NumClients-1:0]           client_mem_req;
  logic [NumClients-1:0]           client_mem_write;
  logic [AddrWidth*NumClients-1:0] client_mem_addr;
  logic [DataWidth*NumClients-1:0] client_mem_write_data;
  logic [4*NumClients-1:0]         client_mem_read_length;
  logic [4*NumClients-1:0]         client_mem_write_length;
  logic [NumClients-1:0]           client_mem_grant;
  logic [DataWidth*NumClients-1:0] client_mem_read_data;
  logic [NumClients-1:0]           client_mem_read_data_valid;

  logic                master_mem_req;
  logic                master_mem_write;
  logic [AddrWidth-1:0] master_mem_addr;
  logic [DataWidth-1:0] master_mem_write_data;
  logic                master_mem_ready;
  logic [DataWidth-1:0] master_mem_read_data;
  logic                master_mem_read_data_valid;

  int unsigned ci;

  function automatic logic [AddrWidth-1:0] client_base_addr(
      input logic [ClientIdxWidth-1:0] client_id);
    client_base_addr = {
        {(8 - ClientIdxWidth){1'b0}},
        client_id,
        {(AddrWidth - 8){1'b0}}
    };
  endfunction

  function automatic logic [DataWidth-1:0] mem_pattern(
      input logic [ClientIdxWidth-1:0] client_id,
      input logic [AddrWidth-1:0]       addr_in);
    logic [15:0] full_pat;
    full_pat    = addr_in[15:0] ^ 16'hA5C3 ^ addr_in[23:16];
    mem_pattern = full_pat[DataWidth-1:0];
  endfunction

  logic [AddrWidth-1:0] active_addr;
  assign active_addr = client_base_addr(active_client) + curr_addr;

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
      state                   <= StIdle;
      active_client           <= {ClientIdxWidth{1'b0}};
      curr_addr               <= {AddrWidth{1'b0}};
      wait_counter            <= 24'd0;
      blink_counter           <= 25'd0;
      bist_done               <= 1'b0;
      fail_latched            <= 1'b0;
      led_status              <= 1'b1;
      client_mem_req          <= {NumClients{1'b0}};
      client_mem_write        <= {NumClients{1'b0}};
      client_mem_addr         <= {AddrWidth*NumClients{1'b0}};
      client_mem_write_data   <= {DataWidth*NumClients{1'b0}};
      client_mem_read_length  <= {(4*NumClients){1'b1}};
      client_mem_write_length <= {(4*NumClients){1'b1}};
    end else begin
      for (ci = 0; ci < NumClients; ci = ci + 1) begin
        client_mem_read_length[ci*4 +: 4]  <= 4'd1;
        client_mem_write_length[ci*4 +: 4] <= 4'd1;
      end

      blink_counter <= blink_counter + 25'd1;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          client_mem_req   <= {NumClients{1'b0}};
          client_mem_write <= {NumClients{1'b0}};
          wait_counter     <= 24'd0;
          if (start_event) begin
            active_client <= {ClientIdxWidth{1'b0}};
            curr_addr     <= {AddrWidth{1'b0}};
            bist_done     <= 1'b0;
            fail_latched  <= 1'b0;
            state         <= StWrReq;
          end
        end

        StWrReq: begin
          client_mem_req[active_client] <= 1'b1;
          client_mem_write[active_client] <= 1'b1;
          client_mem_addr[active_client*AddrWidth +: AddrWidth] <= active_addr;
          client_mem_write_data[active_client*DataWidth +: DataWidth] <=
              mem_pattern(active_client, active_addr);
          wait_counter <= 24'd0;
          state        <= StWrWait;
        end

        StWrWait: begin
          if (client_mem_grant[active_client]) begin
            client_mem_req <= {NumClients{1'b0}};
            if (curr_addr == LastAddr) begin
              curr_addr <= {AddrWidth{1'b0}};
              state     <= StRdReq;
            end else begin
              curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
              state     <= StWrReq;
            end
            wait_counter <= 24'd0;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StRdReq: begin
          client_mem_req[active_client] <= 1'b1;
          client_mem_write[active_client] <= 1'b0;
          client_mem_addr[active_client*AddrWidth +: AddrWidth] <= active_addr;
          wait_counter <= 24'd0;
          state        <= StRdWait;
        end

        StRdWait: begin
          if (client_mem_grant[active_client]) begin
            client_mem_req <= {NumClients{1'b0}};
            wait_counter   <= 24'd0;
            state          <= StRdDvWait;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StRdDvWait: begin
          if (client_mem_read_data_valid[active_client]) begin
            if (client_mem_read_data[active_client*DataWidth +: DataWidth] !=
                mem_pattern(active_client, active_addr))
              fail_latched <= 1'b1;

            if (curr_addr == LastAddr) begin
              state <= StNextCli;
            end else begin
              curr_addr <= curr_addr + {{(AddrWidth-1){1'b0}}, 1'b1};
              state     <= StRdReq;
            end
            wait_counter <= 24'd0;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StNextCli: begin
          client_mem_req <= {NumClients{1'b0}};
          if (active_client == NumClients - 1) begin
            if (NumClients >= 2)
              state <= StCntReq;
            else begin
              bist_done <= 1'b1;
              state     <= StIdle;
            end
          end else begin
            active_client <= active_client + {{(ClientIdxWidth-1){1'b0}}, 1'b1};
            curr_addr     <= {AddrWidth{1'b0}};
            state         <= StWrReq;
          end
        end

        // Priority contention: all clients request simultaneously; highest
        // index must win before any low-priority client is granted.
        StCntReq: begin
          client_mem_write <= {NumClients{1'b0}};
          for (ci = 0; ci < NumClients; ci = ci + 1) begin
            client_mem_addr[ci*AddrWidth +: AddrWidth] <=
                client_base_addr(ci[ClientIdxWidth-1:0]);
          end
          client_mem_req <= {NumClients{1'b1}};
          wait_counter   <= 24'd0;
          state          <= StCntWait;
        end

        StCntWait: begin
          if (client_mem_grant[NumClients-1]) begin
            client_mem_req <= {NumClients{1'b0}};
            state          <= StCntDeassert;
            wait_counter   <= 24'd0;
          end else if (|(client_mem_grant & ((1'b1 << NumLowPriClients) - 1'b1))) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StCntDeassert: begin
          if (NumLowPriClients == 0) begin
            client_mem_req <= {NumClients{1'b0}};
            bist_done      <= 1'b1;
            state          <= StIdle;
          end else begin
            // Re-assert only low-priority clients; any grant here is a fail.
            client_mem_req <= ((1'b1 << NumLowPriClients) - 1'b1);
            wait_counter   <= 24'd0;
            state          <= StCntLoWait;
          end
        end

        StCntLoWait: begin
          if (|client_mem_grant) begin
            client_mem_req <= {NumClients{1'b0}};
            bist_done      <= 1'b1;
            state          <= StIdle;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        default: state <= StIdle;
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

  // Mock memory slave: accepts arbiter master port and echoes write data on read.
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
