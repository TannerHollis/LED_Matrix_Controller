// ============================================================================
// File Name   : spi_slave_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for spi_slave. Drives SPI mode-0 byte transfers and
//   checks parallel data_o / data_valid_o handshaking.
//
// Dependencies:
//   - spi_slave.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style migration.
// ============================================================================
`timescale 1ns / 1ps

module spi_slave_tb;

  localparam int unsigned ClkPeriod      = 10;
  localparam int unsigned SpiSclkPeriod  = 40;
  localparam int unsigned Width          = 8;

  logic clk_i;
  logic rst_ni;
  logic spi_sclk_i;
  logic spi_cs_ni;
  logic spi_mosi_i;

  logic [Width-1:0] data_o;
  logic             data_valid_o;

  spi_slave #(
    .Width(Width)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_sclk_i(spi_sclk_i),
    .spi_cs_ni(spi_cs_ni),
    .spi_mosi_i(spi_mosi_i),
    .data_o(data_o),
    .data_valid_o(data_valid_o)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;
  always #(SpiSclkPeriod / 2) spi_sclk_i = ~spi_sclk_i;

  task send_spi_byte;
    input [Width-1:0] byte_to_send;
    integer i;
    begin
      spi_cs_ni = 1'b0;
      #10;
      for (i = Width - 1; i >= 0; i = i - 1) begin
        spi_mosi_i = byte_to_send[i];
        #(SpiSclkPeriod);
      end
      #10;
      spi_cs_ni = 1'b1;
      spi_mosi_i = 1'b0;
      #10;
    end
  endtask

  initial begin
    clk_i = 1'b0;
    spi_sclk_i = 1'b0;
    spi_cs_ni = 1'b1;
    spi_mosi_i = 1'b0;
    rst_ni = 1'b0;

    $display("Starting SPI Slave Testbench...");

    #100;
    rst_ni = 1'b1;
    #50;

    $display("Test Case 1: Sending byte 0xA5");
    send_spi_byte(8'hA5);

    wait (data_valid_o);
    if (data_o == 8'hA5) begin
      $display("SUCCESS: Received 0x%h as expected.", data_o);
    end else begin
      $display("FAILURE: Received 0x%h, expected 0xA5.", data_o);
    end
    @(negedge data_valid_o);

    #100;

    $display("Test Case 2: Sending multiple bytes 0xB6, 0xC7");
    spi_cs_ni = 1'b0;
    #10;
    send_spi_byte(8'hB6);
    wait (data_valid_o);
    if (data_o == 8'hB6) begin
      $display("SUCCESS: Received 0x%h as expected.", data_o);
    end else begin
      $display("FAILURE: Received 0x%h, expected 0xB6.", data_o);
    end
    @(negedge data_valid_o);

    send_spi_byte(8'hC7);
    wait (data_valid_o);
    if (data_o == 8'hC7) begin
      $display("SUCCESS: Received 0x%h as expected.", data_o);
    end else begin
      $display("FAILURE: Received 0x%h, expected 0xC7.", data_o);
    end
    @(negedge data_valid_o);

    spi_cs_ni = 1'b1;
    #100;

    $display("Test Case 3: Testing edge cases and timing");

    spi_cs_ni = 1'b0;
    #5;
    spi_cs_ni = 1'b1;
    #10;

    spi_cs_ni = 1'b0;
    #10;
    spi_mosi_i = 1'b1;
    #(SpiSclkPeriod / 2);
    spi_mosi_i = 1'b0;
    #(SpiSclkPeriod / 2);
    spi_cs_ni = 1'b1;
    #10;

    spi_cs_ni = 1'b0;
    #10;
    for (integer j = 0; j < 4; j = j + 1) begin
      spi_mosi_i = j[0];
      #(SpiSclkPeriod / 4);
    end
    spi_cs_ni = 1'b1;
    #100;

    if (!data_valid_o) begin
      $display("SUCCESS: Invalid timing was handled correctly.");
    end else begin
      $display("FAILURE: Invalid timing produced valid data.");
    end

    $display("Test Case 4: Testing reset behavior");
    rst_ni = 1'b0;
    #50;
    rst_ni = 1'b1;
    #50;

    send_spi_byte(8'h55);
    wait (data_valid_o);
    if (data_o == 8'h55) begin
      $display("SUCCESS: Reset and recovery working correctly.");
    end else begin
      $display("FAILURE: Reset recovery failed.");
    end
    @(negedge data_valid_o);

    $display("Testbench finished.");
    $finish;
  end

endmodule
