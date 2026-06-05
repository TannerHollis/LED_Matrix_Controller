// ============================================================================
// File Name   : sdram_command.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   SDRAM command sequencer that drives RAS/CAS/WE timing, auto-refresh, mode
//   register load, and burst read/write transactions for the host interface.
//
// Parameters  :
//   RowStart, RowSize, ColStart, ColSize, BankStart, BankSize - Address decode
//   SaSize, AddrSize - SDRAM and host address widths
//   ScCl, ScRcd, ScRrd, ScPm, ScBl, ScSingleWrite - SDRAM timing and mode
//
// Dependencies:
//   (none)
// ============================================================================
// Revision History:
//   Current - SDRAM command sequencer (lowRISC port naming).
// ============================================================================

module command #(
  parameter int unsigned RowStart      = 9,
  parameter int unsigned RowSize      = 13,
  parameter int unsigned ColStart      = 0,
  parameter int unsigned ColSize       = 9,
  parameter int unsigned BankStart     = 22,
  parameter int unsigned BankSize      = 2,
  parameter int unsigned SaSize        = 13,
  parameter int unsigned AddrSize      = 24,
  parameter int unsigned ScCl          = 3,
  parameter int unsigned ScRcd         = 3,
  parameter int unsigned ScRrd         = 7,
  parameter int unsigned ScPm          = 0,
  parameter int unsigned ScBl          = 1,
  parameter int unsigned ScSingleWrite = 0
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic [AddrSize-1:0]    saddr_i,
  input  logic                   nop_i,
  input  logic                   reada_i,
  input  logic                   writea_i,
  input  logic                   refresh_i,
  input  logic                   precharge_i,
  input  logic                   load_mode_i,
  input  logic                   ref_req_i,
  input  logic                   init_req_i,
  input  logic                   pm_stop_i,
  input  logic                   pm_done_i,
  output logic                   ref_ack_o,
  output logic                   cm_ack_o,
  output logic                   oe_o,
  output logic [SaSize-1:0]      sa_o,
  output logic [1:0]             ba_o,
  output logic [1:0]             cs_n_o,
  output logic                   cke_o,
  output logic                   ras_n_o,
  output logic                   cas_n_o,
  output logic                   we_n_o
);

  localparam logic [2:0] SdrBl = (ScPm == 1) ? 3'b111 :
      (ScBl == 1) ? 3'b000 :
      (ScBl == 2) ? 3'b001 :
      (ScBl == 4) ? 3'b010 :
                    3'b011;
  localparam logic SdrBt = 1'b0;
  localparam logic [2:0] SdrCl = (ScCl == 2) ? 3'b10 : 3'b11;

  logic                     do_reada_q;
  logic                     do_writea_q;
  logic                     do_refresh_q;
  logic                     do_precharge_q;
  logic                     do_load_mode_q;
  logic                     do_initial_q;
  logic                     command_done_q;
  logic [7:0]               command_delay_q;
  logic [1:0]               rw_shift_q;
  logic                     rw_flag_q;
  logic                     do_rw_q;
  logic [6:0]               oe_shift_q;
  logic                     oe1_q;
  logic                     oe2_q;
  logic                     oe3_q;
  logic                     oe4_q;
  logic [3:0]               rp_shift_q;
  logic                     rp_done_q;
  logic                     ex_read_q;
  logic                     ex_write_q;

  logic [RowSize-1:0]       rowaddr;
  logic [ColSize-1:0]       coladdr;
  logic [BankSize-1:0]      bankaddr;

  assign rowaddr  = saddr_i[RowStart + RowSize - 1 : RowStart];
  assign coladdr  = saddr_i[ColStart + ColSize - 1 : ColStart];
  assign bankaddr = saddr_i[BankStart + BankSize - 1 : BankStart];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      do_reada_q     <= 1'b0;
      do_writea_q    <= 1'b0;
      do_refresh_q   <= 1'b0;
      do_precharge_q <= 1'b0;
      do_load_mode_q <= 1'b0;
      do_initial_q   <= 1'b0;
      command_done_q <= 1'b0;
      command_delay_q <= 8'd0;
      rw_flag_q      <= 1'b0;
      rp_shift_q     <= 4'd0;
      rp_done_q      <= 1'b0;
      ex_read_q      <= 1'b0;
      ex_write_q     <= 1'b0;
    end else begin
      if (init_req_i) begin
        do_reada_q     <= 1'b0;
        do_writea_q    <= 1'b0;
        do_refresh_q   <= 1'b0;
        do_precharge_q <= 1'b0;
        do_load_mode_q <= 1'b0;
        do_initial_q   <= 1'b1;
        command_done_q <= 1'b0;
        command_delay_q <= 8'd0;
        rw_flag_q      <= 1'b0;
        rp_shift_q     <= 4'd0;
        rp_done_q      <= 1'b0;
        ex_read_q      <= 1'b0;
        ex_write_q     <= 1'b0;
      end else begin
        do_initial_q <= 1'b0;

        if ((ref_req_i || refresh_i) && !command_done_q && !do_refresh_q &&
            !rp_done_q && !do_reada_q && !do_writea_q)
          do_refresh_q <= 1'b1;
        else
          do_refresh_q <= 1'b0;

        if (reada_i && !command_done_q && !do_reada_q && !rp_done_q && !ref_req_i) begin
          do_reada_q <= 1'b1;
          ex_read_q  <= 1'b1;
        end else begin
          do_reada_q <= 1'b0;
        end

        if (writea_i && !command_done_q && !do_writea_q && !rp_done_q && !ref_req_i) begin
          do_writea_q <= 1'b1;
          ex_write_q  <= 1'b1;
        end else begin
          do_writea_q <= 1'b0;
        end

        if (precharge_i && !command_done_q && !do_precharge_q)
          do_precharge_q <= 1'b1;
        else
          do_precharge_q <= 1'b0;

        if (load_mode_i && !command_done_q && !do_load_mode_q)
          do_load_mode_q <= 1'b1;
        else
          do_load_mode_q <= 1'b0;

        if (do_refresh_q || do_reada_q || do_writea_q || do_precharge_q || do_load_mode_q) begin
          command_delay_q <= 8'b11111111;
          command_done_q  <= 1'b1;
          rw_flag_q       <= do_reada_q;
        end else begin
          command_done_q  <= command_delay_q[0];
          command_delay_q <= (command_delay_q >> 1);
        end

        if (!command_delay_q[0] && command_done_q) begin
          rp_shift_q <= 4'b1111;
          rp_done_q  <= 1'b1;
        end else begin
          if (ScPm == 0) begin
            rp_shift_q <= (rp_shift_q >> 1);
            rp_done_q  <= rp_shift_q[0];
          end else begin
            if (!ex_read_q && !ex_write_q) begin
              rp_shift_q <= (rp_shift_q >> 1);
              rp_done_q  <= rp_shift_q[0];
            end else if (pm_stop_i) begin
              rp_shift_q <= (rp_shift_q >> 1);
              rp_done_q  <= rp_shift_q[0];
              ex_read_q  <= 1'b0;
              ex_write_q <= 1'b0;
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      oe_shift_q <= 7'd0;
      oe1_q      <= 1'b0;
      oe2_q      <= 1'b0;
      oe_o       <= 1'b0;
    end else begin
      if (ScPm == 0) begin
        if (do_writea_q) begin
          if (ScBl == 1)
            oe_shift_q <= 7'd0;
          else if (ScBl == 2)
            oe_shift_q <= 7'd1;
          else if (ScBl == 4)
            oe_shift_q <= 7'd7;
          else if (ScBl == 8)
            oe_shift_q <= 7'd127;
          oe1_q <= 1'b1;
        end else begin
          oe_shift_q <= (oe_shift_q >> 1);
          oe1_q      <= oe_shift_q[0];
          oe2_q      <= oe1_q;
          oe3_q      <= oe2_q;
          oe4_q      <= oe3_q;
          if (ScRcd == 2)
            oe_o <= oe3_q;
          else
            oe_o <= oe4_q;
        end
      end else begin
        if (do_writea_q)
          oe4_q <= 1'b1;
        else if (do_precharge_q || do_reada_q || do_refresh_q || do_initial_q || pm_stop_i)
          oe4_q <= 1'b0;
        oe_o <= oe4_q;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rw_shift_q <= 2'd0;
      do_rw_q    <= 1'b0;
    end else begin
      if (do_reada_q || do_writea_q) begin
        if (ScRcd == 1)
          do_rw_q <= 1'b1;
        else if (ScRcd == 2)
          rw_shift_q <= 2'd1;
        else if (ScRcd == 3)
          rw_shift_q <= 2'd2;
      end else begin
        rw_shift_q <= (rw_shift_q >> 1);
        do_rw_q    <= rw_shift_q[0];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cm_ack_o  <= 1'b0;
      ref_ack_o <= 1'b0;
    end else begin
      if (do_refresh_q && ref_req_i)
        ref_ack_o <= 1'b1;
      else if (do_refresh_q || do_reada_q || do_writea_q || do_precharge_q || do_load_mode_q)
        cm_ack_o <= 1'b1;
      else begin
        ref_ack_o <= 1'b0;
        cm_ack_o  <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      sa_o    <= '0;
      ba_o    <= '0;
      cs_n_o  <= 2'b11;
      ras_n_o <= 1'b1;
      cas_n_o <= 1'b1;
      we_n_o  <= 1'b1;
      cke_o   <= 1'b0;
    end else begin
      cke_o <= 1'b1;

      if (do_writea_q || do_reada_q)
        sa_o <= rowaddr;
      else
        sa_o <= coladdr;

      if (do_rw_q || do_precharge_q)
        sa_o[10] <= !ScPm[0];

      if (do_precharge_q || do_load_mode_q)
        ba_o <= 2'b00;
      else
        ba_o <= bankaddr[1:0];

      if (do_refresh_q || do_precharge_q || do_load_mode_q || do_initial_q)
        cs_n_o <= 2'b00;
      else
        cs_n_o <= 2'b00;

      if (do_load_mode_q)
        sa_o <= {ScSingleWrite[0], 1'b0, SdrCl, SdrBt, SdrBl};

      if (do_refresh_q) begin
        ras_n_o <= 1'b0;
        cas_n_o <= 1'b0;
        we_n_o  <= 1'b1;
      end else if (do_precharge_q && (oe4_q || rw_flag_q)) begin
        ras_n_o <= 1'b1;
        cas_n_o <= 1'b1;
        we_n_o  <= 1'b0;
      end else if (do_precharge_q) begin
        ras_n_o <= 1'b0;
        cas_n_o <= 1'b1;
        we_n_o  <= 1'b0;
      end else if (do_load_mode_q) begin
        ras_n_o <= 1'b0;
        cas_n_o <= 1'b0;
        we_n_o  <= 1'b0;
      end else if (do_reada_q || do_writea_q) begin
        ras_n_o <= 1'b0;
        cas_n_o <= 1'b1;
        we_n_o  <= 1'b1;
      end else if (do_rw_q) begin
        ras_n_o <= 1'b1;
        cas_n_o <= 1'b0;
        we_n_o  <= rw_flag_q;
      end else if (do_initial_q) begin
        ras_n_o <= 1'b1;
        cas_n_o <= 1'b1;
        we_n_o  <= 1'b1;
      end else begin
        ras_n_o <= 1'b1;
        cas_n_o <= 1'b1;
        we_n_o  <= 1'b1;
      end
    end
  end

endmodule
