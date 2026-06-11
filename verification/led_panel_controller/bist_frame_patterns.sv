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
//
// Pattern index :
//   0  vertical color bars       8  hue spectrum (horizontal)
//   1  checkerboard              9  hue spectrum (vertical)
//   2  horizontal stripes       10  hue spectrum (diagonal)
//   3  grayscale gradient H     11  warm gradient (black-red-yellow-white)
//   4  grayscale gradient V     12  cool gradient (black-blue-cyan-white)
//   5  red gradient H           13  four quadrants
//   6  green gradient V         14  RGB vertical gradients in thirds
//   7  blue gradient H          15  hue spectrum fading to black at bottom
// ============================================================================
// Revision History:
//   Current - lowRISC style (logic, unique case, function automatic).
// ============================================================================

module bist_frame_patterns #(
  parameter int unsigned ColorDepth   = 4,
  parameter int unsigned TotalWidth   = 128,
  parameter int unsigned TotalHeight  = 32,
  parameter int unsigned PatternCount = 16
) (
  input  logic [((PatternCount <= 1) ? 1 : $clog2(PatternCount))-1:0] pattern_sel_i,
  input  logic [((TotalWidth * TotalHeight <= 1) ? 1 : $clog2(TotalWidth * TotalHeight))-1:0]
      addr_i,
  output logic [ColorDepth*3-1:0] pixel_o
);

  localparam int unsigned CellSize = 8;
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
  int unsigned maxv;
  int unsigned hue256;
  int unsigned ro;
  int unsigned go;
  int unsigned bo;
  int unsigned third_w;
  int unsigned zone;
  int unsigned fade;

  assign ch_full = {ColorDepth{1'b1}};
  assign ch_zero = {ColorDepth{1'b0}};

  function automatic int unsigned ch_max(input int unsigned depth);
    ch_max = (1 << depth) - 1;
  endfunction

  function automatic int unsigned scale_pos(
      input int unsigned pos,
      input int unsigned max_pos,
      input int unsigned peak
  );
    if (max_pos == 0)
      scale_pos = peak;
    else
      scale_pos = (pos * peak + max_pos / 2) / max_pos;
  endfunction

  function automatic void hue_to_rgb(
      input  int unsigned hue256,
      input  int unsigned depth,
      output int unsigned rout,
      output int unsigned gout,
      output int unsigned bout
  );
    int unsigned peak;
    int unsigned h;
    int unsigned f;
    int unsigned p;
    int unsigned q;
    int unsigned t;
    begin
      peak = ch_max(depth);
      h    = (hue256 * 6) / 256;
      if (h >= 6)
        h = 5;
      f = (hue256 * 6) % 256;
      p = 0;
      q = (peak * (256 - f)) / 256;
      t = (peak * f) / 256;
      unique case (h)
        0: begin
          rout = peak;
          gout = t;
          bout = p;
        end
        1: begin
          rout = q;
          gout = peak;
          bout = p;
        end
        2: begin
          rout = p;
          gout = peak;
          bout = t;
        end
        3: begin
          rout = p;
          gout = q;
          bout = peak;
        end
        4: begin
          rout = t;
          gout = p;
          bout = peak;
        end
        default: begin
          rout = peak;
          gout = p;
          bout = q;
        end
      endcase
    end
  endfunction

  function automatic int unsigned clamp_ch(
      input int unsigned value,
      input int unsigned depth
  );
    int unsigned peak;
    peak = ch_max(depth);
    if (value > peak)
      clamp_ch = peak;
    else
      clamp_ch = value;
  endfunction

  always_comb begin
    col     = addr_i % TotalWidth;
    row     = addr_i / TotalWidth;
    r       = ch_zero;
    g       = ch_zero;
    b       = ch_zero;
    stripe  = 0;
    cell_x  = col / CellSize;
    cell_y  = row / CellSize;
    band    = (row * BarCount) / TotalHeight;
    maxv    = ch_max(ColorDepth);
    hue256  = 0;
    ro      = 0;
    go      = 0;
    bo      = 0;
    third_w = TotalWidth / 3;
    zone    = 0;
    fade    = 0;
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
        ro = clamp_ch(scale_pos(col, TotalWidth - 1, maxv), ColorDepth);
        r  = ro[ColorDepth-1:0];
        g  = r;
        b  = r;
      end

      4: begin
        ro = clamp_ch(scale_pos(row, TotalHeight - 1, maxv), ColorDepth);
        r  = ro[ColorDepth-1:0];
        g  = r;
        b  = r;
      end

      5: begin
        ro = clamp_ch(scale_pos(col, TotalWidth - 1, maxv), ColorDepth);
        r  = ro[ColorDepth-1:0];
      end

      6: begin
        go = clamp_ch(scale_pos(row, TotalHeight - 1, maxv), ColorDepth);
        g  = go[ColorDepth-1:0];
      end

      7: begin
        bo = clamp_ch(scale_pos(col, TotalWidth - 1, maxv), ColorDepth);
        b  = bo[ColorDepth-1:0];
      end

      8: begin
        hue256 = (col * 255) / ((TotalWidth > 1) ? (TotalWidth - 1) : 1);
        hue_to_rgb(hue256, ColorDepth, ro, go, bo);
        r = ro[ColorDepth-1:0];
        g = go[ColorDepth-1:0];
        b = bo[ColorDepth-1:0];
      end

      9: begin
        hue256 = (row * 255) / ((TotalHeight > 1) ? (TotalHeight - 1) : 1);
        hue_to_rgb(hue256, ColorDepth, ro, go, bo);
        r = ro[ColorDepth-1:0];
        g = go[ColorDepth-1:0];
        b = bo[ColorDepth-1:0];
      end

      10: begin
        hue256 = ((col * 128) / ((TotalWidth > 1) ? (TotalWidth - 1) : 1) +
                  (row * 128) / ((TotalHeight > 1) ? (TotalHeight - 1) : 1));
        if (hue256 > 255)
          hue256 = 255;
        hue_to_rgb(hue256, ColorDepth, ro, go, bo);
        r = ro[ColorDepth-1:0];
        g = go[ColorDepth-1:0];
        b = bo[ColorDepth-1:0];
      end

      11: begin
        zone = row / ((TotalHeight > 3) ? (TotalHeight / 3) : 1);
        if (zone >= 3)
          zone = 2;
        unique case (zone)
          0: begin
            ro = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            r  = ro[ColorDepth-1:0];
          end
          1: begin
            r  = ch_full;
            go = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            g  = go[ColorDepth-1:0];
          end
          default: begin
            r  = ch_full;
            g  = ch_full;
            bo = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            b  = bo[ColorDepth-1:0];
          end
        endcase
      end

      12: begin
        zone = row / ((TotalHeight > 3) ? (TotalHeight / 3) : 1);
        if (zone >= 3)
          zone = 2;
        unique case (zone)
          0: begin
            bo = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            b  = bo[ColorDepth-1:0];
          end
          1: begin
            go = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            g  = go[ColorDepth-1:0];
            b  = ch_full;
          end
          default: begin
            ro = clamp_ch(scale_pos(row % ((TotalHeight > 3) ? (TotalHeight / 3) : 1),
                                    ((TotalHeight > 3) ? (TotalHeight / 3) : 1) - 1,
                                    maxv), ColorDepth);
            r  = ro[ColorDepth-1:0];
            g  = ch_full;
            b  = ch_full;
          end
        endcase
      end

      13: begin
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

      14: begin
        ro = clamp_ch(scale_pos(row, TotalHeight - 1, maxv), ColorDepth);
        if (col < third_w)
          r = ro[ColorDepth-1:0];
        else if (col < (2 * third_w))
          g = ro[ColorDepth-1:0];
        else
          b = ro[ColorDepth-1:0];
      end

      15: begin
        hue256 = (col * 255) / ((TotalWidth > 1) ? (TotalWidth - 1) : 1);
        hue_to_rgb(hue256, ColorDepth, ro, go, bo);
        fade   = scale_pos(TotalHeight - 1 - row, TotalHeight - 1, maxv);
        ro     = clamp_ch((ro * fade) / maxv, ColorDepth);
        go     = clamp_ch((go * fade) / maxv, ColorDepth);
        bo     = clamp_ch((bo * fade) / maxv, ColorDepth);
        r      = ro[ColorDepth-1:0];
        g      = go[ColorDepth-1:0];
        b      = bo[ColorDepth-1:0];
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
