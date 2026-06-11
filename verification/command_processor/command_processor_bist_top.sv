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
//   SdramRowWidth   - SDRAM row address width (Default: 13)
//   SdramColWidth   - SDRAM column address width (Default: 9)
//   SdramBankWidth  - SDRAM bank address width (Default: 2)
//
// Dependencies:
//   - command_processor.sv
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - Migrated to lowRISC style (logic, enum FSM, unique case).
//   Prior   - Scripted write/read/flip commands through SDRAM stack.
// ============================================================================

module command_processor_bist_top #(
  parameter int unsigned TotalWidth     = 1024,
  parameter int unsigned TotalHeight    = 32,
  parameter int unsigned ColorDepth       = 4,
  parameter int unsigned CmdWidth         = 8,
  parameter int unsigned AddrWidth        = 24,
  parameter int unsigned SdramRowWidth    = 13,
  parameter int unsigned SdramColWidth    = 9,
  parameter int unsigned SdramBankWidth   = 2
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

  localparam int unsigned DataWidth = ColorDepth * 3;
  localparam int unsigned CpAddrWidth = (TotalWidth * TotalHeight <= 1) ?
                                        1 : $clog2(TotalWidth * TotalHeight);
  localparam int unsigned SdramAddrWidth =
      SdramBankWidth + SdramRowWidth + SdramColWidth;
  localparam int unsigned ScriptCount     = 4;
  localparam int unsigned ScriptIdxWidth  = 3;
  localparam int unsigned ByteIdxWidth    = 4;
  localparam int unsigned CountWidth      = 32;

  localparam logic [ByteIdxWidth-1:0] AddrBytes =
      (CpAddrWidth <= 8)  ? 4'd1 :
      (CpAddrWidth <= 16) ? 4'd2 :
      (CpAddrWidth <= 24) ? 4'd3 : 4'd4;
  localparam logic [ByteIdxWidth-1:0] DataBytes =
      (DataWidth <= 8)  ? 4'd1 :
      (DataWidth <= 16) ? 4'd2 :
      (DataWidth <= 24) ? 4'd3 : 4'd4;
  localparam logic [ByteIdxWidth-1:0] WritePhaseLen = 4'd1 + AddrBytes + DataBytes;
  localparam logic [ByteIdxWidth-1:0] ReadPhaseLen  = 4'd1 + AddrBytes;
  localparam logic [ByteIdxWidth-1:0] FlipPhaseLen  = 4'd1;

  localparam logic [CmdWidth-1:0] CmdWritePixel = 8'h01;
  localparam logic [CmdWidth-1:0] CmdFlipBuffer = 8'h02;
  localparam logic [CmdWidth-1:0] CmdReadPixel  = 8'h03;

  localparam logic [CountWidth-1:0] OpWaitTimeout       = 32'd10_000_000;
  localparam int unsigned           SdramHostInitCycles = 24'd50_000;

  typedef enum logic [1:0] {
    PhWrite,
    PhRead,
    PhFlip
  } command_phase_e;

  typedef enum logic [3:0] {
    StIdle,
    StSendByte,
    StByteGap,
    StWaitWrite,
    StWaitRead,
    StWaitFlip
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
  logic [23:0] sdram_init_countdown;
  command_phase_e command_phase;
  logic [ScriptIdxWidth-1:0] script_index;
  logic [ByteIdxWidth-1:0]   byte_index;
  logic [CountWidth-1:0]     wait_counter;
  logic [24:0]               blink_counter;
  logic                      bist_done;
  logic                      fail_latched;
  logic                      frame_ready_seen;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic [CmdWidth-1:0] spi_data_in;
  logic                spi_data_valid;
  logic                frame_ready;

  logic                cp_mem_req;
  logic                cp_mem_write;
  logic [3:0]          cp_mem_read_length;
  logic [3:0]          cp_mem_write_length;
  logic [CpAddrWidth-1:0] cp_mem_addr;
  logic [DataWidth-1:0]   cp_mem_write_data;
  logic                cp_mem_grant;
  logic [DataWidth-1:0] cp_mem_read_data;
  logic                cp_mem_read_data_valid;
  logic [DataWidth-1:0] read_data_out;
  logic                read_data_valid;

  logic [1:0] client_mem_req;
  logic [1:0] client_mem_write;
  logic [AddrWidth*2-1:0] client_mem_addr;
  logic [DataWidth*2-1:0] client_mem_write_data;
  logic [7:0] client_mem_read_length;
  logic [7:0] client_mem_write_length;
  logic [1:0] client_mem_grant;
  logic [DataWidth*2-1:0] client_mem_read_data;
  logic [1:0] client_mem_read_data_valid;

  logic                master_mem_req;
  logic                master_mem_write;
  logic [AddrWidth-1:0] master_mem_addr;
  logic [DataWidth-1:0] master_mem_write_data;
  logic                master_mem_ready;
  logic [3:0]          master_mem_read_length;
  logic [3:0]          master_mem_write_length;
  logic [DataWidth-1:0] master_mem_read_data;
  logic                master_mem_read_data_valid;

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

  assign client_mem_req = {cp_mem_req, 1'b0};
  assign client_mem_write = {cp_mem_write, 1'b0};
  assign client_mem_addr =
      {{(AddrWidth-CpAddrWidth){1'b0}}, cp_mem_addr, {AddrWidth{1'b0}}};
  assign client_mem_write_data =
      {cp_mem_write_data, {DataWidth{1'b0}}};
  assign client_mem_read_length  = {cp_mem_read_length, 4'd1};
  assign client_mem_write_length = {cp_mem_write_length, 4'd1};
  assign cp_mem_grant = client_mem_grant[1];
  assign cp_mem_read_data = client_mem_read_data[2*DataWidth-1:DataWidth];
  assign cp_mem_read_data_valid = client_mem_read_data_valid[1];

  function automatic logic [CpAddrWidth-1:0] script_addr(
      input logic [ScriptIdxWidth-1:0] idx);
    unique case (idx)
      3'd0: script_addr = 15'h0000;
      3'd1: script_addr = 15'h0015;
      3'd2: script_addr = 15'h0123;
      3'd3: script_addr = 15'h1FFE;
      default: script_addr = {CpAddrWidth{1'b0}};
    endcase
  endfunction

  function automatic logic [DataWidth-1:0] script_data(
      input logic [ScriptIdxWidth-1:0] idx);
    unique case (idx)
      3'd0: script_data = 12'hA5C;
      3'd1: script_data = 12'h5A3;
      3'd2: script_data = 12'hC3F;
      3'd3: script_data = 12'h03C;
      default: script_data = {DataWidth{1'b0}};
    endcase
  endfunction

  function automatic logic [ByteIdxWidth-1:0] phase_len(
      input command_phase_e phase);
    unique case (phase)
      PhWrite: phase_len = WritePhaseLen;
      PhRead:  phase_len = ReadPhaseLen;
      PhFlip:  phase_len = FlipPhaseLen;
      default: phase_len = FlipPhaseLen;
    endcase
  endfunction

  function automatic logic [CmdWidth-1:0] command_byte(
      input command_phase_e              phase,
      input logic [ScriptIdxWidth-1:0]   idx,
      input logic [ByteIdxWidth-1:0]     byte_idx);
    logic [CpAddrWidth-1:0] shifted_addr;
    logic [DataWidth-1:0]   shifted_data;
    shifted_addr = {CpAddrWidth{1'b0}};
    shifted_data = {DataWidth{1'b0}};
    if (phase == PhWrite) begin
      if (byte_idx == 0)
        command_byte = CmdWritePixel;
      else if (byte_idx <= AddrBytes) begin
        shifted_addr = script_addr(idx) >> ((byte_idx - 1) * 8);
        command_byte = shifted_addr[CmdWidth-1:0];
      end else begin
        shifted_data = script_data(idx) >> ((byte_idx - 1 - AddrBytes) * 8);
        command_byte = shifted_data[CmdWidth-1:0];
      end
    end else if (phase == PhRead) begin
      if (byte_idx == 0)
        command_byte = CmdReadPixel;
      else begin
        shifted_addr = script_addr(idx) >> ((byte_idx - 1) * 8);
        command_byte = shifted_addr[CmdWidth-1:0];
      end
    end else begin
      command_byte = CmdFlipBuffer;
    end
  endfunction

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
      state                <= StIdle;
      command_phase        <= PhWrite;
      script_index         <= {ScriptIdxWidth{1'b0}};
      byte_index           <= {ByteIdxWidth{1'b0}};
      wait_counter         <= {CountWidth{1'b0}};
      blink_counter        <= 25'd0;
      bist_done            <= 1'b0;
      fail_latched         <= 1'b0;
      frame_ready_seen     <= 1'b0;
      sdram_init_countdown <= SdramHostInitCycles;
      led_status           <= 1'b1;
      spi_data_in          <= {CmdWidth{1'b0}};
      spi_data_valid       <= 1'b0;
    end else begin
      blink_counter  <= blink_counter + 25'd1;
      spi_data_valid <= 1'b0;
      if (frame_ready)
        frame_ready_seen <= 1'b1;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          wait_counter <= {CountWidth{1'b0}};
          if (sdram_init_countdown != 24'd0)
            sdram_init_countdown <= sdram_init_countdown - 24'd1;
          else if (start_event) begin
            bist_done        <= 1'b0;
            fail_latched     <= 1'b0;
            frame_ready_seen <= 1'b0;
            command_phase    <= PhWrite;
            script_index     <= {ScriptIdxWidth{1'b0}};
            byte_index       <= {ByteIdxWidth{1'b0}};
            state            <= StSendByte;
          end
        end

        // Scripted SPI byte stream into command_processor.
        StSendByte: begin
          spi_data_in    <= command_byte(command_phase, script_index, byte_index);
          spi_data_valid <= 1'b1;
          wait_counter   <= {CountWidth{1'b0}};
          state          <= StByteGap;
        end

        StByteGap: begin
          if (byte_index == phase_len(command_phase) - 1) begin
            byte_index   <= {ByteIdxWidth{1'b0}};
            wait_counter <= {CountWidth{1'b0}};
            if (command_phase == PhWrite)
              state <= StWaitWrite;
            else if (command_phase == PhRead)
              state <= StWaitRead;
            else begin
              frame_ready_seen <= frame_ready_seen | frame_ready;
              state <= StWaitFlip;
            end
          end else begin
            byte_index <= byte_index + {{(ByteIdxWidth-1){1'b0}}, 1'b1};
            state      <= StSendByte;
          end
        end

        StWaitWrite: begin
          if (cp_mem_req && cp_mem_write) begin
            if (cp_mem_addr != script_addr(script_index) ||
                cp_mem_write_data != script_data(script_index)) begin
              fail_latched <= 1'b1;
            end
          end

          if (cp_mem_req && cp_mem_write && cp_mem_grant) begin
            command_phase <= PhRead;
            byte_index    <= {ByteIdxWidth{1'b0}};
            wait_counter  <= {CountWidth{1'b0}};
            state         <= StSendByte;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        // SDRAM-backed read response check via command_processor read port.
        StWaitRead: begin
          if (read_data_valid) begin
            if (read_data_out != script_data(script_index))
              fail_latched <= 1'b1;
            wait_counter <= {CountWidth{1'b0}};
            if (script_index == ScriptCount - 1) begin
              command_phase <= PhFlip;
              script_index  <= {ScriptIdxWidth{1'b0}};
            end else begin
              command_phase <= PhWrite;
              script_index  <= script_index + {{(ScriptIdxWidth-1){1'b0}}, 1'b1};
            end
            byte_index <= {ByteIdxWidth{1'b0}};
            state      <= StSendByte;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        StWaitFlip: begin
          if (frame_ready_seen) begin
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

  command_processor #(
    .TotalWidth(TotalWidth),
    .TotalHeight(TotalHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth)
  ) command_processor_inst (
    .clk_i(clk_host),
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
