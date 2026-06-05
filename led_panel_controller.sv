// ============================================================================
// File Name   : led_panel_controller.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Top-level RGB LED panel controller for a scalable 2D panel array. Integrates
//   SPI and optional Ethernet command ingress, command_processor, memory_arbiter,
//   SDRAM stack, and one led_panel_driver per parallel panel row.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   SysClkHz, RefreshRateHz, BrightnessWidth, NumPanelRows, NumPanelsPerRow,
//   PanelWidth, PanelHeight, ColorDepth, CmdWidth, EnableEthernet,
//   SdramRowWidth, SdramColWidth, SdramBankWidth, ReadBurstLen,
//   SdramHostCyclesPerBurst, SdramHostCyclesPerSingle
//
// Dependencies:
//   - spi_slave.sv
//   - command_processor.sv
//   - led_panel_driver.sv
//   - memory_arbiter.sv
//   - sdram_arbiter_adapter.sv
//   - sdram_controller.sv
//   - ethernet_interface.v (when EnableEthernet = 1)
// ============================================================================
// Revision History:
//   Current - SPI/Ethernet ingress, SDRAM stack, per-row panel drivers, refresh budget checks.
// ============================================================================

module led_panel_controller #(
  parameter int unsigned SysClkHz                   = 50_000_000,
  parameter int unsigned RefreshRateHz              = 60,
  parameter int unsigned BrightnessWidth            = 8,
  parameter int unsigned NumPanelRows               = 12,
  parameter int unsigned NumPanelsPerRow            = 12,
  parameter int unsigned PanelWidth                 = 64,
  parameter int unsigned PanelHeight                = 32,
  parameter int unsigned ColorDepth                 = 4,
  parameter int unsigned CmdWidth                   = 8,
  parameter int unsigned EnableEthernet             = 0,
  parameter int unsigned SdramRowWidth              = 13,
  parameter int unsigned SdramColWidth              = 9,
  parameter int unsigned SdramBankWidth             = 2,
  parameter int unsigned ReadBurstLen               = 8,
  parameter int unsigned SdramHostCyclesPerBurst    = 16,
  parameter int unsigned SdramHostCyclesPerSingle   = 30
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic spi_sclk_i,
  input  logic spi_cs_ni,
  input  logic spi_mosi_i,
  output logic spi_miso_o,

  input  logic eth_rx_data_i,
  input  logic eth_rx_dv_i,
  input  logic eth_rx_er_i,
  output logic eth_tx_data_o,
  output logic eth_tx_en_o,
  input  logic eth_tx_er_i,
  input  logic eth_crs_i,
  input  logic eth_col_i,

  output logic [NumPanelRows-1:0] panel_r1_o,
  output logic [NumPanelRows-1:0] panel_g1_o,
  output logic [NumPanelRows-1:0] panel_b1_o,
  output logic [NumPanelRows-1:0] panel_r2_o,
  output logic [NumPanelRows-1:0] panel_g2_o,
  output logic [NumPanelRows-1:0] panel_b2_o,
  output logic [5*NumPanelRows-1:0] panel_addr_o,
  output logic [NumPanelRows-1:0] panel_clk_o,
  output logic [NumPanelRows-1:0] panel_lat_o,
  output logic [NumPanelRows-1:0] panel_oe_o,

  output logic [12:0] sdram_addr_o,
  output logic [1:0]  sdram_ba_o,
  output logic        sdram_cas_n_o,
  output logic        sdram_cke_o,
  output logic        sdram_clk_o,
  output logic        sdram_cs_n_o,
  inout  wire  [15:0] sdram_dq_io,
  output logic [1:0]  sdram_dqm_o,
  output logic        sdram_ras_n_o,
  output logic        sdram_we_n_o
);

  localparam int unsigned TotalWidth   = PanelWidth * NumPanelsPerRow;
  localparam int unsigned TotalHeight  = PanelHeight * NumPanelRows;
  localparam int unsigned FbAddrWidth    = $clog2(TotalWidth * TotalHeight);
  localparam int unsigned DataWidth      = ColorDepth * 3;
  localparam int unsigned SdramHaddrWidth =
      SdramBankWidth + SdramRowWidth + SdramColWidth;
  localparam int unsigned SdramAddrWidth = SdramHaddrWidth;
  localparam int unsigned RowAddrWidth   =
      (PanelHeight / 2 <= 1) ? 1 : $clog2(PanelHeight / 2);

  localparam int unsigned RowPairCount              = PanelHeight / 2;
  localparam int unsigned CyclesPerRowScan          = (TotalWidth * 2) + 3;
  localparam int unsigned TotalOverheadCycles       =
      CyclesPerRowScan * RowPairCount * ColorDepth;
  localparam int unsigned TotalBcmWeight            = (1 << ColorDepth) - 1;
  localparam int unsigned TotalUnitsPerRefresh      = TotalBcmWeight * RowPairCount;
  localparam int unsigned MinDisplayCyclesPerFrame  =
      TotalOverheadCycles + TotalUnitsPerRefresh;
  localparam int unsigned MaxDisplayRateHz          = SysClkHz / MinDisplayCyclesPerFrame;

  localparam int unsigned DesiredCyclesPerFrame     = SysClkHz / RefreshRateHz;

  localparam int unsigned SdramFullBurstsPerLine      = TotalWidth / ReadBurstLen;
  localparam int unsigned SdramTailReadsPerLine       = TotalWidth % ReadBurstLen;
  localparam int unsigned SdramBusCyclesPerLineBurst =
      NumPanelRows * (
          (SdramFullBurstsPerLine * SdramHostCyclesPerBurst) +
          (SdramTailReadsPerLine * SdramHostCyclesPerSingle)
      );
  localparam int unsigned SdramBusCyclesPerLineBl1   =
      SdramHostCyclesPerSingle * TotalWidth * NumPanelRows;
  localparam int unsigned SdramBusCyclesPerLine       = SdramBusCyclesPerLineBurst;
  localparam int unsigned SdramCyclesSavedPerLine     =
      SdramBusCyclesPerLineBl1 - SdramBusCyclesPerLineBurst;
  localparam int unsigned CyclesBudgetPerScanLine     = DesiredCyclesPerFrame / PanelHeight;
  localparam int unsigned SdramBusCyclesPerRowPair    = SdramBusCyclesPerLine * 2;
  localparam int unsigned SdramBusCyclesPerRowPairBl1 = SdramBusCyclesPerLineBl1 * 2;
  localparam int unsigned SdramCyclesSavedPerRowPair  = SdramCyclesSavedPerLine * 2;
  localparam int unsigned SdramCyclesSavedPerFrame    =
      SdramCyclesSavedPerRowPair * RowPairCount;
  localparam int unsigned CyclesBudgetPerRowPair      = DesiredCyclesPerFrame / RowPairCount;
  localparam int unsigned MaxSdramLineRateHz          =
      SysClkHz / (SdramBusCyclesPerLine * PanelHeight);
  localparam int unsigned MaxSdramLineRateHzBl1       =
      SysClkHz / (SdramBusCyclesPerLineBl1 * PanelHeight);
  localparam int unsigned MaxSdramRowPairRateHz       =
      SysClkHz / (SdramBusCyclesPerRowPair * RowPairCount);
  localparam int unsigned MaxSdramRowPairRateHzBl1    =
      SysClkHz / (SdramBusCyclesPerRowPairBl1 * RowPairCount);
  localparam int unsigned MaxAchievableRateHz          =
      MaxDisplayRateHz < MaxSdramRowPairRateHz ?
      MaxDisplayRateHz : MaxSdramRowPairRateHz;

  localparam int unsigned Hub75UtilPct              =
      (MinDisplayCyclesPerFrame * 100) / DesiredCyclesPerFrame;
  localparam int unsigned SdramLineUtilPct          =
      (SdramBusCyclesPerLine * 100) / CyclesBudgetPerScanLine;
  localparam int unsigned SdramLineUtilPctBl1       =
      (SdramBusCyclesPerLineBl1 * 100) / CyclesBudgetPerScanLine;
  localparam int unsigned SdramRowPairUtilPct       =
      (SdramBusCyclesPerRowPair * 100) / CyclesBudgetPerRowPair;
  localparam int unsigned SdramRowPairUtilPctBl1    =
      (SdramBusCyclesPerRowPairBl1 * 100) / CyclesBudgetPerRowPair;
  localparam int unsigned TargetVsCeilingPct        =
      (RefreshRateHz * 100) / MaxAchievableRateHz;
  localparam int unsigned LinePeriodUs              =
      1000000 / (RefreshRateHz * PanelHeight);

  initial begin
    if (ReadBurstLen != 1 && ReadBurstLen != 2 && ReadBurstLen != 4 && ReadBurstLen != 8)
      $display("ERROR: led_panel_controller ReadBurstLen=%0d; legal values are 1, 2, 4, 8",
               ReadBurstLen);
    if (SdramTailReadsPerLine != 0)
      $display("INFO: budget tail_reads_per_line=%0d (width not multiple of burst_len=%0d)",
               SdramTailReadsPerLine, ReadBurstLen);

    $display("INFO: config width=%0d height=%0d panel_rows=%0d panels_per_row=%0d depth=%0d clk_hz=%0d",
             TotalWidth, TotalHeight, NumPanelRows, NumPanelsPerRow, ColorDepth, SysClkHz);
    $display("INFO: target_hz=%0d frame_cycles=%0d us_per_scan_line=%0d",
             RefreshRateHz, DesiredCyclesPerFrame, LinePeriodUs);
    $display("INFO: limit HUB75 used_cycles=%0d budget_cycles=%0d util_pct=%0d max_hz=%0d",
             MinDisplayCyclesPerFrame, DesiredCyclesPerFrame, Hub75UtilPct, MaxDisplayRateHz);
    $display("INFO: budget sdram burst_len=%0d bursts_per_line=%0d cyc_per_burst=%0d cyc_per_single=%0d",
             ReadBurstLen, SdramFullBurstsPerLine,
             SdramHostCyclesPerBurst, SdramHostCyclesPerSingle);
    $display("INFO: limit SDRAM_line BL%0d used_cycles=%0d budget_cycles=%0d util_pct=%0d max_hz=%0d",
             ReadBurstLen, SdramBusCyclesPerLine, CyclesBudgetPerScanLine,
             SdramLineUtilPct, MaxSdramLineRateHz);
    $display("INFO: limit SDRAM_line BL1 baseline used_cycles=%0d util_pct=%0d max_hz=%0d",
             SdramBusCyclesPerLineBl1, SdramLineUtilPctBl1, MaxSdramLineRateHzBl1);
    $display("INFO: limit SDRAM_row_pair BL%0d used_cycles=%0d budget_cycles=%0d util_pct=%0d max_hz=%0d",
             ReadBurstLen, SdramBusCyclesPerRowPair, CyclesBudgetPerRowPair,
             SdramRowPairUtilPct, MaxSdramRowPairRateHz);
    $display("INFO: budget sdram_cycles_saved_per_row_pair=%0d per_frame=%0d vs_single_beat",
             SdramCyclesSavedPerRowPair, SdramCyclesSavedPerFrame);
    $display("INFO: ceiling_hz=%0d target_pct_of_ceiling=%0d",
             MaxAchievableRateHz, TargetVsCeilingPct);

    if (RefreshRateHz <= MaxAchievableRateHz)
      $display("INFO: verdict OK target_hz=%0d ceiling_hz=%0d", RefreshRateHz, MaxAchievableRateHz);
    else
      $display("INFO: verdict FAIL target_hz=%0d ceiling_hz=%0d", RefreshRateHz, MaxAchievableRateHz);

    if (RefreshRateHz > MaxDisplayRateHz)
      $display("ERROR: HUB75 over limit util_pct=%0d max_hz=%0d", Hub75UtilPct, MaxDisplayRateHz);
    if (SdramBusCyclesPerLine > CyclesBudgetPerScanLine)
      $display("ERROR: SDRAM_line over limit util_pct=%0d max_hz=%0d",
               SdramLineUtilPct, MaxSdramLineRateHz);
    if (SdramBusCyclesPerRowPair > CyclesBudgetPerRowPair)
      $display("ERROR: SDRAM_row_pair over limit util_pct=%0d", SdramRowPairUtilPct);
  end

  logic [CmdWidth-1:0] spi_data_out;
  logic                spi_data_valid;
  logic [CmdWidth-1:0] eth_data_out;
  logic                eth_data_valid;
  logic                eth_cmd_ready;

  logic cmd_mem_req;
  logic cmd_mem_write;
  logic [3:0] cmd_mem_read_length;
  logic [3:0] cmd_mem_write_length;
  logic [FbAddrWidth-1:0] cmd_mem_addr;
  logic [DataWidth-1:0] cmd_mem_write_data;
  logic cmd_mem_grant;
  logic [DataWidth-1:0] cmd_mem_read_data;
  logic cmd_mem_read_data_valid;

  logic [NumPanelRows-1:0] panel_mem_req;
  logic [NumPanelRows-1:0] panel_mem_write;
  logic [4*NumPanelRows-1:0] panel_mem_read_length;
  logic [FbAddrWidth*NumPanelRows-1:0] panel_mem_addr;
  logic [DataWidth*NumPanelRows-1:0] panel_mem_write_data;
  logic [4*NumPanelRows-1:0] panel_mem_write_length;
  logic [NumPanelRows-1:0] panel_mem_grant;
  logic [DataWidth*NumPanelRows-1:0] panel_mem_read_data;
  logic [NumPanelRows-1:0] panel_mem_read_data_valid;

  logic arbiter_mem_req;
  logic arbiter_mem_write;
  logic [3:0] arbiter_mem_read_length;
  logic [3:0] arbiter_mem_write_length;
  logic [FbAddrWidth-1:0] arbiter_mem_addr;
  logic [DataWidth-1:0] arbiter_mem_write_data;
  logic arbiter_mem_ready;
  logic [DataWidth-1:0] arbiter_mem_read_data;
  logic arbiter_mem_read_data_valid;

  localparam logic [BrightnessWidth-1:0] DriverBrightness = {BrightnessWidth{1'b1}};

  logic frame_ready;
  logic panels_enabled_q;
  logic panel_reset_n;

  logic [31:0] eth_config_ip_addr;
  logic [15:0] eth_config_udp_port;
  logic [15:0] eth_config_tcp_port;
  logic        eth_config_valid;

  logic [CmdWidth-1:0] cmd_data_in;
  logic                cmd_data_valid_final;

  logic [RowAddrWidth*NumPanelRows-1:0] panel_addr_internal;

  assign spi_miso_o = 1'b0;

  spi_slave #(
    .Width(CmdWidth)
  ) spi_slave_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_sclk_i(spi_sclk_i),
    .spi_cs_ni(spi_cs_ni),
    .spi_mosi_i(spi_mosi_i),
    .data_o(spi_data_out),
    .data_valid_o(spi_data_valid)
  );

  generate
    if (EnableEthernet) begin : gen_ethernet
      ethernet_interface #(
        .UdpPort(16'h1234),
        .TcpPort(16'h1235),
        .MacAddr(48'h00_11_22_33_44_55),
        .IpAddr(32'hC0_A8_01_64)
      ) eth_interface_inst (
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
        .cmd_data_o(eth_data_out),
        .cmd_data_valid_o(eth_data_valid),
        .cmd_ready_i(eth_cmd_ready),
        .config_ip_addr_o(eth_config_ip_addr),
        .config_udp_port_o(eth_config_udp_port),
        .config_tcp_port_o(eth_config_tcp_port),
        .config_valid_o(eth_config_valid),
        .eth_link_up_o(),
        .eth_rx_activity_o(),
        .eth_tx_activity_o(),
        .rx_packet_count_o(),
        .tx_packet_count_o(),
        .rx_error_count_o()
      );
    end else begin : gen_no_ethernet
      assign eth_tx_data_o = 1'b0;
      assign eth_tx_en_o   = 1'b0;
      assign eth_data_out       = {CmdWidth{1'b0}};
      assign eth_data_valid     = 1'b0;
      assign eth_config_ip_addr   = 32'd0;
      assign eth_config_udp_port  = 16'd0;
      assign eth_config_tcp_port  = 16'd0;
      assign eth_config_valid     = 1'b0;
    end
  endgenerate

  assign cmd_data_in          = spi_data_valid ? spi_data_out : eth_data_out;
  assign cmd_data_valid_final = spi_data_valid | eth_data_valid;
  assign eth_cmd_ready        = !spi_data_valid;

  assign panel_mem_write        = {NumPanelRows{1'b0}};
  assign panel_mem_write_data   = {(DataWidth*NumPanelRows){1'b0}};
  assign panel_mem_write_length = {(4*NumPanelRows){4'b0001}};

  assign panel_reset_n = rst_ni && panels_enabled_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      panels_enabled_q <= 1'b0;
    end else if (frame_ready) begin
      panels_enabled_q <= 1'b1;
    end
  end

  command_processor #(
    .TotalWidth(TotalWidth),
    .TotalHeight(TotalHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth)
  ) cmd_proc_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_data_in_i(cmd_data_in),
    .spi_data_valid_i(cmd_data_valid_final),
    .frame_ready_o(frame_ready),
    .mem_req_o(cmd_mem_req),
    .mem_write_o(cmd_mem_write),
    .mem_read_length_o(cmd_mem_read_length),
    .mem_write_length_o(cmd_mem_write_length),
    .mem_addr_o(cmd_mem_addr),
    .mem_write_data_o(cmd_mem_write_data),
    .mem_grant_i(cmd_mem_grant),
    .mem_read_data_i(cmd_mem_read_data),
    .mem_read_data_valid_i(cmd_mem_read_data_valid),
    .read_data_out_o(),
    .read_data_valid_o()
  );

  memory_arbiter #(
    .NumClients(NumPanelRows + 1),
    .NumLowPriClients(1),
    .AddrWidth(FbAddrWidth),
    .DataWidth(DataWidth)
  ) mem_arbiter_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .client_mem_req_i({panel_mem_req, cmd_mem_req}),
    .client_mem_write_i({panel_mem_write, cmd_mem_write}),
    .client_mem_addr_i({panel_mem_addr, cmd_mem_addr}),
    .client_mem_write_data_i({panel_mem_write_data, cmd_mem_write_data}),
    .client_mem_read_length_i({panel_mem_read_length, cmd_mem_read_length}),
    .client_mem_write_length_i({panel_mem_write_length, cmd_mem_write_length}),
    .client_mem_grant_o({panel_mem_grant, cmd_mem_grant}),
    .client_mem_read_data_o({panel_mem_read_data, cmd_mem_read_data}),
    .client_mem_read_data_valid_o({panel_mem_read_data_valid, cmd_mem_read_data_valid}),
    .master_mem_req_o(arbiter_mem_req),
    .master_mem_write_o(arbiter_mem_write),
    .master_mem_addr_o(arbiter_mem_addr),
    .master_mem_write_data_o(arbiter_mem_write_data),
    .master_mem_read_length_o(arbiter_mem_read_length),
    .master_mem_write_length_o(arbiter_mem_write_length),
    .master_mem_ready_i(arbiter_mem_ready),
    .master_mem_read_data_i(arbiter_mem_read_data),
    .master_mem_read_data_valid_i(arbiter_mem_read_data_valid)
  );

  genvar i;
  generate
    for (i = 0; i < NumPanelRows; i = i + 1) begin : gen_panel_drivers
      assign panel_addr_o[i*5 +: 5] =
          {{(5-RowAddrWidth){1'b0}}, panel_addr_internal[i*RowAddrWidth +: RowAddrWidth]};

      led_panel_driver #(
        .SysClkHz(SysClkHz),
        .RefreshRateHz(RefreshRateHz),
        .BrightnessWidth(BrightnessWidth),
        .TotalRowWidth(TotalWidth),
        .PanelHeight(PanelHeight),
        .ColorDepth(ColorDepth),
        .RowOffset(i * PanelHeight),
        .TotalDisplayHeight(TotalHeight),
        .ReadBurstLen(ReadBurstLen)
      ) led_driver_inst (
        .clk_i(clk_i),
        .rst_ni(panel_reset_n),
        .brightness_i(DriverBrightness),
        .mem_req_o(panel_mem_req[i]),
        .mem_read_length_o(panel_mem_read_length[i*4 +: 4]),
        .mem_grant_i(panel_mem_grant[i]),
        .mem_addr_o(panel_mem_addr[i*FbAddrWidth +: FbAddrWidth]),
        .mem_read_data_i(panel_mem_read_data[i*DataWidth +: DataWidth]),
        .mem_read_data_valid_i(panel_mem_read_data_valid[i]),
        .panel_r1_o(panel_r1_o[i]),
        .panel_g1_o(panel_g1_o[i]),
        .panel_b1_o(panel_b1_o[i]),
        .panel_r2_o(panel_r2_o[i]),
        .panel_g2_o(panel_g2_o[i]),
        .panel_b2_o(panel_b2_o[i]),
        .panel_addr_o(panel_addr_internal[i*RowAddrWidth +: RowAddrWidth]),
        .panel_clk_o(panel_clk_o[i]),
        .panel_lat_o(panel_lat_o[i]),
        .panel_oe_o(panel_oe_o[i])
      );
    end
  endgenerate

  logic [15:0] sdram_write_data;
  logic        sdram_write_request;
  logic [SdramAddrWidth-1:0] sdram_write_addr;
  logic [8:0]  sdram_write_length;
  logic        sdram_write_load;
  logic        sdram_write_full;
  logic [15:0] sdram_write_used;

  logic [15:0] sdram_read_data;
  logic        sdram_read_request;
  logic [SdramAddrWidth-1:0] sdram_read_addr;
  logic [8:0]  sdram_read_length;
  logic        sdram_read_load;
  logic        sdram_read_empty;
  logic [15:0] sdram_read_used;

  sdram_controller #(
    .RowSize(SdramRowWidth),
    .ColSize(SdramColWidth),
    .BankSize(SdramBankWidth),
    .RowStart(SdramColWidth),
    .ColStart(0),
    .BankStart(SdramColWidth + SdramRowWidth),
    .SaSize(SdramRowWidth),
    .AddrSize(SdramBankWidth + SdramRowWidth + SdramColWidth),
    .DataWidth(16),
    .ScBl(8),
    .ScSingleWrite(1)
  ) sdram_ctrl_inst (
    .clk_50mhz_i(clk_i),
    .rst_ni(rst_ni),
    .write_data_i(sdram_write_data),
    .write_request_i(sdram_write_request),
    .write_addr_i(sdram_write_addr),
    .write_length_i(sdram_write_length),
    .write_load_i(sdram_write_load),
    .write_full_o(sdram_write_full),
    .write_used_o(sdram_write_used),
    .read_data_o(sdram_read_data),
    .read_request_i(sdram_read_request),
    .read_addr_i(sdram_read_addr),
    .read_length_i(sdram_read_length),
    .read_load_i(sdram_read_load),
    .read_empty_o(sdram_read_empty),
    .read_used_o(sdram_read_used),
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

  sdram_arbiter_adapter #(
    .AddrWidth(FbAddrWidth),
    .DataWidth(DataWidth),
    .SdramAddrWidth(SdramAddrWidth),
    .MaxBurstLen(8),
    .ScBl(8)
  ) sdram_adapter_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .arbiter_mem_req_i(arbiter_mem_req),
    .arbiter_mem_write_i(arbiter_mem_write),
    .arbiter_mem_addr_i(arbiter_mem_addr),
    .arbiter_mem_write_data_i(arbiter_mem_write_data),
    .arbiter_mem_read_length_i(arbiter_mem_read_length),
    .arbiter_mem_write_length_i(arbiter_mem_write_length),
    .arbiter_mem_ready_o(arbiter_mem_ready),
    .arbiter_mem_read_data_o(arbiter_mem_read_data),
    .arbiter_mem_read_data_valid_o(arbiter_mem_read_data_valid),
    .sdram_write_data_o(sdram_write_data),
    .sdram_write_request_o(sdram_write_request),
    .sdram_write_addr_o(sdram_write_addr),
    .sdram_write_length_o(sdram_write_length),
    .sdram_write_load_o(sdram_write_load),
    .sdram_write_full_i(sdram_write_full),
    .sdram_write_used_i(sdram_write_used),
    .sdram_read_data_i(sdram_read_data),
    .sdram_read_request_o(sdram_read_request),
    .sdram_read_addr_o(sdram_read_addr),
    .sdram_read_length_o(sdram_read_length),
    .sdram_read_load_o(sdram_read_load),
    .sdram_read_empty_i(sdram_read_empty)
  );

endmodule
