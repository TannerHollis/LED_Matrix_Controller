// ============================================================================
// File Name   : command_processor_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for command_processor. Drives SPI command bytes and
//   a mock memory arbiter to verify write, read, and flip-buffer handling.
//
// Dependencies:
//   - command_processor.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style migration.
// ============================================================================
`timescale 1ns / 1ps

module command_processor_tb;

  localparam int unsigned ClkPeriod   = 10;
  localparam int unsigned TotalWidth  = 32;
  localparam int unsigned TotalHeight = 32;
  localparam int unsigned ColorDepth  = 4;
  localparam int unsigned CmdWidth    = 8;
  localparam int unsigned AddrWidth   = $clog2(TotalWidth * TotalHeight);
  localparam int unsigned DataWidth   = ColorDepth * 3;

  logic clk_i;
  logic rst_ni;

  logic [CmdWidth-1:0] spi_data_in_i;
  logic                spi_data_valid_i;

  logic frame_ready_o;

  logic                                mem_req_o;
  logic                                mem_write_o;
  logic [3:0]                          mem_read_length_o;
  logic [3:0]                          mem_write_length_o;
  logic [AddrWidth-1:0]                mem_addr_o;
  logic [DataWidth-1:0]                mem_write_data_o;
  logic                                mem_grant_i;
  logic [DataWidth-1:0]                mem_read_data_i;
  logic                                mem_read_data_valid_i;
  logic [DataWidth-1:0]                read_data_out_o;
  logic                                read_data_valid_o;

  command_processor #(
    .TotalWidth(TotalWidth),
    .TotalHeight(TotalHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_data_in_i(spi_data_in_i),
    .spi_data_valid_i(spi_data_valid_i),
    .frame_ready_o(frame_ready_o),
    .mem_req_o(mem_req_o),
    .mem_write_o(mem_write_o),
    .mem_read_length_o(mem_read_length_o),
    .mem_write_length_o(mem_write_length_o),
    .mem_addr_o(mem_addr_o),
    .mem_write_data_o(mem_write_data_o),
    .mem_grant_i(mem_grant_i),
    .mem_read_data_i(mem_read_data_i),
    .mem_read_data_valid_i(mem_read_data_valid_i),
    .read_data_out_o(read_data_out_o),
    .read_data_valid_o(read_data_valid_o)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;

  task send_byte;
    input [CmdWidth-1:0] byte_to_send;
    begin
      spi_data_in_i <= byte_to_send;
      spi_data_valid_i <= 1'b1;
      @(posedge clk_i);
      spi_data_valid_i <= 1'b0;
    end
  endtask

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    spi_data_in_i = '0;
    spi_data_valid_i = 1'b0;
    mem_grant_i = 1'b0;
    mem_read_data_i = '0;
    mem_read_data_valid_i = 1'b0;

    $display("Starting Command Processor Testbench...");
    #100;
    rst_ni = 1'b1;
    #50;

    $display("\nTest Case 1: Sending CMD_FLIP_BUFFER (0x02)");
    send_byte(8'h02);
    wait (frame_ready_o);
    $display("SUCCESS: frame_ready_o signal pulsed.");
    @(negedge frame_ready_o);
    #100;

    $display("\nTest Case 2: Sending CMD_WRITE_PIXEL (0x01) with multi-byte address/data");
    send_byte(8'h01);
    @(posedge clk_i);
    send_byte(8'h35);
    @(posedge clk_i);
    send_byte(8'h12);
    @(posedge clk_i);
    send_byte(8'hCD);
    @(posedge clk_i);
    send_byte(8'hAB);

    wait (mem_req_o);
    $display("DUT has requested memory access.");

    if (mem_write_o && mem_addr_o == 16'h1235 && mem_write_data_o == 16'hABCD) begin
      $display("SUCCESS: Correct memory write request. Addr: %h, Data: %h",
               mem_addr_o, mem_write_data_o);
    end else begin
      $display("FAILURE: Incorrect memory write request. Addr: %h, Data: %h",
               mem_addr_o, mem_write_data_o);
    end

    @(posedge clk_i);
    mem_grant_i <= 1'b1;
    @(posedge clk_i);
    mem_grant_i <= 1'b0;

    if (!mem_req_o) begin
      $display("SUCCESS: mem_req_o was de-asserted after grant.");
    end else begin
      $display("FAILURE: mem_req_o was not de-asserted after grant.");
    end

    #100;

    $display("\nTest Case 3: Sending CMD_READ_PIXEL (0x03)");
    send_byte(8'h03);
    @(posedge clk_i);
    send_byte(8'h42);
    @(posedge clk_i);
    send_byte(8'h34);

    wait (mem_req_o);
    $display("DUT has requested memory read access.");

    if (!mem_write_o && mem_addr_o == 16'h3442) begin
      $display("SUCCESS: Correct memory read request. Addr: %h", mem_addr_o);
    end else begin
      $display("FAILURE: Incorrect memory read request. Addr: %h, Write: %b",
               mem_addr_o, mem_write_o);
    end

    @(posedge clk_i);
    mem_grant_i <= 1'b1;
    mem_read_data_i <= 16'hDEAD;
    mem_read_data_valid_i <= 1'b1;
    @(posedge clk_i);
    mem_grant_i <= 1'b0;
    mem_read_data_valid_i <= 1'b0;

    wait (read_data_valid_o);
    if (read_data_out_o == 16'hDEAD) begin
      $display("SUCCESS: read_data_out_o returned expected pixel data.");
    end else begin
      $display("FAILURE: read_data_out_o mismatch. Got: %h", read_data_out_o);
    end

    if (!mem_req_o) begin
      $display("SUCCESS: mem_req_o was de-asserted after read grant.");
    end else begin
      $display("FAILURE: mem_req_o was not de-asserted after read grant.");
    end

    #100;

    $display("\nTest Case 4: Sending invalid command (0xFF)");
    send_byte(8'hFF);

    #200;
    if (!mem_req_o) begin
      $display("SUCCESS: Invalid command was ignored correctly.");
    end else begin
      $display("FAILURE: Invalid command generated memory request.");
    end

    #100;

    $display("\nTest Case 5: Testing frame_ready_o signal");
    send_byte(8'h02);
    wait (frame_ready_o);
    $display("SUCCESS: frame_ready_o asserted for flip command.");
    @(negedge frame_ready_o);
    #100;

    $display("\nTestbench finished.");
    $finish;
  end

endmodule
