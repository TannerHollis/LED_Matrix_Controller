// ============================================================================
// File Name   : led_panel_controller_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM-backed visual demo for the top-level led_panel_controller. A synthetic
//   SPI master writes rotating test patterns through spi_slave and
//   command_processor, flips the framebuffer, then holds each image for a few
//   seconds before advancing. No HUB75 self-check; use for bench visual verify.
//
// Parameters  :
//   SysClkHz             - Input clock frequency in Hz (Default: 50 MHz)
//   RefreshRateHz        - Display refresh target used by DUT timing
//   NumPanelRows         - Parallel HUB75 rows instantiated in DUT
//   NumPanelsPerRow      - Daisy-chained panels per row
//   PanelWidth           - Width of one physical panel in pixels
//   PanelHeight          - Height of one physical panel in pixels
//   ColorDepth           - Color bit depth per channel
//   SpiHalfPeriodCycles  - Synthetic SPI half-period in clk_50mhz cycles
//   CommandSettleCycles  - Inter-command wait for SDRAM write completion
//   PatternHoldSec       - Seconds to show each pattern before advancing
//   PatternCount         - Number of patterns in bist_frame_patterns
//
// Dependencies:
//   - led_panel_controller.sv
//   - bist_frame_patterns.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style; rotating visual patterns only (no checker).
// ============================================================================

