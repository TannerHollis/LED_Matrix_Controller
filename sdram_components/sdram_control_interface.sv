// ============================================================================
// File Name   : sdram_control_interface.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Host-side SDRAM control bridge that accepts read/write/refresh commands,
//   tracks initialization, and acknowledges completed memory operations.
//
// Parameters  :
//   AddrSize - Host address bus width
//   InitPer  - Initialization wait in SDRAM clock cycles
//   RefPer   - Auto-refresh interval in SDRAM clock cycles
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - SDRAM control-signal timing interface (lowRISC port naming).
// ============================================================================

module control_interface #(
  parameter int unsigned AddrSize = 24,
  parameter int unsigned InitPer  = 24000,
  parameter int unsigned RefPer   = 1024
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic [2:0]             cmd_i,
  input  logic [AddrSize-1:0]    addr_i,
  input  logic                   ref_ack_i,
  input  logic                   init_ack_i,
  input  logic                   cm_ack_i,
  output logic                   nop_o,
  output logic                   reada_o,
  output logic                   writea_o,
  output logic                   refresh_o,
  output logic                   precharge_o,
  output logic                   load_mode_o,
  output logic [AddrSize-1:0]    saddr_o,
  output logic                   ref_req_o,
  output logic                   init_req_o,
  output logic                   cmd_ack_o
);

  logic [15:0] timer_q;
  logic [15:0] init_timer_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      nop_o    <= 1'b0;
      reada_o  <= 1'b0;
      writea_o <= 1'b0;
      saddr_o  <= '0;
    end else begin
      saddr_o <= addr_i;

      nop_o    <= (cmd_i == 3'b000);
      reada_o  <= (cmd_i == 3'b001);
      writea_o <= (cmd_i == 3'b010);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      cmd_ack_o <= 1'b0;
    else if (cm_ack_i && !cmd_ack_o)
      cmd_ack_o <= 1'b1;
    else
      cmd_ack_o <= 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      timer_q   <= '0;
      ref_req_o <= 1'b0;
    end else begin
      if (ref_ack_i) begin
        timer_q   <= RefPer[15:0];
        ref_req_o <= 1'b0;
      end else if (init_req_o) begin
        timer_q   <= RefPer[15:0] + 16'd200;
        ref_req_o <= 1'b0;
      end else begin
        timer_q <= timer_q - 16'd1;
      end

      if (timer_q == 16'd0)
        ref_req_o <= 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      init_timer_q <= '0;
      refresh_o    <= 1'b0;
      precharge_o  <= 1'b0;
      load_mode_o  <= 1'b0;
      init_req_o   <= 1'b0;
    end else begin
      if (init_timer_q < (InitPer + 201))
        init_timer_q <= init_timer_q + 16'd1;

      if (init_timer_q < InitPer) begin
        refresh_o   <= 1'b0;
        precharge_o <= 1'b0;
        load_mode_o <= 1'b0;
        init_req_o  <= 1'b1;
      end else if (init_timer_q == (InitPer + 20)) begin
        refresh_o   <= 1'b0;
        precharge_o <= 1'b1;
        load_mode_o <= 1'b0;
        init_req_o  <= 1'b0;
      end else if ((init_timer_q == (InitPer + 40))  ||
                   (init_timer_q == (InitPer + 60))  ||
                   (init_timer_q == (InitPer + 80))  ||
                   (init_timer_q == (InitPer + 100)) ||
                   (init_timer_q == (InitPer + 120)) ||
                   (init_timer_q == (InitPer + 140)) ||
                   (init_timer_q == (InitPer + 160)) ||
                   (init_timer_q == (InitPer + 180))) begin
        refresh_o   <= 1'b1;
        precharge_o <= 1'b0;
        load_mode_o <= 1'b0;
        init_req_o  <= 1'b0;
      end else if (init_timer_q == (InitPer + 200)) begin
        refresh_o   <= 1'b0;
        precharge_o <= 1'b0;
        load_mode_o <= 1'b1;
        init_req_o  <= 1'b0;
      end else begin
        refresh_o   <= 1'b0;
        precharge_o <= 1'b0;
        load_mode_o <= 1'b0;
        init_req_o  <= 1'b0;
      end
    end
  end

endmodule
