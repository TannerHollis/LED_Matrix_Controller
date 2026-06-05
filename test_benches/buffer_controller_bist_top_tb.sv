// ============================================================================
// File Name   : buffer_controller_bist_top_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation smoke test for buffer_controller_bist_top. Uses a narrow row
//   width and few swap rounds for fast regression in ModelSim/Questa.
//
// Parameters  :
//   TotalRowWidth - Pixels per row in the DUT (Default: 64)
//   SwapRounds    - Ping-pong swap rounds to exercise (Default: 4)
//   ClkPeriod     - 50 MHz clock period in ns (Default: 20)
//
// Dependencies:
//   - verification/buffer_controller/buffer_controller_bist_top.sv
// ============================================================================

`timescale 1ns / 1ps

module buffer_controller_bist_top_tb;

  localparam int unsigned TotalRowWidth = 64;
  localparam int unsigned SwapRounds    = 4;
  localparam int unsigned ClkPeriod     = 20;

  logic clk_50mhz;
  logic btn_start;
  logic btn_reset;

  logic led_status;

  buffer_controller_bist_top #(
    .TotalRowWidth(TotalRowWidth),
    .SwapRounds(SwapRounds)
  ) dut (
    .clk_50mhz(clk_50mhz),
    .btn_start(btn_start),
    .btn_reset(btn_reset),
    .led_status(led_status)
  );

  initial clk_50mhz = 1'b0;
  always #(ClkPeriod / 2) clk_50mhz = ~clk_50mhz;

  initial begin
    btn_start = 1'b0;
    btn_reset = 1'b0;
    #(ClkPeriod * 4);
    btn_reset = 1'b1;

    #(ClkPeriod * 2);
    btn_start = 1'b1;
    #(ClkPeriod * 4);
    btn_start = 1'b0;

    wait (dut.bist_done || dut.fail_latched);
    #(ClkPeriod * 4);

    if (dut.fail_latched) begin
      $display("FAIL: buffer_controller BIST latched failure (swap_count=%0d)",
               dut.swap_count);
      $fatal(1);
    end else begin
      $display("PASS: buffer_controller BIST completed (swap_count=%0d)",
               dut.swap_count);
    end

    $finish;
  end

  initial begin
    #(ClkPeriod * 2000000);
    $display("TIMEOUT: swap_count=%0d fail=%0b done=%0b",
             dut.swap_count, dut.fail_latched, dut.bist_done);
    $fatal(1);
  end

endmodule
