// ============================================================================
// File Name   : display_driver.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   HUB75 display driver with BCM timing, global brightness PWM, and row-pair
//   scanning. Reads one top+bottom line pair from line buffers and drives panel
//   R1/G1/B1/R2/G2/B2, ADDR, CLK, LAT, and OE. Asserts row_pair_done once per
//   completed row pair and display_complete at frame wrap.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   SysClkHz, RefreshRateHz, BrightnessWidth, TotalRowWidth, PanelHeight,
//   ColorDepth
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - One-cycle line-buffer read wait before CLK high (M9K latency).
// ============================================================================

module display_driver #(
  parameter int unsigned SysClkHz       = 50_000_000,
  parameter int unsigned RefreshRateHz  = 60,
  parameter int unsigned BrightnessWidth = 8,
  parameter int unsigned TotalRowWidth  = 1024,
  parameter int unsigned PanelHeight    = 32,
  parameter int unsigned ColorDepth     = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic [BrightnessWidth-1:0] brightness_i,

  input  logic [ColorDepth*3-1:0]           buffer_rd_data_top_i,
  input  logic [ColorDepth*3-1:0]           buffer_rd_data_bottom_i,
  output logic [$clog2(TotalRowWidth)-1:0]  buffer_rd_addr_o,

  output logic panel_r1_o,
  output logic panel_g1_o,
  output logic panel_b1_o,
  output logic panel_r2_o,
  output logic panel_g2_o,
  output logic panel_b2_o,
  output logic [$clog2(PanelHeight/2)-1:0] panel_addr_o,
  output logic panel_clk_o,
  output logic panel_lat_o,
  output logic panel_oe_o,

  input  logic start_display_i,
  output logic display_complete_o,
  output logic row_pair_done_o,
  output logic busy_o
);

  localparam int unsigned PixelDataWidth = ColorDepth * 3;
  localparam int unsigned RowPairCount   = PanelHeight / 2;
  localparam int unsigned AddrBits       = $clog2(RowPairCount);
  localparam int unsigned CyclesPerFrame = SysClkHz / RefreshRateHz;
  localparam int unsigned CyclesPerRowScan = (TotalRowWidth * 3) + 3;
  localparam int unsigned TotalOverheadCycles =
      CyclesPerRowScan * RowPairCount * ColorDepth;
  localparam int unsigned TotalBcmWeight = (1 << ColorDepth) - 1;
  localparam int unsigned TotalUnitsPerRefresh = TotalBcmWeight * RowPairCount;
  localparam int unsigned MinCyclesPerFrame =
      TotalOverheadCycles + TotalUnitsPerRefresh;
  localparam int unsigned MaxRefreshRateHz = SysClkHz / MinCyclesPerFrame;
  localparam int unsigned AvailableOeCycles =
      CyclesPerFrame - TotalOverheadCycles;
  localparam int unsigned TimeUnitScaler =
      AvailableOeCycles / TotalUnitsPerRefresh;
  localparam int unsigned ShiftAddrWidth = $clog2(TotalRowWidth);
  localparam int unsigned OeTimerWidth   = $clog2(CyclesPerFrame);

  localparam logic [ShiftAddrWidth-1:0] LastShiftAddr = TotalRowWidth - 1;
  localparam logic [ShiftAddrWidth-1:0] ShiftOne =
      {{(ShiftAddrWidth-1){1'b0}}, 1'b1};
  localparam logic [AddrBits-1:0] LastRowPair = RowPairCount - 1;
  localparam logic [AddrBits-1:0] RowPairOne =
      {{(AddrBits-1){1'b0}}, 1'b1};
  localparam logic [ColorDepth-1:0] LastBcm = ColorDepth - 1;
  localparam logic [ColorDepth-1:0] BcmOne =
      {{(ColorDepth-1){1'b0}}, 1'b1};
  localparam logic [BrightnessWidth-1:0] PwmOne =
      {{(BrightnessWidth-1){1'b0}}, 1'b1};

  typedef enum logic [2:0] {
    StIdle,
    StShift,
    StRdWait,
    StClkHi,
    StLatch,
    StEnable
  } display_state_e;

  display_state_e display_state_d, display_state_q;

  logic [ColorDepth-1:0] bcm_counter_q;
  logic [AddrBits-1:0] row_pair_counter_q;
  logic [ShiftAddrWidth-1:0] shift_counter_q;
  logic [OeTimerWidth-1:0] oe_timer_q;
  logic [BrightnessWidth-1:0] pwm_counter_q;

  initial begin
    $display("INFO: display_driver config: width=%0d height=%0d color_depth=%0d refresh=%0d Hz max_refresh=%0d Hz",
             TotalRowWidth, PanelHeight, ColorDepth, RefreshRateHz, MaxRefreshRateHz);
    if (RefreshRateHz > MaxRefreshRateHz) begin
      $display("ERROR: display_driver RefreshRateHz=%0d exceeds max_refresh=%0d for width=%0d height=%0d color_depth=%0d",
               RefreshRateHz, MaxRefreshRateHz, TotalRowWidth, PanelHeight, ColorDepth);
      $display("ERROR: display_driver needs at least %0d cycles/frame, but RefreshRateHz provides %0d cycles/frame",
               MinCyclesPerFrame, CyclesPerFrame);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pwm_counter_q <= '0;
    end else begin
      pwm_counter_q <= pwm_counter_q + PwmOne;
    end
  end

  always_comb begin
    display_state_d = display_state_q;

    if (start_display_i && display_state_q == StIdle) begin
      display_state_d = StShift;
    end else if (display_complete_o) begin
      display_state_d = StIdle;
    end else begin
      unique case (display_state_q)
        StShift: display_state_d = StRdWait;

        StRdWait: display_state_d = StClkHi;

        StClkHi: begin
          if (shift_counter_q == {ShiftAddrWidth{1'b0}}) begin
            display_state_d = StLatch;
          end else begin
            display_state_d = StShift;
          end
        end

        StLatch: display_state_d = StEnable;

        StEnable: begin
          if (oe_timer_q > {OeTimerWidth{1'b0}}) begin
            display_state_d = StEnable;
          end else if (bcm_counter_q == LastBcm) begin
            if (row_pair_counter_q == LastRowPair) begin
              display_state_d = StIdle;
            end else begin
              display_state_d = StShift;
            end
          end else begin
            display_state_d = StShift;
          end
        end

        default: display_state_d = StIdle;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      display_state_q    <= StIdle;
      panel_r1_o         <= 1'b0;
      panel_g1_o         <= 1'b0;
      panel_b1_o         <= 1'b0;
      panel_r2_o         <= 1'b0;
      panel_g2_o         <= 1'b0;
      panel_b2_o         <= 1'b0;
      panel_addr_o       <= '0;
      panel_clk_o        <= 1'b0;
      panel_lat_o        <= 1'b0;
      panel_oe_o         <= 1'b1;
      bcm_counter_q      <= '0;
      row_pair_counter_q <= '0;
      shift_counter_q    <= '0;
      oe_timer_q         <= '0;
      buffer_rd_addr_o   <= '0;
      display_complete_o <= 1'b0;
      row_pair_done_o    <= 1'b0;
      busy_o             <= 1'b0;
    end else begin
      display_state_q    <= display_state_d;
      display_complete_o <= 1'b0;
      row_pair_done_o    <= 1'b0;

      if (start_display_i && display_state_q == StIdle) begin
        shift_counter_q    <= LastShiftAddr;
        bcm_counter_q      <= '0;
        row_pair_counter_q <= '0;
        busy_o             <= 1'b1;
      end else if (display_complete_o) begin
        busy_o <= 1'b0;
      end else begin
        unique case (display_state_q)
          StIdle: begin
            panel_oe_o  <= 1'b1;
            panel_clk_o <= 1'b0;
            panel_lat_o <= 1'b0;
          end

          StShift: begin
            panel_clk_o      <= 1'b0;
            buffer_rd_addr_o <= shift_counter_q;
          end

          StRdWait: begin
            panel_clk_o <= 1'b0;
          end

          StClkHi: begin
            panel_clk_o <= 1'b1;
            panel_r1_o  <= buffer_rd_data_top_i[(ColorDepth*2) + bcm_counter_q];
            panel_g1_o  <= buffer_rd_data_top_i[(ColorDepth*1) + bcm_counter_q];
            panel_b1_o  <= buffer_rd_data_top_i[(ColorDepth*0) + bcm_counter_q];
            panel_r2_o  <= buffer_rd_data_bottom_i[(ColorDepth*2) + bcm_counter_q];
            panel_g2_o  <= buffer_rd_data_bottom_i[(ColorDepth*1) + bcm_counter_q];
            panel_b2_o  <= buffer_rd_data_bottom_i[(ColorDepth*0) + bcm_counter_q];

            if (shift_counter_q != {ShiftAddrWidth{1'b0}}) begin
              shift_counter_q <= shift_counter_q - ShiftOne;
            end
          end

          StLatch: begin
            panel_clk_o  <= 1'b0;
            panel_lat_o  <= 1'b1;
            panel_addr_o <= row_pair_counter_q;
            oe_timer_q   <= (1 << bcm_counter_q) * TimeUnitScaler;
          end

          StEnable: begin
            panel_lat_o <= 1'b0;

            if (oe_timer_q > {OeTimerWidth{1'b0}} && pwm_counter_q < brightness_i) begin
              panel_oe_o <= 1'b0;
            end else begin
              panel_oe_o <= 1'b1;
            end

            if (oe_timer_q > {OeTimerWidth{1'b0}}) begin
              oe_timer_q <= oe_timer_q - {{(OeTimerWidth-1){1'b0}}, 1'b1};
            end else begin
              if (bcm_counter_q == LastBcm) begin
                bcm_counter_q   <= '0;
                row_pair_done_o <= 1'b1;
                if (row_pair_counter_q == LastRowPair) begin
                  row_pair_counter_q <= '0;
                  display_complete_o <= 1'b1;
                end else begin
                  row_pair_counter_q <= row_pair_counter_q + RowPairOne;
                  shift_counter_q    <= LastShiftAddr;
                end
              end else begin
                bcm_counter_q   <= bcm_counter_q + BcmOne;
                shift_counter_q <= LastShiftAddr;
              end
            end
          end

          default: ;
        endcase
      end
    end
  end

endmodule
