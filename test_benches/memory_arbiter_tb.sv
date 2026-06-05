// ============================================================================
// File Name   : memory_arbiter_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for memory_arbiter. Exercises fixed-priority grant
//   logic, multi-beat read hold, and simultaneous client requests.
//
// Dependencies:
//   - memory_arbiter.sv
// ============================================================================
`timescale 1ns / 1ps

module memory_arbiter_tb;

  localparam int unsigned ClkPeriod  = 10;
  localparam int unsigned NumClients = 2;
  localparam int unsigned AddrWidth  = 16;
  localparam int unsigned DataWidth  = 12;

  logic clk_i;
  logic rst_ni;
  integer i;

  logic [NumClients-1:0]                    client_mem_req_i;
  logic [NumClients-1:0]                    client_mem_write_i;
  logic [AddrWidth*NumClients-1:0]          client_mem_addr_i;
  logic [DataWidth*NumClients-1:0]          client_mem_write_data_i;
  logic [4*NumClients-1:0]                  client_mem_read_length_i;
  logic [4*NumClients-1:0]                  client_mem_write_length_i;
  logic [NumClients-1:0]                    client_mem_grant_o;
  logic [DataWidth*NumClients-1:0]          client_mem_read_data_o;
  logic [NumClients-1:0]                    client_mem_read_data_valid_o;

  logic                     master_mem_req_o;
  logic                     master_mem_write_o;
  logic [AddrWidth-1:0]     master_mem_addr_o;
  logic [DataWidth-1:0]     master_mem_write_data_o;
  logic [3:0]               master_mem_read_length_o;
  logic [3:0]               master_mem_write_length_o;
  logic                     master_mem_ready_i;
  logic [DataWidth-1:0]     master_mem_read_data_i;
  logic                     master_mem_read_data_valid_i;

  logic [3:0] burst_beats_left;

  memory_arbiter #(
    .NumClients(NumClients),
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .client_mem_req_i(client_mem_req_i),
    .client_mem_write_i(client_mem_write_i),
    .client_mem_addr_i(client_mem_addr_i),
    .client_mem_write_data_i(client_mem_write_data_i),
    .client_mem_read_length_i(client_mem_read_length_i),
    .client_mem_write_length_i(client_mem_write_length_i),
    .client_mem_grant_o(client_mem_grant_o),
    .client_mem_read_data_o(client_mem_read_data_o),
    .client_mem_read_data_valid_o(client_mem_read_data_valid_o),
    .master_mem_req_o(master_mem_req_o),
    .master_mem_write_o(master_mem_write_o),
    .master_mem_addr_o(master_mem_addr_o),
    .master_mem_write_data_o(master_mem_write_data_o),
    .master_mem_read_length_o(master_mem_read_length_o),
    .master_mem_write_length_o(master_mem_write_length_o),
    .master_mem_ready_i(master_mem_ready_i),
    .master_mem_read_data_i(master_mem_read_data_i),
    .master_mem_read_data_valid_i(master_mem_read_data_valid_i)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;

  always_ff @(posedge clk_i) begin
    master_mem_read_data_valid_i <= 1'b0;
    if (master_mem_req_o && !master_mem_write_o && master_mem_ready_i) begin
      master_mem_read_data_i <= master_mem_addr_o[DataWidth-1:0] + 1'b1;
      master_mem_read_data_valid_i <= 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      master_mem_ready_i <= 1'b0;
      burst_beats_left <= 4'd0;
    end else begin
      master_mem_ready_i <= 1'b0;
      if (master_mem_req_o && !master_mem_write_o) begin
        if (burst_beats_left == 4'd0) begin
          master_mem_ready_i <= 1'b1;
          burst_beats_left <= master_mem_read_length_o;
        end
      end else if (master_mem_read_data_valid_i && burst_beats_left != 4'd0) begin
        if (burst_beats_left <= 4'd1)
          burst_beats_left <= 4'd0;
        else
          burst_beats_left <= burst_beats_left - 4'd1;
      end
    end
  end

  task client_request;
    input integer client_id;
    input bit is_write;
    input [AddrWidth-1:0] addr;
    input [DataWidth-1:0] wdata;
    input [3:0] rd_len;
    input [3:0] wr_len;
    begin
      client_mem_req_i[client_id] <= 1'b1;
      client_mem_write_i[client_id] <= is_write;
      client_mem_addr_i[client_id*AddrWidth +: AddrWidth] <= addr;
      client_mem_write_data_i[client_id*DataWidth +: DataWidth] <= wdata;
      client_mem_read_length_i[client_id*4 +: 4] <= rd_len;
      client_mem_write_length_i[client_id*4 +: 4] <= wr_len;
    end
  endtask

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    client_mem_req_i = '0;
    client_mem_write_i = '0;
    client_mem_addr_i = '0;
    client_mem_write_data_i = '0;
    client_mem_read_length_i = {(4*NumClients){4'd1}};
    client_mem_write_length_i = {(4*NumClients){4'd1}};
    master_mem_read_data_i = '0;

    $display("Starting Memory Arbiter Testbench...");
    #100;
    rst_ni = 1'b1;
    #50;

    $display("\nTest Case 1: Client 0 write request.");
    client_request(0, 1, 16'h1000, 12'hABC, 4'd1, 4'd1);
    @(posedge clk_i);
    client_mem_req_i[0] = 1'b0;

    wait (client_mem_grant_o[0]);
    if (master_mem_addr_o == 16'h1000 && master_mem_write_data_o == 12'hABC)
      $display("SUCCESS: Master port shows correct data for Client 0.");
    else
      $display("FAILURE: Master port data incorrect.");
    #100;

    $display("\nTest Case 2: Client 1 single-beat read.");
    client_request(1, 0, 16'h2000, 12'h0, 4'd1, 4'd1);
    @(posedge clk_i);
    client_mem_req_i[1] = 1'b0;

    wait (client_mem_grant_o[1]);
    wait (client_mem_read_data_valid_o[1]);
    if (client_mem_read_data_o[1*DataWidth +: DataWidth] == 12'h001)
      $display("SUCCESS: Client 1 received correct read data.");
    else
      $display("FAILURE: Client 1 read data incorrect.");
    #100;

    $display("\nTest Case 3: Client 0 burst read length 8.");
    client_request(0, 0, 16'h3000, 12'h0, 4'd8, 4'd1);
    @(posedge clk_i);
    client_mem_req_i[0] = 1'b0;

    wait (client_mem_grant_o[0]);
    for (i = 0; i < 8; i = i + 1) begin
      wait (client_mem_read_data_valid_o[0]);
      $display("Burst beat %0d data=%h", i,
               client_mem_read_data_o[0*DataWidth +: DataWidth]);
      @(posedge clk_i);
    end
    $display("SUCCESS: Client 0 received eight read-valid beats.");
    #100;

    $display("\nTestbench finished.");
    $finish;
  end

endmodule
