// ============================================================================
// File Name   : sdram_arbiter_adapter.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Bridges memory_arbiter master transactions to the sdram_controller FIFO host
//   interface. Delivers up to eight arbiter read beats per SDRAM burst command;
//   host writes are single-beat (write_length = 1).
//
// Parameters  :
//   AddrWidth         - Width of the arbiter address bus (Default: 16)
//   DataWidth         - Width of the arbiter data bus (Default: 12)
//   SdramAddrWidth    - Width of the SDRAM controller address bus (Default: 25)
//   MaxBurstLen       - Maximum host burst length; legal 1, 2, 4, or 8 (Default: 8)
//   ScBl              - SDRAM controller burst length; must match sdram_controller
//   WrTurnaroundWait  - Host cycles after write FIFO drain before read (Default: 64)
//
// Dependencies:
//   - sdram_controller.sv (FIFO host interface)
//
// Revision History:
//   Current - Burst-8 SDRAM reads, single-beat writes (lowRISC port naming).
// ============================================================================

module sdram_arbiter_adapter #(
  parameter int unsigned AddrWidth        = 16,
  parameter int unsigned DataWidth        = 12,
  parameter int unsigned SdramAddrWidth   = 25,
  parameter int unsigned MaxBurstLen      = 8,
  parameter int unsigned ScBl             = 8,
  parameter logic [11:0] WrTurnaroundWait = 12'd64
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         arbiter_mem_req_i,
  input  logic                         arbiter_mem_write_i,
  input  logic [AddrWidth-1:0]         arbiter_mem_addr_i,
  input  logic [DataWidth-1:0]         arbiter_mem_write_data_i,
  input  logic [3:0]                   arbiter_mem_read_length_i,
  input  logic [3:0]                   arbiter_mem_write_length_i,
  output logic                         arbiter_mem_ready_o,
  output logic [DataWidth-1:0]         arbiter_mem_read_data_o,
  output logic                         arbiter_mem_read_data_valid_o,

  output logic [15:0]                    sdram_write_data_o,
  output logic                         sdram_write_request_o,
  output logic [SdramAddrWidth-1:0]    sdram_write_addr_o,
  output logic [8:0]                   sdram_write_length_o,
  output logic                         sdram_write_load_o,
  input  logic                         sdram_write_full_i,
  input  logic [15:0]                  sdram_write_used_i,

  input  logic [15:0]                  sdram_read_data_i,
  output logic                         sdram_read_request_o,
  output logic [SdramAddrWidth-1:0]    sdram_read_addr_o,
  output logic [8:0]                   sdram_read_length_o,
  output logic                         sdram_read_load_o,
  input  logic                         sdram_read_empty_i
);

  localparam logic [8:0] HostBurstLen = ScBl[8:0];
  localparam logic [8:0] ReadDisabled = 9'd0;

  typedef enum logic [4:0] {
    StIdle,
    StWrSync,
    StWrAckWait,
    StRdSync,
    StRdFlush,
    StRdFlushW,
    StRdStart,
    StRdWait,
    StRdPop,
    StRdSettle,
    StRdValid
  } adapter_state_e;

  localparam int unsigned WrAckTimeout = 16;

  adapter_state_e state_q;

  logic [11:0]              wr_drain_counter_q;
  logic [7:0]               wr_ack_counter_q;
  logic [AddrWidth-1:0]     expected_wr_addr_q;
  logic [AddrWidth-1:0]     expected_rd_addr_q;
  logic [AddrWidth-1:0]     read_burst_addr_q;
  logic                     wr_tracking_valid_q;
  logic                     rd_tracking_valid_q;
  logic                     writes_pending_q;
  logic [1:0]               read_settle_count_q;
  logic [3:0]               beats_remaining_q;

  logic _unused_wr_len;
  logic needs_write_turnaround;

  function automatic logic [3:0] clamp_burst_len(input logic [3:0] req_len);
    if (req_len < 4'd1 || req_len > MaxBurstLen[3:0])
      return 4'd1;
    else if (req_len != 4'd1 && req_len != 4'd2 && req_len != 4'd4 && req_len != 4'd8)
      return 4'd1;
    else
      return req_len;
  endfunction

  assign _unused_wr_len = |arbiter_mem_write_length_i;
  assign needs_write_turnaround = writes_pending_q || (sdram_write_used_i[8:0] != 9'd0);

  assign sdram_write_data_o = {{(16 - DataWidth){1'b0}}, arbiter_mem_write_data_i};
  assign sdram_write_addr_o = {{(SdramAddrWidth - AddrWidth){1'b0}}, arbiter_mem_addr_i};
  assign sdram_read_addr_o  = {{(SdramAddrWidth - AddrWidth){1'b0}}, read_burst_addr_q};
  assign arbiter_mem_read_data_o = sdram_read_data_i[DataWidth-1:0];

  initial begin
    if (MaxBurstLen != 1 && MaxBurstLen != 2 && MaxBurstLen != 4 && MaxBurstLen != 8)
      $display("ERROR: sdram_arbiter_adapter MaxBurstLen=%0d; legal values are 1, 2, 4, 8",
               MaxBurstLen);
    if (ScBl != 1 && ScBl != 2 && ScBl != 4 && ScBl != 8)
      $display("ERROR: sdram_arbiter_adapter ScBl=%0d; legal values are 1, 2, 4, 8", ScBl);
    if (MaxBurstLen < ScBl)
      $display("ERROR: sdram_arbiter_adapter MaxBurstLen (%0d) must be >= ScBl (%0d)",
               MaxBurstLen, ScBl);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                       <= StIdle;
      arbiter_mem_ready_o           <= 1'b0;
      arbiter_mem_read_data_valid_o <= 1'b0;
      sdram_write_request_o         <= 1'b0;
      sdram_write_load_o            <= 1'b0;
      sdram_write_length_o          <= 9'd1;
      sdram_read_request_o          <= 1'b0;
      sdram_read_load_o             <= 1'b0;
      sdram_read_length_o           <= ReadDisabled;
      expected_wr_addr_q            <= '0;
      expected_rd_addr_q            <= '0;
      read_burst_addr_q             <= '0;
      wr_tracking_valid_q           <= 1'b0;
      rd_tracking_valid_q           <= 1'b0;
      writes_pending_q              <= 1'b0;
      read_settle_count_q           <= 2'd0;
      wr_drain_counter_q            <= 12'd0;
      wr_ack_counter_q              <= 8'd0;
      beats_remaining_q             <= 4'd0;
    end else begin
      arbiter_mem_ready_o           <= 1'b0;
      arbiter_mem_read_data_valid_o <= 1'b0;
      sdram_write_request_o         <= 1'b0;
      sdram_write_load_o            <= 1'b0;
      sdram_read_request_o          <= 1'b0;
      sdram_read_load_o             <= 1'b0;

      case (state_q)
        StIdle: begin
          sdram_write_length_o <= 9'd1;
          sdram_read_length_o  <= ReadDisabled;

          if (arbiter_mem_req_i) begin
            if (arbiter_mem_write_i) begin
              sdram_read_length_o <= ReadDisabled;
              rd_tracking_valid_q <= 1'b0;

              if (wr_tracking_valid_q && (arbiter_mem_addr_i == expected_wr_addr_q)) begin
                if (!sdram_write_full_i) begin
                  sdram_write_length_o  <= 9'd1;
                  sdram_write_request_o <= 1'b1;
                  arbiter_mem_ready_o   <= 1'b1;
                  expected_wr_addr_q    <= arbiter_mem_addr_i + {{(AddrWidth-1){1'b0}}, 1'b1};
                  writes_pending_q      <= 1'b1;
                  wr_ack_counter_q      <= 8'd0;
                  state_q               <= StWrAckWait;
                end
              end else begin
                wr_drain_counter_q <= 12'd0;
                state_q            <= StWrSync;
              end
            end else begin
              sdram_write_length_o <= 9'd1;
              wr_tracking_valid_q  <= 1'b0;
              beats_remaining_q    <= clamp_burst_len(arbiter_mem_read_length_i);

              if (rd_tracking_valid_q && (arbiter_mem_addr_i == expected_rd_addr_q)) begin
                read_burst_addr_q <= arbiter_mem_addr_i;
                state_q           <= StRdFlush;
              end else begin
                rd_tracking_valid_q <= 1'b0;
                wr_drain_counter_q    <= 12'd0;
                if (needs_write_turnaround)
                  state_q <= StRdSync;
                else
                  state_q <= StRdFlush;
              end
            end
          end
        end

        StWrSync: begin
          if (sdram_write_used_i[8:0] == 9'd0) begin
            if (wr_drain_counter_q >= WrTurnaroundWait) begin
              wr_drain_counter_q <= 12'd0;
              if (!sdram_write_full_i) begin
                sdram_write_load_o    <= 1'b1;
                sdram_write_length_o  <= 9'd1;
                sdram_write_request_o <= 1'b1;
                arbiter_mem_ready_o   <= 1'b1;
                expected_wr_addr_q    <= arbiter_mem_addr_i + {{(AddrWidth-1){1'b0}}, 1'b1};
                wr_tracking_valid_q   <= 1'b1;
                writes_pending_q      <= 1'b1;
                wr_ack_counter_q      <= 8'd0;
                state_q               <= StWrAckWait;
              end
            end else begin
              wr_drain_counter_q <= wr_drain_counter_q + 12'd1;
            end
          end else begin
            wr_drain_counter_q <= 12'd0;
          end
        end

        StWrAckWait: begin
          if (!arbiter_mem_req_i) begin
            wr_ack_counter_q <= 8'd0;
            state_q          <= StIdle;
          end else if (wr_ack_counter_q >= WrAckTimeout[7:0]) begin
            wr_ack_counter_q    <= 8'd0;
            wr_tracking_valid_q <= 1'b0;
            state_q             <= StIdle;
          end else begin
            wr_ack_counter_q <= wr_ack_counter_q + 8'd1;
          end
        end

        StRdSync: begin
          if (sdram_write_used_i[8:0] == 9'd0) begin
            if (wr_drain_counter_q >= WrTurnaroundWait) begin
              wr_drain_counter_q <= 12'd0;
              writes_pending_q     <= 1'b0;
              state_q              <= StRdFlush;
            end else begin
              wr_drain_counter_q <= wr_drain_counter_q + 12'd1;
            end
          end else begin
            wr_drain_counter_q <= 12'd0;
          end
        end

        StRdFlush: begin
          if (!sdram_read_empty_i) begin
            sdram_read_request_o <= 1'b1;
            state_q              <= StRdFlushW;
          end else begin
            beats_remaining_q <= clamp_burst_len(arbiter_mem_read_length_i);
            read_burst_addr_q <= arbiter_mem_addr_i;
            state_q           <= StRdStart;
          end
        end

        StRdFlushW: begin
          state_q <= StRdFlush;
        end

        StRdStart: begin
          sdram_read_load_o    <= 1'b1;
          sdram_read_length_o  <= HostBurstLen;
          arbiter_mem_ready_o  <= 1'b1;
          expected_rd_addr_q   <= read_burst_addr_q + beats_remaining_q;
          rd_tracking_valid_q  <= 1'b1;
          state_q              <= StRdWait;
        end

        StRdWait: begin
          if (!sdram_read_empty_i) begin
            sdram_read_request_o <= 1'b1;
            read_settle_count_q  <= 2'd0;
            state_q              <= StRdSettle;
          end
        end

        StRdSettle: begin
          state_q <= StRdPop;
        end

        StRdPop: begin
          if (read_settle_count_q < 2'd2) begin
            read_settle_count_q <= read_settle_count_q + 2'd1;
          end else begin
            state_q <= StRdValid;
          end
        end

        StRdValid: begin
          arbiter_mem_read_data_valid_o <= 1'b1;
          if (beats_remaining_q <= 4'd1) begin
            sdram_read_length_o <= ReadDisabled;
            state_q             <= StIdle;
          end else begin
            beats_remaining_q <= beats_remaining_q - 4'd1;
            state_q           <= StRdWait;
          end
        end

        default: state_q <= StIdle;
      endcase
    end
  end

endmodule
