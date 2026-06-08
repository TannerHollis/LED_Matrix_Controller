// ============================================================================
// File Name   : top_level.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   FPGA top-level wrapper for the DE2-115 (or custom carrier). Instantiates
//   led_panel_controller and exposes clock, reset, SPI, optional Ethernet RMII,
//   HUB75 panel buses, and external SDRAM pins without additional logic.
//
// Parameters  :
//   Same as led_panel_controller (passed through unchanged).
//
// Dependencies:
//   - led_panel_controller.sv
// ============================================================================
// Revision History:
//   Current - Production top; DUT-only instantiation.
// ============================================================================

module top_level #(
  parameter int unsigned SysClkHz               = 50_000_000,
  parameter int unsigned RefreshRateHz          = 60,
  parameter int unsigned BrightnessWidth        = 8,
  parameter int unsigned NumPanelRows           = 1,
  parameter int unsigned NumPanelsPerRow        = 1,
  parameter int unsigned PanelWidth             = 64,
  parameter int unsigned PanelHeight            = 32,
  parameter int unsigned ColorDepth             = 4,
  parameter int unsigned CmdWidth               = 8,
  parameter int unsigned EnableEthernet         = 0,
  parameter int unsigned SdramRowWidth          = 13,
  parameter int unsigned SdramColWidth          = 9,
  parameter int unsigned SdramBankWidth         = 2,
  parameter int unsigned ReadBurstLen           = 8,
  parameter int unsigned SdramHostCyclesPerBurst  = 16,
  parameter int unsigned SdramHostCyclesPerSingle = 30
) (
  input  wire clk_50mhz,
  input  wire btn_reset,

  input  wire spi_sclk,
  input  wire spi_cs_n,
  input  wire spi_mosi,
  output wire spi_miso,

  input  wire eth_rx_data,
  input  wire eth_rx_dv,
  input  wire eth_rx_er,
  output wire eth_tx_data,
  output wire eth_tx_en,
  input  wire eth_tx_er,
  input  wire eth_crs,
  input  wire eth_col,

  output wire [NumPanelRows-1:0]   hub75_r1,
  output wire [NumPanelRows-1:0]   hub75_g1,
  output wire [NumPanelRows-1:0]   hub75_b1,
  output wire [NumPanelRows-1:0]   hub75_r2,
  output wire [NumPanelRows-1:0]   hub75_g2,
  output wire [NumPanelRows-1:0]   hub75_b2,
  output wire [5*NumPanelRows-1:0] hub75_addr,
  output wire [NumPanelRows-1:0]   hub75_clk,
  output wire [NumPanelRows-1:0]   hub75_lat,
  output wire [NumPanelRows-1:0]   hub75_oe,

  output wire [12:0] sdram_addr,
  output wire [1:0]  sdram_ba,
  output wire        sdram_cas_n,
  output wire        sdram_cke,
  output wire        sdram_clk,
  output wire        sdram_cs_n,
  inout  wire [15:0] sdram_dq,
  output wire [1:0]  sdram_dqm,
  output wire        sdram_ras_n,
  output wire        sdram_we_n
);

  led_panel_controller #(
    .SysClkHz(SysClkHz),
    .RefreshRateHz(RefreshRateHz),
    .BrightnessWidth(BrightnessWidth),
    .NumPanelRows(NumPanelRows),
    .NumPanelsPerRow(NumPanelsPerRow),
    .PanelWidth(PanelWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth),
    .EnableEthernet(EnableEthernet),
    .SdramRowWidth(SdramRowWidth),
    .SdramColWidth(SdramColWidth),
    .SdramBankWidth(SdramBankWidth),
    .ReadBurstLen(ReadBurstLen),
    .SdramHostCyclesPerBurst(SdramHostCyclesPerBurst),
    .SdramHostCyclesPerSingle(SdramHostCyclesPerSingle)
  ) u_led_panel_controller (
    .clk_i(clk_50mhz),
    .rst_ni(btn_reset),

    .spi_sclk_i(spi_sclk),
    .spi_cs_ni(spi_cs_n),
    .spi_mosi_i(spi_mosi),
    .spi_miso_o(spi_miso),

    .eth_rx_data_i(eth_rx_data),
    .eth_rx_dv_i(eth_rx_dv),
    .eth_rx_er_i(eth_rx_er),
    .eth_tx_data_o(eth_tx_data),
    .eth_tx_en_o(eth_tx_en),
    .eth_tx_er_i(eth_tx_er),
    .eth_crs_i(eth_crs),
    .eth_col_i(eth_col),

    .panel_r1_o(hub75_r1),
    .panel_g1_o(hub75_g1),
    .panel_b1_o(hub75_b1),
    .panel_r2_o(hub75_r2),
    .panel_g2_o(hub75_g2),
    .panel_b2_o(hub75_b2),
    .panel_addr_o(hub75_addr),
    .panel_clk_o(hub75_clk),
    .panel_lat_o(hub75_lat),
    .panel_oe_o(hub75_oe),

    .sdram_addr_o(sdram_addr),
    .sdram_ba_o(sdram_ba),
    .sdram_cas_n_o(sdram_cas_n),
    .sdram_cke_o(sdram_cke),
    .sdram_clk_o(sdram_clk),
    .sdram_cs_n_o(sdram_cs_n),
    .sdram_dq_io(sdram_dq),
    .sdram_dqm_o(sdram_dqm),
    .sdram_ras_n_o(sdram_ras_n),
    .sdram_we_n_o(sdram_we_n)
  );

endmodule
