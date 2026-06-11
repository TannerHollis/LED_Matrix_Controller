// ============================================================================
// File Name   : sdram_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top that exercises sdram_controller directly (no memory
//   arbiter). One button press writes then read-verifies a sweep of SDRAM using
//   mem_pattern(addr) = addr[15:0] ^ 16'hA5C3.
//
// Parameters  :
//   AddrWidth       - Host SDRAM address bus width (Default: 24)
//   DataWidth       - Host/SDRAM data bus width (Default: 16)
//   SdramAddrWidth - SDRAM chip address bus width (Default: 13)
//   SdramRowSize    - Row address field width (Default: 13)
//   SdramColSize    - Column address field width (Default: 9)
//   SdramBankSize   - Bank address field width (Default: 2)
//   BurstLen        - SDRAM burst length; must be 1, 2, 4, or 8 (Default: 8)
//   FirstTestAddr  - First address in the write/read sweep (Default: 0)
//   LastTestAddr   - Last address in the write/read sweep (Default: 24'h00FF_FFFF)
//
// Sweep addresses must be burst-aligned: (LAST - FIRST + 1) must be divisible
// by BurstLen.
//
// Dependencies:
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style; direct SDRAM controller burst write/read sweep BIST.
// ============================================================================

module sdram_bist_top #(
  parameter int unsigned AddrWidth      = 24,
  parameter int unsigned DataWidth      = 16,
  parameter int unsigned SdramAddrWidth = 13,
  parameter int unsigned SdramRowSize   = 13,
  parameter int unsigned SdramColSize   = 9,
  parameter int unsigned SdramBankSize  = 2,
  parameter int unsigned BurstLen       = 8,
  parameter logic [23:0] FirstTestAddr  = 24'h0000_0000,
  parameter logic [23:0] LastTestAddr   = 24'h00FF_FFFF
) (
  input  logic                   clk_50mhz,
  input  logic                   btn_start,
  input  logic                   btn_reset,
  output logic                   led_status,
  output logic [SdramAddrWidth-1:0] sdram_addr,
  output logic [1:0]             sdram_ba,
  output logic                   sdram_cas_n,
  output logic                   sdram_cke,
  output logic                   sdram_clk,
  output logic                   sdram_cs_n,
  inout  wire [DataWidth-1:0]   sdram_dq,
  output logic [DataWidth/8-1:0] sdram_dqm,
  output logic                   sdram_ras_n,
  output logic                   sdram_we_n
);

  typedef enum logic [3:0] {
    StIdle,
    StWrFill,
    StWrDrain,
    StWrFinish,
    StRdFlush,
    StRdFlushW,
    StRdPop,
    StRdSettle,
    StRdCapture,
    StRdCompare,
    StDone,
    StFail
  } bist_state_e;

  localparam logic [8:0] ReadDisabled  = 9'd0;
  localparam logic [11:0] WrFinishWait = 12'd2048;
  localparam logic [8:0] HostBurstLen  = BurstLen;
  localparam int unsigned BurstLenBits = (BurstLen <= 1) ? 1 : $clog2(BurstLen);

  localparam int unsigned SdramRowStart  = SdramColSize;
  localparam int unsigned SdramColStart  = 0;
  localparam int unsigned SdramBankStart = SdramColSize + SdramRowSize;

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
  logic [AddrWidth-1:0]      curr_addr;
  logic [BurstLenBits-1:0]   wr_fill_idx;
  logic [BurstLenBits-1:0]   rd_word_idx;
  logic [11:0]               finish_counter;
  logic [24:0]               blink_counter;
  logic                      start_armed;
  logic [1:0]                btn_sync;

  logic                      write_request;
  logic                      read_request;
  logic                      write_load;
  logic                      read_load;
  logic [AddrWidth-1:0]      write_addr;
  logic [AddrWidth-1:0]      read_addr;
  logic [DataWidth-1:0]      write_data;
  logic [DataWidth-1:0]      read_data_sampled;
  logic [DataWidth-1:0]      expected_data;
  logic [8:0]                ctrl_write_length;
  logic [8:0]                ctrl_read_length;

  logic [DataWidth-1:0] read_data;
  logic [15:0]          write_used;
  logic [15:0]          read_used;
  logic                 write_full;
  logic                 read_empty;

  logic [AddrWidth-1:0] first_test_addr;
  logic [AddrWidth-1:0] last_test_addr;
  logic [AddrWidth-1:0] burst_last_addr;
  logic                 at_last_burst;
  logic                 start_event;

  assign first_test_addr = FirstTestAddr[AddrWidth-1:0];
  assign last_test_addr  = LastTestAddr[AddrWidth-1:0];
  assign burst_last_addr = curr_addr + BurstLen - 1;
  assign at_last_burst   = (burst_last_addr >= last_test_addr);
  assign start_event     = (btn_sync == 2'b10) && start_armed;

  function automatic logic [DataWidth-1:0] mem_pattern(
      input logic [AddrWidth-1:0] addr_in
  );
    mem_pattern = addr_in[DataWidth-1:0] ^ 16'hA5C3;
  endfunction

  initial begin
    if (BurstLen != 1 && BurstLen != 2 && BurstLen != 4 && BurstLen != 8) begin
      $display("ERROR: sdram_bist_top BurstLen=%0d; legal values are 1, 2, 4, 8", BurstLen);
      $finish;
    end
  end

  always_ff @(posedge clk_host or negedge rst_ni) begin
    if (!rst_ni) begin
      btn_sync    <= 2'b11;
      start_armed <= 1'b1;
    end else begin
      btn_sync <= {btn_sync[0], btn_start};
      if (btn_sync[1])
        start_armed <= 1'b1;
      else if (btn_sync == 2'b10 && start_armed)
        start_armed <= 1'b0;
    end
  end

  always_ff @(posedge clk_host or negedge rst_ni) begin
    if (!rst_ni) begin
      state             <= StIdle;
      curr_addr         <= first_test_addr;
      wr_fill_idx       <= {BurstLenBits{1'b0}};
      rd_word_idx       <= {BurstLenBits{1'b0}};
      finish_counter    <= 12'd0;
      blink_counter     <= 25'd0;
      led_status        <= 1'b1;
      write_request     <= 1'b0;
      read_request      <= 1'b0;
      write_load        <= 1'b0;
      read_load         <= 1'b0;
      write_addr        <= first_test_addr;
      read_addr         <= first_test_addr;
      write_data        <= {DataWidth{1'b0}};
      read_data_sampled <= {DataWidth{1'b0}};
      expected_data     <= {DataWidth{1'b0}};
      ctrl_write_length <= HostBurstLen;
      ctrl_read_length  <= ReadDisabled;
    end else begin
      write_request <= 1'b0;
      read_request  <= 1'b0;
      write_load    <= 1'b0;
      read_load     <= 1'b0;
      blink_counter <= blink_counter + 25'd1;

      unique case (state)
        StIdle: begin
          led_status <= 1'b1;
          if (start_event) begin
            write_load        <= 1'b1;
            write_addr        <= first_test_addr;
            read_load         <= 1'b1;
            read_addr         <= first_test_addr;
            ctrl_write_length <= HostBurstLen;
            ctrl_read_length  <= ReadDisabled;
            curr_addr         <= first_test_addr;
            wr_fill_idx       <= {BurstLenBits{1'b0}};
            rd_word_idx       <= {BurstLenBits{1'b0}};
            finish_counter    <= 12'd0;
            state             <= StWrFill;
          end
        end

        StWrFill: begin
          led_status <= ~blink_counter[21];
          write_data <= mem_pattern(curr_addr + {{(AddrWidth-BurstLenBits){1'b0}}, wr_fill_idx});
          if (!write_full) begin
            write_request <= 1'b1;
            if (wr_fill_idx == (BurstLen - 1)) begin
              wr_fill_idx <= {BurstLenBits{1'b0}};
              state       <= StWrDrain;
            end else begin
              wr_fill_idx <= wr_fill_idx + 1'b1;
            end
          end
        end

        StWrDrain: begin
          led_status <= ~blink_counter[21];
          if (write_used[8:0] == 9'd0) begin
            if (at_last_burst) begin
              ctrl_write_length <= ReadDisabled;
              finish_counter    <= 12'd0;
              state             <= StWrFinish;
            end else begin
              curr_addr <= curr_addr + BurstLen;
              state     <= StWrFill;
            end
          end
        end

        StWrFinish: begin
          if (write_used[8:0] == 9'd0 && finish_counter >= WrFinishWait) begin
            curr_addr        <= first_test_addr;
            rd_word_idx      <= {BurstLenBits{1'b0}};
            ctrl_read_length <= ReadDisabled;
            state            <= StRdFlush;
          end else begin
            finish_counter <= finish_counter + 12'd1;
          end
        end

        StRdFlush: begin
          if (!read_empty) begin
            read_request <= 1'b1;
            state        <= StRdFlushW;
          end else begin
            read_load        <= 1'b1;
            read_addr        <= first_test_addr;
            ctrl_read_length <= HostBurstLen;
            state            <= StRdPop;
          end
        end

        StRdFlushW: begin
          state <= StRdFlush;
        end

        StRdPop: begin
          led_status <= ~blink_counter[21];
          if (!read_empty) begin
            read_request <= 1'b1;
            state        <= StRdSettle;
          end
        end

        StRdSettle: begin
          state <= StRdCapture;
        end

        StRdCapture: begin
          read_data_sampled <= read_data;
          expected_data <= mem_pattern(curr_addr + {{(AddrWidth-BurstLenBits){1'b0}}, rd_word_idx});
          state         <= StRdCompare;
        end

        StRdCompare: begin
          if (read_data_sampled != expected_data) begin
            state <= StFail;
          end else if (rd_word_idx == (BurstLen - 1)) begin
            if (at_last_burst) begin
              state <= StDone;
            end else begin
              curr_addr   <= curr_addr + BurstLen;
              rd_word_idx <= {BurstLenBits{1'b0}};
              state       <= StRdPop;
            end
          end else begin
            rd_word_idx <= rd_word_idx + 1'b1;
            state       <= StRdPop;
          end
        end

        StDone: begin
          led_status <= 1'b0;
        end

        StFail: begin
          led_status <= ~blink_counter[23];
        end

        default: state <= StIdle;
      endcase
    end
  end

  sdram_controller #(
    .RowStart(SdramRowStart),
    .RowSize(SdramRowSize),
    .ColStart(SdramColStart),
    .ColSize(SdramColSize),
    .BankStart(SdramBankStart),
    .BankSize(SdramBankSize),
    .SaSize(SdramAddrWidth),
    .AddrSize(AddrWidth),
    .DataWidth(DataWidth),
    .ScBl(BurstLen),
    .ScSingleWrite(0),
    .MaxBurstLen(8)
  ) sdram_ctrl_inst (
    .clk_host_i(clk_host),
    .clk_sdram_i(clk_sdram),
    .rst_ni(rst_ni),
    .write_data_i(write_data),
    .write_request_i(write_request),
    .write_addr_i(write_addr),
    .write_length_i(ctrl_write_length),
    .write_load_i(write_load),
    .write_full_o(write_full),
    .write_used_o(write_used),
    .read_data_o(read_data),
    .read_request_i(read_request),
    .read_addr_i(read_addr),
    .read_length_i(ctrl_read_length),
    .read_load_i(read_load),
    .read_empty_o(read_empty),
    .read_used_o(read_used),
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
