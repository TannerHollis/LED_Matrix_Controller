// ============================================================================
// File Name   : led_panel_controller_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   End-to-end simulation testbench for led_panel_controller. Writes a known
//   pixel pattern over SPI, flips the active buffer, and monitors panel outputs.
//
// Dependencies:
//   - led_panel_controller.sv
//   - sdram_components/sdram_model.sv
// ============================================================================
`timescale 1ns / 1ps

module led_panel_controller_tb;

  localparam int unsigned ClkPeriod       = 10;
  localparam int unsigned SpiSclkPeriod   = 20;
  localparam int unsigned NumPanelRows    = 1;
  localparam int unsigned NumPanelsPerRow = 1;
  localparam int unsigned PanelWidth      = 8;
  localparam int unsigned PanelHeight     = 8;
  localparam int unsigned ColorDepth      = 4;
  localparam int unsigned CmdWidth        = 8;

  logic clk_i;
  logic rst_ni;
  integer i;

  logic spi_sclk_i;
  logic spi_cs_ni;
  logic spi_mosi_i;
  logic spi_miso_o;

  logic eth_rx_data_i;
  logic eth_rx_dv_i;
  logic eth_rx_er_i;
  logic eth_tx_data_o;
  logic eth_tx_en_o;
  logic eth_tx_er_i;
  logic eth_crs_i;
  logic eth_col_i;

  logic [NumPanelRows-1:0] panel_oe_o;
  logic [NumPanelRows-1:0] panel_lat_o;

  wire [12:0] sdram_addr_o;
  wire [1:0]  sdram_ba_o;
  wire        sdram_cas_n_o;
  wire        sdram_cke_o;
  wire        sdram_clk_o;
  wire        sdram_cs_n_o;
  wire [15:0] sdram_dq_io;
  wire [1:0]  sdram_dqm_o;
  wire        sdram_ras_n_o;
  wire        sdram_we_n_o;

  led_panel_controller #(
    .SysClkHz(50_000_000),
    .RefreshRateHz(60),
    .NumPanelRows(NumPanelRows),
    .NumPanelsPerRow(NumPanelsPerRow),
    .PanelWidth(PanelWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth),
    .EnableEthernet(0)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_sclk_i(spi_sclk_i),
    .spi_cs_ni(spi_cs_ni),
    .spi_mosi_i(spi_mosi_i),
    .spi_miso_o(spi_miso_o),
    .eth_rx_data_i(eth_rx_data_i),
    .eth_rx_dv_i(eth_rx_dv_i),
    .eth_rx_er_i(eth_rx_er_i),
    .eth_tx_data_o(eth_tx_data_o),
    .eth_tx_en_o(eth_tx_en_o),
    .eth_tx_er_i(eth_tx_er_i),
    .eth_crs_i(eth_crs_i),
    .eth_col_i(eth_col_i),
    .panel_oe_o(panel_oe_o),
    .panel_lat_o(panel_lat_o),
    .sdram_addr_o(sdram_addr_o),
    .sdram_ba_o(sdram_ba_o),
    .sdram_cas_n_o(sdram_cas_n_o),
    .sdram_cke_o(sdram_cke_o),
    .sdram_clk_o(sdram_clk_o),
    .sdram_cs_n_o(sdram_cs_n_o),
    .sdram_dq_io(sdram_dq_io),
    .sdram_dqm_o(sdram_dqm_o),
    .sdram_ras_n_o(sdram_ras_n_o),
    .sdram_we_n_o(sdram_we_n_o)
  );

  sdram_model #(
    .AddrWidth(13),
    .DataWidth(16),
    .RowWidth(13),
    .ColWidth(9),
    .BankWidth(2),
    .CasLatency(3)
  ) sdram_chip (
    .sdram_clk_i(sdram_clk_o),
    .sdram_cke_i(sdram_cke_o),
    .sdram_cs_ni(sdram_cs_n_o),
    .sdram_ba_i(sdram_ba_o),
    .sdram_addr_i(sdram_addr_o),
    .sdram_dq_io(sdram_dq_io),
    .sdram_ras_ni(sdram_ras_n_o),
    .sdram_cas_ni(sdram_cas_n_o),
    .sdram_we_ni(sdram_we_n_o),
    .sdram_dqm_i(sdram_dqm_o)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;
  always #(SpiSclkPeriod / 2) spi_sclk_i = ~spi_sclk_i;

  task send_spi_byte;
    input [CmdWidth-1:0] byte_to_send;
    integer j;
    begin
      for (j = CmdWidth - 1; j >= 0; j = j - 1) begin
        spi_mosi_i = byte_to_send[j];
        #(SpiSclkPeriod);
      end
    end
  endtask

  initial begin
    clk_i = 1'b0;
    spi_sclk_i = 1'b0;
    spi_cs_ni = 1'b1;
    spi_mosi_i = 1'b0;
    rst_ni = 1'b0;
    eth_rx_data_i = 1'b0;
    eth_rx_dv_i = 1'b0;
    eth_rx_er_i = 1'b0;
    eth_tx_er_i = 1'b0;
    eth_crs_i = 1'b0;
    eth_col_i = 1'b0;

    $display("T=%3t: Starting Top-Level Testbench with SDRAM model...", $time);
    #100;
    rst_ni = 1'b1;
    #50;

    $display("T=%3t: Writing a ramp pattern to SDRAM via SPI.", $time);
    spi_cs_ni = 1'b0;

    for (i = 0; i < PanelWidth * PanelHeight; i = i + 1) begin
      send_spi_byte(8'h01);
      send_spi_byte(i[7:0]);
      send_spi_byte(i[15:8]);
      send_spi_byte(i[7:0]);
      send_spi_byte(i[15:8]);
    end

    $display("T=%3t: Sending FLIP command.", $time);
    send_spi_byte(8'h02);
    spi_cs_ni = 1'b1;
    #100;

    $display("T=%3t: Verification: Waiting for panel driver to become active.", $time);
    wait (panel_oe_o[0] == 1'b0);
    $display("T=%3t: SUCCESS! Panel OE for row 0 is active.", $time);

    #5000;

    $display("T=%3t: Test Case 2: Testing multiple panel rows", $time);
    spi_cs_ni = 1'b0;

    for (i = 0; i < PanelWidth * (PanelHeight/2); i = i + 1) begin
      send_spi_byte(8'h01);
      send_spi_byte(i[7:0]);
      send_spi_byte(i[15:8]);
      send_spi_byte(8'hF0);
      send_spi_byte(8'h00);
    end

    for (i = PanelWidth * (PanelHeight/2); i < PanelWidth * PanelHeight; i = i + 1) begin
      send_spi_byte(8'h01);
      send_spi_byte(i[7:0]);
      send_spi_byte(i[15:8]);
      send_spi_byte(8'h00);
      send_spi_byte(8'hF0);
    end

    send_spi_byte(8'h02);
    spi_cs_ni = 1'b1;

    wait (panel_oe_o[0] == 1'b0);
    $display("T=%3t: SUCCESS! Panel row is active.", $time);

    #2000;

    $display("T=%3t: Test Case 3: Testing error handling", $time);
    spi_cs_ni = 1'b0;
    send_spi_byte(8'h01);
    send_spi_byte(8'h00);
    spi_cs_ni = 1'b1;

    #1000;
    if (panel_oe_o[0] == 1'b0) begin
      $display("T=%3t: SUCCESS! System continued functioning after malformed command.", $time);
    end else begin
      $display("T=%3t: FAILURE! System stopped functioning after malformed command.", $time);
    end

    $display("T=%3t: Test Case 4: Testing reset behavior", $time);
    rst_ni = 1'b0;
    #100;
    rst_ni = 1'b1;
    #100;

    wait (panel_oe_o[0] == 1'b0);
    $display("T=%3t: SUCCESS! System resumed operation after reset.", $time);

    #2000;
    $display("T=%3t: Testbench finished.", $time);
    $finish;
  end

endmodule