module led_panel_controller_bist_top #(
  parameter int unsigned SysClkHz            = 100_000_000,
  parameter int unsigned MaxPanelClkHz       = 25_000_000,
  parameter int unsigned RefreshRateHz       = 120,
  parameter int unsigned NumPanelRows        = 1,
  parameter int unsigned NumPanelsPerRow     = 2,
  parameter int unsigned PanelWidth          = 64,
  parameter int unsigned PanelHeight         = 32,
  parameter int unsigned ColorDepth          = 4,
  parameter int unsigned CmdWidth            = 8,
  parameter int unsigned SpiHalfPeriodCycles = 4,
  parameter int unsigned CommandSettleCycles = 256,
  parameter int unsigned PatternHoldSec      = 3,
  parameter int unsigned PatternCount        = 16,
  parameter int unsigned Hub75HeaderRows     = 3,
  parameter int unsigned SdramRowWidth       = 13,
  parameter int unsigned SdramColWidth       = 9,
  parameter int unsigned SdramBankWidth      = 2
) (
  input  logic        clk_50mhz,
  input  logic        btn_start,
  input  logic        btn_reset,
  output logic        led_status,
  output logic [12:0] sdram_addr,
  output logic [1:0]  sdram_ba,
  output logic        sdram_cas_n,
  output logic        sdram_cke,
  output logic        sdram_clk,
  output logic        sdram_cs_n,
  inout  wire [15:0] sdram_dq,
  output logic [1:0]  sdram_dqm,
  output logic        sdram_ras_n,
  output logic        sdram_we_n,
  output logic [Hub75HeaderRows-1:0]   hub75_r1,
  output logic [Hub75HeaderRows-1:0]   hub75_g1,
  output logic [Hub75HeaderRows-1:0]   hub75_b1,
  output logic [Hub75HeaderRows-1:0]   hub75_r2,
  output logic [Hub75HeaderRows-1:0]   hub75_g2,
  output logic [Hub75HeaderRows-1:0]   hub75_b2,
  output logic [5*Hub75HeaderRows-1:0] hub75_addr,
  output logic [Hub75HeaderRows-1:0]   hub75_clk,
  output logic [Hub75HeaderRows-1:0]   hub75_lat,
  output logic [Hub75HeaderRows-1:0]   hub75_oe
);

  typedef enum logic [3:0] {
    StIdle,
    StLoadWrite,
    StLoadFlip,
    StBeginByte,
    StSetupBit,
    StSclkHigh,
    StSclkLow,
    StFinishByte,
    StByteGap,
    StCommandGap,
    StPatternHold
  } bist_state_e;

  typedef enum logic {
    PhWrite,
    PhFlip
  } command_phase_e;

  localparam int unsigned TotalWidth  = PanelWidth * NumPanelsPerRow;
  localparam int unsigned TotalHeight = PanelHeight * NumPanelRows;
  localparam int unsigned DataWidth   = ColorDepth * 3;
  localparam int unsigned FbAddrWidth = (TotalWidth * TotalHeight <= 1) ?
                                        1 : $clog2(TotalWidth * TotalHeight);
  localparam int unsigned CountWidth    = 32;
  localparam int unsigned ByteIdxWidth  = 4;
  localparam int unsigned BitIdxWidth   = 4;
  localparam logic [BitIdxWidth-1:0] LastSpiBit =
      (CmdWidth <= 1)  ? 4'd0  :
      (CmdWidth <= 2)  ? 4'd1  :
      (CmdWidth <= 3)  ? 4'd2  :
      (CmdWidth <= 4)  ? 4'd3  :
      (CmdWidth <= 5)  ? 4'd4  :
      (CmdWidth <= 6)  ? 4'd5  :
      (CmdWidth <= 7)  ? 4'd6  :
      (CmdWidth <= 8)  ? 4'd7  :
      (CmdWidth <= 9)  ? 4'd8  :
      (CmdWidth <= 10) ? 4'd9  :
      (CmdWidth <= 11) ? 4'd10 :
      (CmdWidth <= 12) ? 4'd11 :
      (CmdWidth <= 13) ? 4'd12 :
      (CmdWidth <= 14) ? 4'd13 :
      (CmdWidth <= 15) ? 4'd14 : 4'd15;
  localparam logic [CountWidth-1:0] FrameWords     = TotalWidth * TotalHeight;
  localparam logic [CountWidth-1:0] LastWriteIndex  = FrameWords - 1;
  localparam logic [23:0] SdramHostInitCycles     = 24'd50_000;
  localparam logic [CountWidth-1:0] PatternHoldCycles =
      SysClkHz * PatternHoldSec;
  localparam int unsigned PatSelWidth =
      (PatternCount <= 1) ? 1 : $clog2(PatternCount);
  localparam logic [PatSelWidth-1:0] LastPatternIndex = PatternCount - 1;

  localparam logic [ByteIdxWidth-1:0] AddrBytes =
      (FbAddrWidth <= 8)  ? 4'd1 :
      (FbAddrWidth <= 16) ? 4'd2 :
      (FbAddrWidth <= 24) ? 4'd3 : 4'd4;
  localparam logic [ByteIdxWidth-1:0] DataBytes =
      (DataWidth <= 8)  ? 4'd1 :
      (DataWidth <= 16) ? 4'd2 :
      (DataWidth <= 24) ? 4'd3 : 4'd4;
  localparam logic [ByteIdxWidth-1:0] WriteCmdLen = 4'd1 + AddrBytes + DataBytes;
  localparam logic [ByteIdxWidth-1:0] FlipCmdLen  = 4'd1;

  localparam logic [7:0] CmdWritePixel = 8'h01;
  localparam logic [7:0] CmdFlipBuffer = 8'h02;

  logic clk_i;
  logic rst_ni;
  assign clk_i  = clk_50mhz;
  assign rst_ni = btn_reset;

  bist_state_e    state;
  logic [23:0]    sdram_init_countdown;
  command_phase_e command_phase;
  logic [CountWidth-1:0]    write_index;
  logic [ByteIdxWidth-1:0]  byte_index;
  logic [BitIdxWidth-1:0]   bit_index;
  logic [CountWidth-1:0]    half_counter;
  logic [CountWidth-1:0]    gap_counter;
  logic [24:0]              blink_counter;
  logic [PatSelWidth-1:0]   pattern_id;
  logic [CountWidth-1:0]    hold_counter;

  logic [2:0] start_sync;
  logic       start_armed;
  logic       start_event;

  logic spi_sclk;
  logic spi_cs_n;
  logic spi_mosi;
  logic spi_miso;

  logic [NumPanelRows-1:0] panel_r1;
  logic [NumPanelRows-1:0] panel_g1;
  logic [NumPanelRows-1:0] panel_b1;
  logic [NumPanelRows-1:0] panel_r2;
  logic [NumPanelRows-1:0] panel_g2;
  logic [NumPanelRows-1:0] panel_b2;
  logic [5*NumPanelRows-1:0] panel_addr;
  logic [NumPanelRows-1:0] panel_clk;
  logic [NumPanelRows-1:0] panel_lat;
  logic [NumPanelRows-1:0] panel_oe;

  localparam int unsigned Hub75PadMsb = Hub75HeaderRows - NumPanelRows;

  assign hub75_r1   = {{Hub75PadMsb{1'b0}}, panel_r1};
  assign hub75_g1   = {{Hub75PadMsb{1'b0}}, panel_g1};
  assign hub75_b1   = {{Hub75PadMsb{1'b0}}, panel_b1};
  assign hub75_r2   = {{Hub75PadMsb{1'b0}}, panel_r2};
  assign hub75_g2   = {{Hub75PadMsb{1'b0}}, panel_g2};
  assign hub75_b2   = {{Hub75PadMsb{1'b0}}, panel_b2};
  assign hub75_addr = {{(Hub75PadMsb * 5){1'b0}}, panel_addr};
  assign hub75_clk  = {{Hub75PadMsb{1'b0}}, panel_clk};
  assign hub75_lat  = {{Hub75PadMsb{1'b0}}, panel_lat};
  assign hub75_oe   = {{Hub75PadMsb{1'b0}}, panel_oe};

  logic [FbAddrWidth-1:0] write_pattern_addr;
  logic [DataWidth-1:0]   write_pattern_pixel;

  assign write_pattern_addr = write_index[FbAddrWidth-1:0];

  bist_frame_patterns #(
    .ColorDepth(ColorDepth),
    .TotalWidth(TotalWidth),
    .TotalHeight(TotalHeight),
    .PatternCount(PatternCount)
  ) u_write_pattern (
    .pattern_sel_i(pattern_id),
    .addr_i(write_pattern_addr),
    .pixel_o(write_pattern_pixel)
  );

  logic [CmdWidth-1:0] current_spi_byte;

  function automatic logic [CmdWidth-1:0] command_byte(
      input command_phase_e           command_phase_in,
      input logic [CountWidth-1:0]    addr_index,
      input logic [ByteIdxWidth-1:0]  byte_idx,
      input logic [DataWidth-1:0]     data_value_in
  );
    logic [FbAddrWidth-1:0] addr_value;
    logic [DataWidth-1:0]   data_value;
    logic [FbAddrWidth-1:0] shifted_addr;
    logic [DataWidth-1:0]   shifted_data;
    begin
      addr_value   = addr_index[FbAddrWidth-1:0];
      data_value   = data_value_in;
      shifted_addr = {FbAddrWidth{1'b0}};
      shifted_data = {DataWidth{1'b0}};

      if (command_phase_in == PhWrite) begin
        if (byte_idx == {ByteIdxWidth{1'b0}})
          command_byte = CmdWritePixel;
        else if (byte_idx <= AddrBytes) begin
          shifted_addr = addr_value >> ((byte_idx - 1'b1) * 8);
          command_byte = shifted_addr[CmdWidth-1:0];
        end else begin
          shifted_data = data_value >> ((byte_idx - 1'b1 - AddrBytes) * 8);
          command_byte = shifted_data[CmdWidth-1:0];
        end
      end else begin
        command_byte = CmdFlipBuffer;
      end
    end
  endfunction

  function automatic logic [ByteIdxWidth-1:0] active_command_len(
      input command_phase_e command_phase_in
  );
    if (command_phase_in == PhWrite)
      active_command_len = WriteCmdLen;
    else
      active_command_len = FlipCmdLen;
  endfunction

  assign current_spi_byte =
      command_byte(command_phase, write_index, byte_index, write_pattern_pixel);

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
      state                <= StIdle;
      command_phase        <= PhWrite;
      write_index          <= {CountWidth{1'b0}};
      byte_index           <= {ByteIdxWidth{1'b0}};
      bit_index            <= {BitIdxWidth{1'b0}};
      half_counter         <= {CountWidth{1'b0}};
      gap_counter          <= {CountWidth{1'b0}};
      blink_counter        <= 25'd0;
      pattern_id           <= {PatSelWidth{1'b0}};
      hold_counter         <= {CountWidth{1'b0}};
      led_status           <= 1'b1;
      spi_sclk             <= 1'b0;
      spi_cs_n             <= 1'b1;
      spi_mosi             <= 1'b0;
      sdram_init_countdown <= SdramHostInitCycles;
    end else begin
      blink_counter <= blink_counter + 25'd1;

      if (state == StPatternHold) led_status <= ~blink_counter[22];
      else if (state != StIdle)   led_status <= ~blink_counter[21];
      else                        led_status <= 1'b1;

      unique case (state)
        StIdle: begin
          spi_sclk     <= 1'b0;
          spi_cs_n     <= 1'b1;
          spi_mosi     <= 1'b0;
          if (sdram_init_countdown != 24'd0)
            sdram_init_countdown <= sdram_init_countdown - 24'd1;
          else if (start_event) begin
            pattern_id   <= {PatSelWidth{1'b0}};
            hold_counter <= {CountWidth{1'b0}};
            write_index  <= {CountWidth{1'b0}};
            state        <= StLoadWrite;
          end
        end

        StLoadWrite: begin
          command_phase <= PhWrite;
          byte_index    <= {ByteIdxWidth{1'b0}};
          bit_index     <= LastSpiBit;
          half_counter  <= {CountWidth{1'b0}};
          gap_counter   <= {CountWidth{1'b0}};
          state         <= StBeginByte;
        end

        StLoadFlip: begin
          command_phase <= PhFlip;
          byte_index    <= {ByteIdxWidth{1'b0}};
          bit_index     <= LastSpiBit;
          half_counter  <= {CountWidth{1'b0}};
          gap_counter   <= {CountWidth{1'b0}};
          state         <= StBeginByte;
        end

        StBeginByte: begin
          spi_cs_n     <= 1'b0;
          spi_sclk     <= 1'b0;
          bit_index    <= LastSpiBit;
          half_counter <= {CountWidth{1'b0}};
          state        <= StSetupBit;
        end

        StSetupBit: begin
          spi_sclk <= 1'b0;
          spi_mosi <= current_spi_byte[bit_index];
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {CountWidth{1'b0}};
            state        <= StSclkHigh;
          end else begin
            half_counter <= half_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        StSclkHigh: begin
          spi_sclk <= 1'b1;
          if (half_counter == SpiHalfPeriodCycles - 1) begin
            half_counter <= {CountWidth{1'b0}};
            state        <= StSclkLow;
          end else begin
            half_counter <= half_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        StSclkLow: begin
          spi_sclk <= 1'b0;
          if (bit_index == {BitIdxWidth{1'b0}}) begin
            state <= StFinishByte;
          end else begin
            bit_index <= bit_index - {{(BitIdxWidth-1){1'b0}}, 1'b1};
            state     <= StSetupBit;
          end
        end

        StFinishByte: begin
          spi_sclk    <= 1'b0;
          spi_cs_n    <= 1'b1;
          gap_counter <= {CountWidth{1'b0}};
          state       <= StByteGap;
        end

        StByteGap: begin
          if (gap_counter < 32'd16) begin
            gap_counter <= gap_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end else if (byte_index == active_command_len(command_phase) - 1'b1) begin
            gap_counter <= {CountWidth{1'b0}};
            state       <= StCommandGap;
          end else begin
            byte_index <= byte_index + {{(ByteIdxWidth-1){1'b0}}, 1'b1};
            state      <= StBeginByte;
          end
        end

        StCommandGap: begin
          if (command_phase == PhFlip) begin
            hold_counter <= {CountWidth{1'b0}};
            state        <= StPatternHold;
          end else if (gap_counter >= CommandSettleCycles[CountWidth-1:0]) begin
            gap_counter <= {CountWidth{1'b0}};
            if (write_index == LastWriteIndex) begin
              state <= StLoadFlip;
            end else begin
              write_index <= write_index + {{(CountWidth-1){1'b0}}, 1'b1};
              state       <= StLoadWrite;
            end
          end else begin
            gap_counter <= gap_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        StPatternHold: begin
          if (hold_counter >= PatternHoldCycles) begin
            hold_counter <= {CountWidth{1'b0}};
            write_index  <= {CountWidth{1'b0}};
            if (pattern_id == LastPatternIndex)
              pattern_id <= {PatSelWidth{1'b0}};
            else
              pattern_id <= pattern_id + {{(PatSelWidth-1){1'b0}}, 1'b1};
            state <= StLoadWrite;
          end else begin
            hold_counter <= hold_counter + {{(CountWidth-1){1'b0}}, 1'b1};
          end
        end

        default: state <= StIdle;
      endcase
    end
  end

  led_panel_controller #(
    .SysClkHz(SysClkHz),
    .MaxPanelClkHz(MaxPanelClkHz),
    .RefreshRateHz(RefreshRateHz),
    .NumPanelRows(NumPanelRows),
    .NumPanelsPerRow(NumPanelsPerRow),
    .PanelWidth(PanelWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .CmdWidth(CmdWidth),
    .EnableEthernet(0),
    .SdramRowWidth(SdramRowWidth),
    .SdramColWidth(SdramColWidth),
    .SdramBankWidth(SdramBankWidth)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .spi_sclk_i(spi_sclk),
    .spi_cs_ni(spi_cs_n),
    .spi_mosi_i(spi_mosi),
    .spi_miso_o(spi_miso),
    .eth_rx_data_i(1'b0),
    .eth_rx_dv_i(1'b0),
    .eth_rx_er_i(1'b0),
    .eth_tx_data_o(),
    .eth_tx_en_o(),
    .eth_tx_er_i(1'b0),
    .eth_crs_i(1'b0),
    .eth_col_i(1'b0),
    .panel_r1_o(panel_r1),
    .panel_g1_o(panel_g1),
    .panel_b1_o(panel_b1),
    .panel_r2_o(panel_r2),
    .panel_g2_o(panel_g2),
    .panel_b2_o(panel_b2),
    .panel_addr_o(panel_addr),
    .panel_clk_o(panel_clk),
    .panel_lat_o(panel_lat),
    .panel_oe_o(panel_oe),
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
