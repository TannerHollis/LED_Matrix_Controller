// ============================================================================
// File Name   : spi_slave_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top for spi_slave only. An internal synthetic SPI master drives
//   MOSI, SCLK, and CS_N into spi_slave, then checks data_out/data_valid for a
//   scripted byte sequence and a partial-byte negative test.
//
// Parameters  :
//   Width                  - SPI word width in bits (Default: 8)
//   SpiHalfPeriodCycles    - Half SCLK period in clk cycles (Default: 8)
//   OpWaitTimeout          - Timeout in clk cycles (Default: 24'd1_000_000)
//
// Dependencies:
//   - spi_slave.sv
// ============================================================================
// Revision History:
//   Current - Internal SPI master exercising spi_slave byte reception.
// ============================================================================

module spi_slave_bist_top #(
  parameter int unsigned Width                = 8,
  parameter int unsigned SpiHalfPeriodCycles  = 8,
  parameter int unsigned OpWaitTimeout        = 24'd1_000_000
) (
  input  logic clk_50mhz,
  input  logic btn_start,
  input  logic btn_reset,
  output logic led_status
);

  localparam int unsigned ByteCount      = 4;
  localparam int unsigned ByteIndexWidth  = 3;
  localparam int unsigned BitIndexWidth  = (Width <= 1) ? 1 : $clog2(Width);
  localparam int unsigned HalfPeriodWidth = (SpiHalfPeriodCycles <= 1) ?
                                            1 : $clog2(SpiHalfPeriodCycles + 1);

  typedef enum logic [3:0] {
    StIdle,
    StBeginByte,
    StSetupBit,
    StSclkHigh,
    StSclkLow,
    StFinishByte,
    StWaitValid,
    StCheckValidLow,
    StBeginPartial,
    StPartialSetup,
    StPartialHigh,
    StPartialLow,
    StPartialDone
  } bist_state_e;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  bist_state_e state;
  logic [23:0] wait_counter;
  logic [24:0] blink_counter;
  logic        bist_done;
  logic        fail_latched;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic             spi_sclk;
  logic             spi_cs_n;
  logic             spi_mosi;
  logic [Width-1:0] data_out;
  logic             data_valid;
  logic             prev_data_valid;

  logic [ByteIndexWidth-1:0] byte_index;
  logic [BitIndexWidth-1:0]  bit_index;
  logic [HalfPeriodWidth-1:0] half_counter;
  logic [2:0]                partial_bit_count;
  logic                      byte_valid_seen;
  logic                      seen_partial_valid;
  logic [Width-1:0]          current_expected_byte;

  function automatic logic [Width-1:0] expected_byte(input logic [ByteIndexWidth-1:0] index_in);
    case (index_in)
      3'd0: expected_byte = 8'hA5;
      3'd1: expected_byte = 8'h5A;
      3'd2: expected_byte = 8'hC3;
      3'd3: expected_byte = 8'h3C;
      default: expected_byte = {Width{1'b0}};
    endcase
  endfunction

  assign current_expected_byte = expected_byte(byte_index);

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
      state              <= StIdle;
      wait_counter       <= 24'd0;
      blink_counter      <= 25'd0;
      bist_done          <= 1'b0;
      fail_latched       <= 1'b0;
      led_status         <= 1'b1;
      spi_sclk           <= 1'b0;
      spi_cs_n           <= 1'b1;
      spi_mosi           <= 1'b0;
      prev_data_valid    <= 1'b0;
      byte_index         <= {ByteIndexWidth{1'b0}};
      bit_index          <= {BitIndexWidth{1'b0}};
      half_counter       <= {HalfPeriodWidth{1'b0}};
      partial_bit_count  <= 3'd0;
      byte_valid_seen    <= 1'b0;
      seen_partial_valid <= 1'b0;
    end else begin
      blink_counter   <= blink_counter + 25'd1;
      prev_data_valid <= data_valid;

      if (fail_latched)          led_status <= ~blink_counter[24];
      else if (state != StIdle)  led_status <= ~blink_counter[21];
      else if (bist_done)        led_status <= 1'b0;
      else                       led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          spi_sclk     <= 1'b0;
          spi_cs_n     <= 1'b1;
          spi_mosi     <= 1'b0;
          wait_counter <= 24'd0;
          if (start_event) begin
            bist_done          <= 1'b0;
            fail_latched       <= 1'b0;
            byte_index         <= {ByteIndexWidth{1'b0}};
            bit_index          <= Width - 1;
            half_counter       <= {HalfPeriodWidth{1'b0}};
            partial_bit_count  <= 3'd0;
            byte_valid_seen    <= 1'b0;
            seen_partial_valid <= 1'b0;
            state              <= StBeginByte;
          end
        end

        StBeginByte: begin
          spi_cs_n        <= 1'b0;
          spi_sclk        <= 1'b0;
          bit_index       <= Width - 1;
          byte_valid_seen <= 1'b0;
          half_counter    <= {HalfPeriodWidth{1'b0}};
          state           <= StSetupBit;
        end

        StSetupBit: begin
          spi_sclk <= 1'b0;
          spi_mosi <= current_expected_byte[bit_index];
          if (data_valid) begin
            if (byte_valid_seen || data_out != current_expected_byte)
              fail_latched <= 1'b1;
            byte_valid_seen <= 1'b1;
          end
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {HalfPeriodWidth{1'b0}};
            state        <= StSclkHigh;
          end else begin
            half_counter <= half_counter + {{(HalfPeriodWidth-1){1'b0}}, 1'b1};
          end
        end

        StSclkHigh: begin
          spi_sclk <= 1'b1;
          if (data_valid) begin
            if (byte_valid_seen || data_out != current_expected_byte)
              fail_latched <= 1'b1;
            byte_valid_seen <= 1'b1;
          end
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {HalfPeriodWidth{1'b0}};
            state        <= StSclkLow;
          end else begin
            half_counter <= half_counter + {{(HalfPeriodWidth-1){1'b0}}, 1'b1};
          end
        end

        StSclkLow: begin
          spi_sclk <= 1'b0;
          if (data_valid) begin
            if (byte_valid_seen || data_out != current_expected_byte)
              fail_latched <= 1'b1;
            byte_valid_seen <= 1'b1;
          end
          if (bit_index == {BitIndexWidth{1'b0}}) begin
            state <= StFinishByte;
          end else begin
            bit_index <= bit_index - {{(BitIndexWidth-1){1'b0}}, 1'b1};
            state     <= StSetupBit;
          end
        end

        StFinishByte: begin
          spi_sclk     <= 1'b0;
          wait_counter <= 24'd0;
          state        <= StWaitValid;
        end

        StWaitValid: begin
          if (data_valid) begin
            if (byte_valid_seen || data_out != current_expected_byte)
              fail_latched <= 1'b1;
            byte_valid_seen <= 1'b1;
            wait_counter    <= 24'd0;
            state           <= StCheckValidLow;
          end else if (byte_valid_seen) begin
            wait_counter <= 24'd0;
            state        <= StCheckValidLow;
          end else if (wait_counter >= OpWaitTimeout) begin
            fail_latched <= 1'b1;
            bist_done    <= 1'b1;
            state        <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        StCheckValidLow: begin
          if (data_valid && prev_data_valid)
            fail_latched <= 1'b1;

          if (byte_index == ByteCount - 1) begin
            spi_cs_n           <= 1'b1;
            byte_index         <= {ByteIndexWidth{1'b0}};
            partial_bit_count  <= 3'd0;
            byte_valid_seen    <= 1'b0;
            seen_partial_valid <= 1'b0;
            state              <= StBeginPartial;
          end else begin
            byte_index <= byte_index + {{(ByteIndexWidth-1){1'b0}}, 1'b1};
            state      <= StBeginByte;
          end
        end

        StBeginPartial: begin
          spi_cs_n           <= 1'b0;
          spi_sclk           <= 1'b0;
          spi_mosi           <= 1'b1;
          partial_bit_count  <= 3'd0;
          seen_partial_valid <= 1'b0;
          half_counter       <= {HalfPeriodWidth{1'b0}};
          wait_counter       <= 24'd0;
          state              <= StPartialSetup;
        end

        StPartialSetup: begin
          spi_sclk <= 1'b0;
          spi_mosi <= ~partial_bit_count[0];
          if (data_valid)
            seen_partial_valid <= 1'b1;
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {HalfPeriodWidth{1'b0}};
            state        <= StPartialHigh;
          end else begin
            half_counter <= half_counter + {{(HalfPeriodWidth-1){1'b0}}, 1'b1};
          end
        end

        StPartialHigh: begin
          spi_sclk <= 1'b1;
          if (data_valid)
            seen_partial_valid <= 1'b1;
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {HalfPeriodWidth{1'b0}};
            state        <= StPartialLow;
          end else begin
            half_counter <= half_counter + {{(HalfPeriodWidth-1){1'b0}}, 1'b1};
          end
        end

        StPartialLow: begin
          spi_sclk <= 1'b0;
          if (data_valid)
            seen_partial_valid <= 1'b1;
          if (partial_bit_count == 3'd3) begin
            spi_cs_n     <= 1'b1;
            wait_counter <= 24'd0;
            state        <= StPartialDone;
          end else begin
            partial_bit_count <= partial_bit_count + 3'd1;
            state             <= StPartialSetup;
          end
        end

        StPartialDone: begin
          if (data_valid)
            seen_partial_valid <= 1'b1;

          if (wait_counter == 24'd16) begin
            if (seen_partial_valid)
              fail_latched <= 1'b1;
            bist_done <= 1'b1;
            state     <= StIdle;
          end else begin
            wait_counter <= wait_counter + 24'd1;
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  spi_slave #(
    .Width(Width)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_sclk_i(spi_sclk),
    .spi_cs_ni(spi_cs_n),
    .spi_mosi_i(spi_mosi),
    .data_o(data_out),
    .data_valid_o(data_valid)
  );

endmodule
