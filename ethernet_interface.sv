// ============================================================================
// File Name   : ethernet_interface.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Placeholder Ethernet command/configuration interface for the LED panel
//   controller. Parses UDP/TCP frames and presents command bytes to the command
//   processor when EnableEthernet is set in led_panel_controller.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   UdpPort, TcpPort, MacAddr, IpAddr
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - RMII Ethernet interface skeleton (not yet integrated in production top).
// ============================================================================

module ethernet_interface #(
  parameter logic [15:0] UdpPort = 16'h1234,
  parameter logic [15:0] TcpPort = 16'h1235,
  parameter logic [47:0] MacAddr = 48'h00_11_22_33_44_55,
  parameter logic [31:0] IpAddr  = 32'hC0_A8_01_64  // 192.168.1.100
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic eth_rx_data_i,
  input  logic eth_rx_dv_i,
  input  logic eth_rx_er_i,
  output logic eth_tx_data_o,
  output logic eth_tx_en_o,
  input  logic eth_tx_er_i,
  input  logic eth_crs_i,
  input  logic eth_col_i,

  output logic [7:0] cmd_data_o,
  output logic       cmd_data_valid_o,
  input  logic       cmd_ready_i,

  output logic [31:0] config_ip_addr_o,
  output logic [15:0] config_udp_port_o,
  output logic [15:0] config_tcp_port_o,
  output logic        config_valid_o,

  output logic        eth_link_up_o,
  output logic        eth_rx_activity_o,
  output logic        eth_tx_activity_o,
  output logic [15:0] rx_packet_count_o,
  output logic [15:0] tx_packet_count_o,
  output logic [15:0] rx_error_count_o
);

  localparam int unsigned EthHeaderSize = 14;
  localparam int unsigned IpHeaderSize  = 20;
  localparam int unsigned UdpHeaderSize = 8;
  localparam int unsigned TcpHeaderSize = 20;
  localparam int unsigned MaxPacketSize = 1518;
  localparam int unsigned RxBufferSize  = 2048;

  typedef enum logic [3:0] {
    StIdle,
    StRxPreamble,
    StRxDestMac,
    StRxSrcMac,
    StRxEthType,
    StRxIpHeader,
    StRxUdpHeader,
    StRxTcpHeader,
    StRxPayload,
    StRxCrc,
    StProcessPacket
  } rx_state_e;

  rx_state_e rx_state_d, rx_state_q;

  logic [7:0]  rx_buffer [0:RxBufferSize-1];
  logic [10:0] rx_buffer_wr_ptr_q;
  logic [10:0] rx_buffer_rd_ptr_q;
  logic        rx_packet_complete_q;
  logic [15:0] rx_packet_length_q;

  logic [31:0] src_ip_addr_q;
  logic [31:0] dest_ip_addr_q;
  logic [15:0] src_port_q;
  logic [15:0] dest_port_q;
  logic [15:0] payload_length_q;
  logic [7:0]  protocol_q;
  logic [7:0]  tcp_flags_q;

  logic        mac_match_q;
  logic [47:0] rx_dest_mac_q;
  logic [47:0] rx_src_mac_q;

  logic [7:0]  cmd_byte_counter_q;
  logic        cmd_processing_q;

  logic        rx_packet_complete_d;
  logic        mac_match_d;
  logic [47:0] rx_dest_mac_d;
  logic [47:0] rx_src_mac_d;
  logic [31:0] src_ip_addr_d;
  logic [31:0] dest_ip_addr_d;
  logic [15:0] src_port_d;
  logic [15:0] dest_port_d;
  logic [15:0] payload_length_d;
  logic [7:0]  protocol_d;
  logic [7:0]  tcp_flags_d;
  logic [15:0] rx_packet_length_d;
  logic [10:0] rx_buffer_wr_ptr_d;

  always_comb begin
    rx_state_d            = rx_state_q;
    rx_packet_complete_d  = 1'b0;
    rx_buffer_wr_ptr_d    = rx_buffer_wr_ptr_q;
    mac_match_d           = mac_match_q;
    rx_dest_mac_d         = rx_dest_mac_q;
    rx_src_mac_d          = rx_src_mac_q;
    src_ip_addr_d         = src_ip_addr_q;
    dest_ip_addr_d        = dest_ip_addr_q;
    src_port_d            = src_port_q;
    dest_port_d           = dest_port_q;
    payload_length_d      = payload_length_q;
    protocol_d            = protocol_q;
    tcp_flags_d           = tcp_flags_q;
    rx_packet_length_d    = rx_packet_length_q;

    if (eth_rx_dv_i) begin
      unique case (rx_state_q)
        StIdle: begin
          if (eth_rx_data_i == 8'h55) begin
            rx_state_d         = StRxPreamble;
            rx_buffer_wr_ptr_d = 11'd0;
          end
        end

        StRxPreamble: begin
          if (eth_rx_data_i == 8'hD5) begin
            rx_state_d = StRxDestMac;
            rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          end else if (eth_rx_data_i != 8'h55) begin
            rx_state_d = StIdle;
          end
        end

        StRxDestMac: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd5) begin
            rx_dest_mac_d = {rx_buffer[0], rx_buffer[1], rx_buffer[2],
                             rx_buffer[3], rx_buffer[4], eth_rx_data_i};
            mac_match_d = (rx_dest_mac_q == MacAddr) ||
                          (rx_dest_mac_q == 48'hFF_FF_FF_FF_FF_FF);
            rx_state_d  = StRxSrcMac;
          end
        end

        StRxSrcMac: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd11) begin
            rx_src_mac_d = {rx_buffer[6], rx_buffer[7], rx_buffer[8],
                            rx_buffer[9], rx_buffer[10], eth_rx_data_i};
            rx_state_d   = StRxEthType;
          end
        end

        StRxEthType: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd13) begin
            if ({rx_buffer[12], eth_rx_data_i} == 16'h0800) begin
              rx_state_d = StRxIpHeader;
            end else begin
              rx_state_d = StIdle;
            end
          end
        end

        StRxIpHeader: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd33) begin
            src_ip_addr_d  = {rx_buffer[26], rx_buffer[27], rx_buffer[28], rx_buffer[29]};
            dest_ip_addr_d = {rx_buffer[30], rx_buffer[31], rx_buffer[32], eth_rx_data_i};
            protocol_d     = rx_buffer[23];
            if (rx_buffer[23] == 8'h11) begin
              rx_state_d = StRxUdpHeader;
            end else if (rx_buffer[23] == 8'h06) begin
              rx_state_d = StRxTcpHeader;
            end else begin
              rx_state_d = StIdle;
            end
          end
        end

        StRxUdpHeader: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd41) begin
            src_port_d       = {rx_buffer[34], rx_buffer[35]};
            dest_port_d      = {rx_buffer[36], rx_buffer[37]};
            payload_length_d = {rx_buffer[38], rx_buffer[39]};
            if (({rx_buffer[36], rx_buffer[37]} == UdpPort) && mac_match_q) begin
              rx_state_d = StRxPayload;
            end else begin
              rx_state_d = StIdle;
            end
          end
        end

        StRxTcpHeader: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (rx_buffer_wr_ptr_q == 11'd53) begin
            src_port_d  = {rx_buffer[34], rx_buffer[35]};
            dest_port_d = {rx_buffer[36], rx_buffer[37]};
            tcp_flags_d = rx_buffer[47];
            if (({rx_buffer[36], rx_buffer[37]} == TcpPort) && mac_match_q) begin
              rx_state_d = StRxPayload;
            end else begin
              rx_state_d = StIdle;
            end
          end
        end

        StRxPayload: begin
          rx_buffer_wr_ptr_d = rx_buffer_wr_ptr_q + 11'd1;
          if (!eth_rx_dv_i) begin
            rx_packet_length_d   = rx_buffer_wr_ptr_q;
            rx_packet_complete_d = 1'b1;
            rx_state_d           = StProcessPacket;
          end
        end

        StProcessPacket: rx_state_d = StIdle;

        default: rx_state_d = StIdle;
      endcase
    end else if (eth_rx_er_i) begin
      rx_state_d = StIdle;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q            <= StIdle;
      rx_buffer_wr_ptr_q    <= 11'd0;
      rx_packet_complete_q  <= 1'b0;
      rx_packet_length_q    <= 16'd0;
      eth_rx_activity_o     <= 1'b0;
      mac_match_q           <= 1'b0;
      rx_dest_mac_q         <= 48'd0;
      rx_src_mac_q          <= 48'd0;
      src_ip_addr_q         <= 32'd0;
      dest_ip_addr_q        <= 32'd0;
      src_port_q            <= 16'd0;
      dest_port_q           <= 16'd0;
      payload_length_q      <= 16'd0;
      protocol_q            <= 8'd0;
      tcp_flags_q           <= 8'd0;
      rx_packet_count_o     <= 16'd0;
      rx_error_count_o      <= 16'd0;
    end else begin
      eth_rx_activity_o    <= 1'b0;
      rx_packet_complete_q <= 1'b0;
      rx_state_q           <= rx_state_d;
      rx_buffer_wr_ptr_q   <= rx_buffer_wr_ptr_d;
      mac_match_q          <= mac_match_d;
      rx_dest_mac_q        <= rx_dest_mac_d;
      rx_src_mac_q         <= rx_src_mac_d;
      src_ip_addr_q        <= src_ip_addr_d;
      dest_ip_addr_q       <= dest_ip_addr_d;
      src_port_q           <= src_port_d;
      dest_port_q          <= dest_port_d;
      payload_length_q     <= payload_length_d;
      protocol_q           <= protocol_d;
      tcp_flags_q          <= tcp_flags_d;
      rx_packet_length_q   <= rx_packet_length_d;

      if (eth_rx_dv_i) begin
        eth_rx_activity_o <= 1'b1;

        unique case (rx_state_q)
          StRxPreamble: begin
            if (eth_rx_data_i == 8'hD5) begin
              rx_buffer[rx_buffer_wr_ptr_q] <= eth_rx_data_i;
            end
          end
          StRxDestMac, StRxSrcMac, StRxEthType, StRxIpHeader,
          StRxUdpHeader, StRxTcpHeader, StRxPayload: begin
            rx_buffer[rx_buffer_wr_ptr_q] <= eth_rx_data_i;
          end
          StProcessPacket: begin
            rx_packet_count_o <= rx_packet_count_o + 16'd1;
          end
          default: ;
        endcase
      end else if (eth_rx_er_i) begin
        rx_error_count_o <= rx_error_count_o + 16'd1;
      end

      if (rx_packet_complete_d) begin
        rx_packet_complete_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_data_o          <= 8'd0;
      cmd_data_valid_o    <= 1'b0;
      config_valid_o      <= 1'b0;
      cmd_byte_counter_q  <= 8'd0;
      cmd_processing_q    <= 1'b0;
    end else begin
      cmd_data_valid_o <= 1'b0;
      config_valid_o   <= 1'b0;

      if (rx_packet_complete_q && !cmd_processing_q) begin
        if (protocol_q == 8'h11 && dest_port_q == UdpPort) begin
          cmd_processing_q   <= 1'b1;
          cmd_byte_counter_q <= 8'd0;
        end

        if (protocol_q == 8'h06 && dest_port_q == TcpPort) begin
          config_valid_o <= 1'b1;
        end
      end

      if (cmd_processing_q) begin
        if (cmd_byte_counter_q < payload_length_q - 16'd8) begin
          cmd_data_o <= rx_buffer[EthHeaderSize + IpHeaderSize + UdpHeaderSize +
                                 cmd_byte_counter_q];
          cmd_data_valid_o   <= 1'b1;
          cmd_byte_counter_q <= cmd_byte_counter_q + 8'd1;
        end else begin
          cmd_processing_q <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      eth_tx_data_o     <= 1'b0;
      eth_tx_en_o       <= 1'b0;
      eth_tx_activity_o <= 1'b0;
      tx_packet_count_o <= 16'd0;
    end else begin
      eth_tx_en_o       <= 1'b0;
      eth_tx_activity_o <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      eth_link_up_o <= 1'b0;
    end else begin
      eth_link_up_o <= 1'b1;
    end
  end

endmodule
