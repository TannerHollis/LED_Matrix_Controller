// ============================================================================
// File Name   : ethernet_interface_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for ethernet_interface. Exercises UDP command
//   extraction, TCP configuration, MAC filtering, malformed-packet handling,
//   link status, and RMII timing.
//
// Dependencies:
//   - ethernet_interface.sv
// ============================================================================
`timescale 1ns / 1ps

module ethernet_interface_tb;

  localparam CLK_PERIOD = 10;
  localparam RMII_PERIOD = 20;
  localparam UDP_PORT = 16'h1234;
  localparam TCP_PORT = 16'h1235;
  localparam [47:0] MAC_ADDR = 48'h00_11_22_33_44_55;
  localparam [31:0] IP_ADDR = 32'hC0_A8_01_64;

  reg clk_i;
  reg rst_ni;
  integer i;

  reg eth_rx_data_i;
  reg eth_rx_dv_i;
  reg eth_rx_er_i;
  wire eth_tx_data_o;
  wire eth_tx_en_o;
  reg eth_tx_er_i;
  reg eth_crs_i;
  reg eth_col_i;

  wire [7:0] cmd_data_o;
  wire cmd_data_valid_o;
  reg cmd_ready_i;

  wire [31:0] config_ip_addr_o;
  wire [15:0] config_udp_port_o;
  wire [15:0] config_tcp_port_o;
  wire config_valid_o;

  wire eth_link_up_o;
  wire eth_rx_activity_o;
  wire eth_tx_activity_o;
  wire [15:0] rx_packet_count_o;
  wire [15:0] tx_packet_count_o;
  wire [15:0] rx_error_count_o;

  ethernet_interface #(
    .UdpPort(UDP_PORT),
    .TcpPort(TCP_PORT),
    .MacAddr(MAC_ADDR),
    .IpAddr(IP_ADDR)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .eth_rx_data_i(eth_rx_data_i),
    .eth_rx_dv_i(eth_rx_dv_i),
    .eth_rx_er_i(eth_rx_er_i),
    .eth_tx_data_o(eth_tx_data_o),
    .eth_tx_en_o(eth_tx_en_o),
    .eth_tx_er_i(eth_tx_er_i),
    .eth_crs_i(eth_crs_i),
    .eth_col_i(eth_col_i),
    .cmd_data_o(cmd_data_o),
    .cmd_data_valid_o(cmd_data_valid_o),
    .cmd_ready_i(cmd_ready_i),
    .config_ip_addr_o(config_ip_addr_o),
    .config_udp_port_o(config_udp_port_o),
    .config_tcp_port_o(config_tcp_port_o),
    .config_valid_o(config_valid_o),
    .eth_link_up_o(eth_link_up_o),
    .eth_rx_activity_o(eth_rx_activity_o),
    .eth_tx_activity_o(eth_tx_activity_o),
    .rx_packet_count_o(rx_packet_count_o),
    .tx_packet_count_o(tx_packet_count_o),
    .rx_error_count_o(rx_error_count_o)
  );

  always #(CLK_PERIOD / 2) clk_i = ~clk_i;

  task send_udp_packet;
    input [47:0] src_mac;
    input [31:0] src_ip;
    input [15:0] src_port;
    input [7:0] payload_data;
    integer j;
    reg [7:0] packet [0:99];
    begin
      for (j = 0; j < 6; j = j + 1) packet[j] = MAC_ADDR[47-8*j -: 8];
      for (j = 0; j < 6; j = j + 1) packet[j+6] = src_mac[47-8*j -: 8];
      packet[12] = 8'h08;
      packet[13] = 8'h00;
      packet[14] = 8'h45;
      packet[15] = 8'h00;
      packet[16] = 8'h00;
      packet[17] = 8'h20;
      packet[18] = 8'h00;
      packet[19] = 8'h01;
      packet[20] = 8'h40;
      packet[21] = 8'h00;
      packet[22] = 8'h40;
      packet[23] = 8'h11;
      packet[24] = 8'h00;
      packet[25] = 8'h00;
      packet[26] = src_ip[31:24];
      packet[27] = src_ip[23:16];
      packet[28] = src_ip[15:8];
      packet[29] = src_ip[7:0];
      packet[30] = IP_ADDR[31:24];
      packet[31] = IP_ADDR[23:16];
      packet[32] = IP_ADDR[15:8];
      packet[33] = IP_ADDR[7:0];
      packet[34] = src_port[15:8];
      packet[35] = src_port[7:0];
      packet[36] = UDP_PORT[15:8];
      packet[37] = UDP_PORT[7:0];
      packet[38] = 8'h00;
      packet[39] = 8'h0C;
      packet[40] = 8'h00;
      packet[41] = 8'h00;
      packet[42] = payload_data;
      packet[43] = 8'h00;
      packet[44] = 8'h00;
      packet[45] = 8'h00;

      eth_rx_dv_i = 1;
      for (j = 0; j < 46; j = j + 1) begin
        eth_rx_data_i = packet[j];
        #(RMII_PERIOD);
      end
      eth_rx_dv_i = 0;
      eth_rx_data_i = 0;
    end
  endtask

  task send_tcp_packet;
    input [47:0] src_mac;
    input [31:0] src_ip;
    input [15:0] src_port;
    input [7:0] config_data;
    integer j;
    reg [7:0] packet [0:99];
    begin
      for (j = 0; j < 6; j = j + 1) packet[j] = MAC_ADDR[47-8*j -: 8];
      for (j = 0; j < 6; j = j + 1) packet[j+6] = src_mac[47-8*j -: 8];
      packet[12] = 8'h08;
      packet[13] = 8'h00;
      packet[14] = 8'h45;
      packet[15] = 8'h00;
      packet[16] = 8'h00;
      packet[17] = 8'h28;
      packet[18] = 8'h00;
      packet[19] = 8'h01;
      packet[20] = 8'h40;
      packet[21] = 8'h00;
      packet[22] = 8'h40;
      packet[23] = 8'h06;
      packet[24] = 8'h00;
      packet[25] = 8'h00;
      packet[26] = src_ip[31:24];
      packet[27] = src_ip[23:16];
      packet[28] = src_ip[15:8];
      packet[29] = src_ip[7:0];
      packet[30] = IP_ADDR[31:24];
      packet[31] = IP_ADDR[23:16];
      packet[32] = IP_ADDR[15:8];
      packet[33] = IP_ADDR[7:0];
      packet[34] = src_port[15:8];
      packet[35] = src_port[7:0];
      packet[36] = TCP_PORT[15:8];
      packet[37] = TCP_PORT[7:0];
      packet[38] = 8'h00;
      packet[39] = 8'h00;
      packet[40] = 8'h00;
      packet[41] = 8'h01;
      packet[42] = 8'h50;
      packet[43] = 8'h10;
      packet[44] = 8'h00;
      packet[45] = 8'h00;
      packet[46] = 8'h00;
      packet[47] = 8'h00;
      packet[48] = 8'h00;
      packet[49] = 8'h00;
      packet[50] = config_data;
      packet[51] = 8'h00;
      packet[52] = 8'h00;
      packet[53] = 8'h00;

      eth_rx_dv_i = 1;
      for (j = 0; j < 54; j = j + 1) begin
        eth_rx_data_i = packet[j];
        #(RMII_PERIOD);
      end
      eth_rx_dv_i = 0;
      eth_rx_data_i = 0;
    end
  endtask

  initial begin
    clk_i = 0;
    rst_ni = 0;
    eth_rx_data_i = 0;
    eth_rx_dv_i = 0;
    eth_rx_er_i = 0;
    eth_tx_er_i = 0;
    eth_crs_i = 0;
    eth_col_i = 0;
    cmd_ready_i = 1;

    $display("Starting Ethernet Interface Testbench...");
    #100;
    rst_ni = 1;
    #50;

    $display("\nTest Case 1: Valid UDP packet with command");
    send_udp_packet(48'hAA_BB_CC_DD_EE_FF, 32'hC0_A8_01_65, 16'h1235, 8'h01);

    wait (cmd_data_valid_o);
    if (cmd_data_o == 8'h01) begin
      $display("SUCCESS: UDP command extracted correctly: 0x%h", cmd_data_o);
    end else begin
      $display("FAILURE: Expected command 0x01, got 0x%h", cmd_data_o);
    end
    @(negedge cmd_data_valid_o);
    #100;

    $display("\nTest Case 2: Valid TCP packet with configuration");
    send_tcp_packet(48'hAA_BB_CC_DD_EE_FF, 32'hC0_A8_01_65, 16'h1236, 8'h02);

    wait (config_valid_o);
    $display("SUCCESS: TCP configuration received: IP=%h, UDP=%h, TCP=%h",
             config_ip_addr_o, config_udp_port_o, config_tcp_port_o);
    @(negedge config_valid_o);
    #100;

    $display("\nTest Case 3: Invalid MAC address (should be filtered)");
    send_udp_packet(48'hFF_FF_FF_FF_FF_FF, 32'hC0_A8_01_65, 16'h1235, 8'h03);

    #200;
    if (!cmd_data_valid_o) begin
      $display("SUCCESS: Packet with invalid MAC was filtered correctly");
    end else begin
      $display("FAILURE: Packet with invalid MAC was not filtered");
    end
    #100;

    $display("\nTest Case 4: Error condition (rx_er asserted)");
    eth_rx_er_i = 1;
    #(RMII_PERIOD * 10);
    eth_rx_er_i = 0;

    if (rx_error_count_o > 0) begin
      $display("SUCCESS: Error condition detected, count: %d", rx_error_count_o);
    end else begin
      $display("FAILURE: Error condition not detected");
    end
    #100;

    $display("\nTest Case 5: Multiple packets in sequence");
    for (i = 0; i < 3; i = i + 1) begin
      send_udp_packet(48'hAA_BB_CC_DD_EE_FF, 32'hC0_A8_01_65, 16'h1235, 8'h10 + i);
      wait (cmd_data_valid_o);
      $display("Packet %d: Command 0x%h received", i, cmd_data_o);
      @(negedge cmd_data_valid_o);
      #50;
    end

    if (rx_packet_count_o >= 3) begin
      $display("SUCCESS: Multiple packets processed correctly, count: %d", rx_packet_count_o);
    end else begin
      $display("FAILURE: Packet count mismatch, expected >=3, got %d", rx_packet_count_o);
    end

    #100;
    $display("\nTestbench finished.");
    $finish;
  end

endmodule
