// ============================================================================
// File Name   : bist_frame_patterns.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Combinational framebuffer pattern generator for led_panel_controller BIST.
//   Select one of several test images by pattern_sel_i; pixel_o is RGB packed
//   {R, G, B} with ColorDepth bits per channel.
//
// Parameters  :
//   ColorDepth   - Bits per RGB channel
//   TotalWidth   - Frame width in pixels
//   TotalHeight  - Frame height in pixels
//   PatternCount - Number of patterns (indices 0 .. PatternCount-1)
// ============================================================================

module bist_frame_patterns #(
  parameter int unsigned ColorDepth  = 4,
  parameter int unsigned TotalWidth  = 128,
  parameter int unsigned TotalHeight = 32,
  parameter int unsigned PatternCount = 6
) (
  input  logic [((PatternCount <= 1) ? 1 : $clog2(PatternCount))-1:0] pattern_sel_i,
  input  logic [((TotalWidth * TotalHeight <= 1) ? 1 : $clog2(TotalWidth * TotalHeight))-1:0]
      addr_i,
  output logic [ColorDepth*3-1:0] pixel_o
);

  localparam int unsigned PixelWidth = ColorDepth * 3;
  localparam int unsigned ColShift   =
      (TotalWidth <= ColorDepth) ? 0 : ($clog2(TotalWidth) - ColorDepth);
  localparam int unsigned RowShift   =
      (TotalHeight <= ColorDepth) ? 0 : ($clog2(TotalHeight) - ColorDepth);
  localparam int unsigned CellSize   = 8;
  localparam int unsigned BarCount   = 8;

  logic [ColorDepth-1:0] ch_full;
  logic [ColorDepth-1:0] ch_zero;
  logic [ColorDepth-1:0] r;
  logic [ColorDepth-1:0] g;
  logic [ColorDepth-1:0] b;
  logic [15:0] col;
  logic [15:0] row;
  int unsigned stripe;
  int unsigned cell_x;
  int unsigned cell_y;
  int unsigned band;

  assign ch_full = {ColorDepth{1'b1}};
  assign ch_zero = {ColorDepth{1'b0}};

  always_comb begin
    col    = addr_i % TotalWidth;
    row    = addr_i / TotalWidth;
    r      = ch_zero;
    g      = ch_zero;
    b      = ch_zero;
    stripe = 0;
    cell_x = col / CellSize;
    cell_y = row / CellSize;
    band   = (row * BarCount) / TotalHeight;
    if (band >= BarCount)
      band = BarCount - 1;

    unique case (pattern_sel_i)
      0: begin
        stripe = (col * BarCount) / TotalWidth;
        if (stripe >= BarCount)
          stripe = BarCount - 1;
        unique case (stripe)
          0: r = ch_full;
          1: g = ch_full;
          2: b = ch_full;
          3: begin
            r = ch_full;
            g = ch_full;
          end
          4: begin
            g = ch_full;
            b = ch_full;
          end
          5: begin
            r = ch_full;
            b = ch_full;
          end
          6: begin
            r = ch_full;
            g = ch_full;
            b = ch_full;
          end
          default: ;
        endcase
      end

      1: begin
        if ((cell_x + cell_y) % 2 == 0) begin
          r = ch_full;
          g = ch_full;
          b = ch_full;
        end
      end

      2: begin
        unique case (band)
          0: r = ch_full;
          1: g = ch_full;
          2: b = ch_full;
          3: begin
            r = ch_full;
            g = ch_full;
          end
          4: begin
            g = ch_full;
            b = ch_full;
          end
          5: begin
            r = ch_full;
            b = ch_full;
          end
          6: begin
            r = ch_full;
            g = ch_full;
            b = ch_full;
          end
          default: ;
        endcase
      end

      3: begin
        r = col[ColShift +: ColorDepth];
      end

      4: begin
        g = row[RowShift +: ColorDepth];
      end

      5: begin
        if (col < TotalWidth / 2) begin
          if (row < TotalHeight / 2)
            r = ch_full;
          else
            g = ch_full;
        end else begin
          if (row < TotalHeight / 2)
            b = ch_full;
          else begin
            r = ch_full;
            g = ch_full;
            b = ch_full;
          end
        end
      end

      default: begin
        r = ch_full;
        g = ch_zero;
        b = ch_zero;
      end
    endcase

    pixel_o = {r, g, b};
  end

endmodule
