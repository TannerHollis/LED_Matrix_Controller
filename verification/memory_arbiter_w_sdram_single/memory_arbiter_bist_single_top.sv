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
//   LastTestAddr    - Last address in the write/read sweep (Default: 24'h00FF_FFFF)
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
//   Current - Migrated to lowRISC style (logic, enum FSM, unique case).
//   Prior   - Single-client SDRAM write/read sweep with burst-8 verify reads.
// ============================================================================

module memory_arbiter_bist_single_top #(
  parameter int unsigned AddrWidth      = 24,
  parameter int unsigned DataWidth      = 12,
  parameter logic [23:0] LastTestAddr   = 24'h00FF_FFFF,
  parameter int unsigned SdramRowWidth  = 13,
  parameter int unsigned SdramColWidth  = 9,
  parameter int unsigned SdramBankWidth = 2
) (
  input  logic        clk_50mhz,
  input  logic        btn_start,
  input  logic        btn_reset,
  output logic        led_status,
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

  // Must exceed sdram_arbiter_adapter WR_TURNAROUND_WAIT (default 64) for first-write grant.
  localparam int unsigned OpWaitTimeout       = 24'd10_000_000;
  // Host-side guard for sdram_controller INIT_PER (24000 SDRAM clocks @ 100 MHz).
  localparam int unsigned SdramHostInitCycles = 24'd50_000;
  localparam int unsigned ReadBurstLen        = 8;
  localparam int unsigned RdBeatBits          = 3;

  localparam logic [AddrWidth-1:0] LastAddr = LastTestAddr[AddrWidth-1:0];
  localparam int unsigned SdramAddrWidth =
      SdramBankWidth + SdramRowWidth + SdramColWidth;

  typedef enum logic [2:0] {
    StIdle,
    StWrReq,
    StWrWait,
    StRdReq,
    StRdWait,
    StRdDvWait
  } bist_state_e;

  logic clk_i;
  logic clk_host;
  logic clk_sdram;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  sdram_clock_gen sdram_clock_gen_inst (
    .clk_board_i(clk_i),
    .rst_ni(rst_ni),
    .clk_host_o(clk_host),
    .clk_sdram_o(clk_sdram),
    .pll_locked_o()
  );

  bist_state_e state;
  logic [AddrWidth-1:0] curr_addr;
  logic [23:0]          wait_counter;
  logic [24:0]          blink_counter;
  logic                 bist_done;
  logic                 fail_latched;
  logic [23:0]          sdram_init_countdown;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic                client_mem_req;
  logic                client_mem_write;
  logic [AddrWidth-1:0] client_mem_addr;
  logic [DataWidth-1:0] client_mem_write_data;
  logic                client_mem_grant;
  logic [DataWidth-1:0] client_mem_read_data;
  logic                client_mem_read_data_valid;

  logic                master_mem_req;
  logic                master_mem_write;
  logic [AddrWidth-1:0] master_mem_addr;
  logic [DataWidth-1:0] master_mem_write_data;
  logic                master_mem_ready;
  logic [3:0]          master_mem_read_length;
  logic [3:0]          master_mem_write_length;
  logic [DataWidth-1:0] master_mem_read_data;
  logic                master_mem_read_data_valid;

  logic [3:0]          client_mem_read_length;
  logic [3:0]          client_mem_write_length;
  logic [RdBeatBits-1:0] rd_beat_idx;

  assign client_mem_write_length = 4'd1;

  logic [15:0] sdram_write_data;
  logic        sdram_write_request;
  logic [SdramAddrWidth-1:0] sdram_write_addr;
  logic [8:0]  sdram_write_length;
  logic        sdram_write_load;
  logic        sdram_write_full;
  logic [15:0] sdram_write_used;

  logic [15:0] sdram_read_data;
  logic        sdram_read_request;
  logic [SdramAddrWidth-1:0] sdram_read_addr;
  logic [8:0]  sdram_read_length;
  logic        sdram_read_load;
  logic        sdram_read_empty;

  logic [AddrWidth-1:0] burst_last_addr;
  logic                 at_last_burst;
  assign burst_last_addr = curr_addr + ReadBurstLen - 1;
  assign at_last_burst = (burst_last_addr >= LastAddr);

  function automatic logic [DataWidth-1:0] mem_pattern(
      input logic [AddrWidth-1:0] addr_in);
    logic [15:0] full_pat;
    full_pat    = addr_in[15:0] ^ 16'hA5C3;
    mem_pattern = full_pat[DataWidth-1:0];
  endfunction

  initial begin
    if (((LastAddr + 1) % ReadBurstLen) != 0) begin
      $display("ERROR: memory_arbiter_bist_single_top LastTestAddr+1 must be multiple of %0d",
               ReadBurstLen);
      $finish;
    end
  end

  always_ff @(posedge clk_host or negedge rst_ni) begin
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

  always_ff @(posedge clk_host or negedge rst_ni) begin
    if (!rst_ni) begin
      state                  <= StIdle;
      curr_addr              <= {AddrWidth{1'b0}};
      wait_counter           <= 24'd0;
      blink_counter          <= 25'd0;
      bist_done              <= 1'b0;
      fail_latched           <= 1'b0;
      sdram_init_countdown   <= SdramHostInitCycles;
      led_status             <= 1'b1;
      client_mem_req         <= 1'b0;
      client_mem_write       <= 1'b0;
      client_mem_addr        <= {AddrWidth{1'b0}};
      client_mem_write_data  <= {DataWidth{1'b0}};
      client_mem_read_length <= 4'd1;
      rd_beat_idx            <= {RdBeatBits{1'b0}};
    end else begin
      blink_counter <= blink_counter + 25'd1;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          client_mem_req <= 1'b0;
          wait_counter   <= 24'd0;
          // Wait for SDRAM controller init before accepting start.
          if (sdram_init_countdown != 24'd0)
            sdram_init_countdown <= sdram_init_countdown - 24'd1;
          else if (start_event) begin
            curr_addr    <= {AddrWidth{1'b0}};
            bist_done    <= 1'b0;
            fail_latched <= 1'b0;
            state        <= StWrReq;
          end
        end

        StWrReq: begin
          client_mem_req         <= 1'b1;
          client_mem_read_length <= 4'd1;
          client_mem_write       <= 1'b1;
          client_mem_addr        <= curr_addr;
          client_mem_write_data  <= mem_pattern(curr_addr);
          wait_counter           <= 24'd0;
          state                  <= StWrWait;
        end

        StWrWait: begin
          if (client_mem_grant) begin
            client_mem_req <= 1'b0;
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

        // Burst-8 read verify through arbiter -> adapter -> SDRAM path.
        StRdReq: begin
          client_mem_req         <= 1'b1;
          client_mem_write       <= 1'b0;
          client_mem_read_length <= ReadBurstLen[3:0];
          client_mem_addr        <= curr_addr;
          wait_counter           <= 24'd0;
          state                  <= StRdWait;
        end

        StRdWait: begin
          if (client_mem_grant) begin
            client_mem_req <= 1'b0;
            rd_beat_idx    <= {RdBeatBits{1'b0}};
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
          if (client_mem_read_data_valid) begin
            if (client_mem_read_data != mem_pattern(
                    curr_addr + {{(AddrWidth-RdBeatBits){1'b0}}, rd_beat_idx}))
              fail_latched <= 1'b1;
            if (rd_beat_idx == (ReadBurstLen - 1)) begin
              if (at_last_burst) begin
                bist_done <= 1'b1;
                state     <= StIdle;
              end else begin
                curr_addr   <= curr_addr + ReadBurstLen;
                rd_beat_idx <= {RdBeatBits{1'b0}};
                state       <= StRdReq;
              end
            end else begin
              rd_beat_idx <= rd_beat_idx + 1'b1;
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

        default: state <= StIdle;
      endcase
    end
  end

  memory_arbiter #(
    .NumClients(1),
    .NumLowPriClients(1),
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) mem_arbiter_inst (
    .clk_i(clk_host),
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
    .SdramAddrWidth(SdramAddrWidth),
    .MaxBurstLen(8),
    .ScBl(8)
  ) sdram_adapter_inst (
    .clk_i(clk_host),
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
    .clk_host_i(clk_host),
    .clk_sdram_i(clk_sdram),
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
