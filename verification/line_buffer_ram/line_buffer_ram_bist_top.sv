// ============================================================================
// File Name   : line_buffer_ram_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for line_buffer_ram on the DE2-115. Exercises M9K
//   inference, synchronous read latency, full-depth write/read verify, and
//   read-old-then-write-new on each address (panel line-buffer pattern).
//
// Parameters  :
//   DATA_WIDTH   - RAM data width (Default: 12)
//   DEPTH        - Number of line slots / entries (Default: 768 = production row)
//   ADDR_WIDTH   - Derived from DEPTH when zero (Default: $clog2(DEPTH))
//
// Dependencies:
//   - line_buffer_ram.sv
// ============================================================================
// Revision History:
//   Current - line_buffer_ram fill/verify/rewrite BIST.
// ============================================================================

module line_buffer_ram_bist_top #(
  parameter int unsigned DataWidth = 12,
  parameter int unsigned Depth     = 768,
  parameter int unsigned AddrWidth = 0
) (
  input  logic clk_50mhz,
  input  logic btn_start,
  input  logic btn_reset,
  output logic led_status
);

  typedef enum logic [3:0] {
    StIdle,
    StWr,
    StRdLaunch,
    StRdWait,
    StRdSample,
    StRw,
    StRwWait,
    StRwSample
  } bist_state_e;

  typedef enum logic [1:0] {
    PhaseFill,
    PhaseVerify,
    PhaseRewrite,
    PhaseAlt
  } test_phase_e;

  localparam int unsigned RamAddrWidth = (AddrWidth > 0) ? AddrWidth :
                                         ((Depth <= 1) ? 1 : $clog2(Depth));
  localparam logic [RamAddrWidth-1:0] LastAddr = Depth - 1;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  bist_state_e state;
  test_phase_e test_phase;
  logic [RamAddrWidth-1:0] curr_addr;
  logic [24:0]             blink_counter;
  logic                    bist_done;
  logic                    fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic [DataWidth-1:0]      wr_data;
  logic [RamAddrWidth-1:0]   wr_addr;
  logic                      wr_en;
  logic [RamAddrWidth-1:0]   rd_addr;
  logic [DataWidth-1:0]      rd_data;

  function automatic logic [DataWidth-1:0] mem_pattern(input logic [RamAddrWidth-1:0] addr_in);
    logic [15:0] full_pat;
    full_pat    = {16'h0000 | addr_in[RamAddrWidth-1:0]} ^ 16'hA5C3;
    mem_pattern = full_pat[DataWidth-1:0];
  endfunction

  function automatic logic [DataWidth-1:0] alt_pattern(input logic [RamAddrWidth-1:0] addr_in);
    alt_pattern = mem_pattern(addr_in ^ {{(RamAddrWidth-1){1'b0}}, 1'b1});
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
      state         <= StIdle;
      test_phase    <= PhaseFill;
      curr_addr     <= {RamAddrWidth{1'b0}};
      blink_counter <= 25'd0;
      bist_done     <= 1'b0;
      fail_latched  <= 1'b0;
      led_status    <= 1'b1;
      wr_data       <= {DataWidth{1'b0}};
      wr_addr       <= {RamAddrWidth{1'b0}};
      wr_en         <= 1'b0;
      rd_addr       <= {RamAddrWidth{1'b0}};
    end else begin
      blink_counter <= blink_counter + 25'd1;
      wr_en         <= 1'b0;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          if (start_event) begin
            test_phase   <= PhaseFill;
            curr_addr    <= {RamAddrWidth{1'b0}};
            bist_done    <= 1'b0;
            fail_latched <= 1'b0;
            state        <= StWr;
          end
        end

        StWr: begin
          wr_en   <= 1'b1;
          wr_addr <= curr_addr;
          wr_data <= mem_pattern(curr_addr);
          if (curr_addr == LastAddr) begin
            curr_addr  <= {RamAddrWidth{1'b0}};
            test_phase <= PhaseVerify;
            state      <= StRdLaunch;
          end else begin
            curr_addr <= curr_addr + {{(RamAddrWidth-1){1'b0}}, 1'b1};
          end
        end

        StRdLaunch: begin
          rd_addr <= curr_addr;
          state   <= StRdWait;
        end

        StRdWait: begin
          state <= StRdSample;
        end

        StRdSample: begin
          if (test_phase == PhaseVerify) begin
            if (rd_data != mem_pattern(curr_addr))
              fail_latched <= 1'b1;
          end else begin
            if (rd_data != alt_pattern(curr_addr))
              fail_latched <= 1'b1;
          end

          if (curr_addr == LastAddr) begin
            curr_addr <= {RamAddrWidth{1'b0}};
            if (test_phase == PhaseVerify) begin
              test_phase <= PhaseRewrite;
              state      <= StRw;
            end else if (!fail_latched &&
                         (test_phase == PhaseAlt) &&
                         (rd_data == alt_pattern(curr_addr))) begin
              bist_done <= 1'b1;
              state     <= StIdle;
            end else begin
              state <= StIdle;
            end
          end else begin
            curr_addr <= curr_addr + {{(RamAddrWidth-1){1'b0}}, 1'b1};
            state     <= StRdLaunch;
          end
        end

        StRw: begin
          rd_addr <= curr_addr;
          state   <= StRwWait;
        end

        StRwWait: begin
          state <= StRwSample;
        end

        StRwSample: begin
          if (rd_data != mem_pattern(curr_addr))
            fail_latched <= 1'b1;
          wr_en   <= 1'b1;
          wr_addr <= curr_addr;
          wr_data <= alt_pattern(curr_addr);
          if (curr_addr == LastAddr) begin
            curr_addr  <= {RamAddrWidth{1'b0}};
            test_phase <= PhaseAlt;
            state      <= StRdLaunch;
          end else begin
            curr_addr <= curr_addr + {{(RamAddrWidth-1){1'b0}}, 1'b1};
            state     <= StRw;
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  line_buffer_ram #(
    .DataWidth(DataWidth),
    .AddrWidth(RamAddrWidth),
    .Depth(Depth)
  ) dut_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .wr_data_i(wr_data),
    .wr_addr_i(wr_addr),
    .wr_en_i(wr_en),
    .rd_addr_i(rd_addr),
    .rd_data_o(rd_data)
  );

endmodule
