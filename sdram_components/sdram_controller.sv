// ============================================================================
// File Name   : sdram_controller.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   FIFO-hosted SDRAM controller for the DE2-115 W9825G6KH-6 device. Dual-clock
//   FIFOs bridge the host port to the SDRAM command domain. clk_host_i and
//   clk_sdram_i are provided by the parent (see sdram_clock_gen.sv); they may be
//   tied to the same net when both domains run at the same frequency.
//
// Parameters  :
//   RowStart, RowSize, ColStart, ColSize, BankStart, BankSize - Address decode
//   SaSize, AddrSize, DataWidth - SDRAM geometry and data width
//   InitPer, RefPer - Initialization and refresh intervals
//   ScCl, ScRcd, ScRrd, ScPm, ScBl, ScSingleWrite - SDRAM timing and mode
//   MaxBurstLen - Maximum host burst; sizes FIFO usedw ports (Default: 8)
//
// Host rules:
//   read_length must equal ScBl for each SDRAM read transaction.
//   write_length may be 1 when ScSingleWrite=1 (burst read + single write).
//   write_length must equal ScBl when ScSingleWrite=0.
//
// Dependencies:
//   - sdram_command.sv
//   - sdram_control_interface.sv
//   - sdram_data_path.sv
//   - sdram_write_fifo.v
//   - sdram_read_fifo.v
// ============================================================================
// Revision History:
//   Current - External clk_host_i / clk_sdram_i; PLL moved to sdram_clock_gen.sv.
// ============================================================================

module sdram_controller #(
  parameter int unsigned RowStart      = 9,
  parameter int unsigned RowSize       = 13,
  parameter int unsigned ColStart      = 0,
  parameter int unsigned ColSize       = 9,
  parameter int unsigned BankStart     = 22,
  parameter int unsigned BankSize      = 2,
  parameter int unsigned SaSize        = 13,
  parameter int unsigned AddrSize      = 24,
  parameter int unsigned DataWidth     = 16,
  parameter int unsigned InitPer       = 24000,
  parameter int unsigned RefPer        = 1024,
  parameter int unsigned ScCl          = 3,
  parameter int unsigned ScRcd         = 3,
  parameter int unsigned ScRrd         = 7,
  parameter int unsigned ScPm          = 0,
  parameter int unsigned ScBl          = 8,
  parameter int unsigned ScSingleWrite = 1,
  parameter int unsigned MaxBurstLen   = 8
) (
  input  logic                         clk_host_i,
  input  logic                         clk_sdram_i,
  input  logic                         rst_ni,
  input  logic [DataWidth-1:0]         write_data_i,
  input  logic                         write_request_i,
  input  logic [AddrSize-1:0]          write_addr_i,
  input  logic [8:0]                   write_length_i,
  input  logic                         write_load_i,
  output logic                         write_full_o,
  output logic [15:0]                  write_used_o,
  output logic [DataWidth-1:0]         read_data_o,
  input  logic                         read_request_i,
  input  logic [AddrSize-1:0]          read_addr_i,
  input  logic [8:0]                   read_length_i,
  input  logic                         read_load_i,
  output logic                         read_empty_o,
  output logic [15:0]                  read_used_o,
  output logic [SaSize-1:0]            sdram_addr_o,
  output logic [1:0]                   sdram_ba_o,
  output logic                         sdram_cas_n_o,
  output logic                         sdram_cke_o,
  output logic                         sdram_clk_o,
  output logic                         sdram_cs_n_o,
  inout  wire  [DataWidth-1:0]         sdram_dq_io,
  output logic [DataWidth/8-1:0]       sdram_dqm_o,
  output logic                         sdram_ras_n_o,
  output logic                         sdram_we_n_o
);

  localparam logic [AddrSize-1:0]  MaxAddr        = {AddrSize{1'b1}};
  localparam logic [SaSize-1:0]    PmPrechargeSa  = 13'h200;
  localparam int unsigned          FifoUsedWidth  = $clog2(MaxBurstLen + 1);
  localparam int unsigned          HostUsedPad   = 16 - FifoUsedWidth;

  logic [AddrSize-1:0] maddr_q;
  logic [8:0]          mlength_q;
  logic [AddrSize-1:0] rwr_addr_q;
  logic [AddrSize-1:0] rrd_addr_q;
  logic              wr_mask_q;
  logic              rd_mask_q;
  logic              mwr_done_q;
  logic              mrd_done_q;
  logic              mwr_q;
  logic              pre_wr_q;
  logic              mrd_q;
  logic              pre_rd_q;
  logic [9:0]        st_q;
  logic [1:0]        cmd_q;
  logic              pm_stop_q;
  logic              pm_done_q;
  logic              read_active_q;
  logic              write_active_q;
  logic [DataWidth-1:0] mdataout_q;

  logic [DataWidth-1:0] mdatin;
  logic                 cmdack;

  logic [DataWidth/8-1:0] dqm_q;
  logic [SaSize-1:0]      sa_q;
  logic [1:0]             ba_q;
  logic [1:0]             cs_n_q;
  logic                   cke_q;
  logic                   ras_n_q;
  logic                   cas_n_q;
  logic                   we_n_q;

  logic [DataWidth-1:0]   dqout;
  logic [DataWidth/8-1:0] idqm;
  logic [SaSize-1:0]      isa;
  logic [1:0]             iba;
  logic [1:0]             ics_n;
  logic                   icke;
  logic                   iras_n;
  logic                   icas_n;
  logic                   iwe_n;

  logic              out_valid_q;
  logic              in_req_q;
  logic [FifoUsedWidth-1:0] write_side_fifo_rusedw;
  logic [FifoUsedWidth-1:0] read_side_fifo_wusedw;
  logic [FifoUsedWidth-1:0] write_fifo_wrusedw;
  logic [FifoUsedWidth-1:0] read_fifo_rdusedw;

  logic [AddrSize-1:0] saddr;
  logic              load_mode;
  logic              nop;
  logic              reada;
  logic              writea;
  logic              refresh;
  logic              precharge;
  logic              oe;
  logic              ref_ack;
  logic              ref_req;
  logic              init_req;
  logic              cm_ack;
  logic              active;

  logic flag_q;

  assign sdram_clk_o   = clk_sdram_i;

  assign sdram_addr_o  = sa_q;
  assign sdram_ba_o    = ba_q;
  assign sdram_cs_n_o  = cs_n_q[0];
  assign sdram_cke_o   = cke_q;
  assign sdram_ras_n_o = ras_n_q;
  assign sdram_cas_n_o = cas_n_q;
  assign sdram_we_n_o  = we_n_q;
  assign sdram_dqm_o   = dqm_q;

  control_interface #(
    .AddrSize(AddrSize),
    .InitPer(InitPer),
    .RefPer(RefPer)
  ) control1 (
    .clk_i(clk_sdram_i),
    .rst_ni(rst_ni),
    .cmd_i(cmd_q),
    .addr_i(maddr_q),
    .ref_ack_i(ref_ack),
    .init_ack_i(1'b0),
    .cm_ack_i(cm_ack),
    .nop_o(nop),
    .reada_o(reada),
    .writea_o(writea),
    .refresh_o(refresh),
    .precharge_o(precharge),
    .load_mode_o(load_mode),
    .saddr_o(saddr),
    .ref_req_o(ref_req),
    .init_req_o(init_req),
    .cmd_ack_o(cmdack)
  );

  command #(
    .RowStart(RowStart),
    .RowSize(RowSize),
    .ColStart(ColStart),
    .ColSize(ColSize),
    .BankStart(BankStart),
    .BankSize(BankSize),
    .SaSize(SaSize),
    .AddrSize(AddrSize),
    .ScCl(ScCl),
    .ScRcd(ScRcd),
    .ScRrd(ScRrd),
    .ScPm(ScPm),
    .ScBl(ScBl),
    .ScSingleWrite(ScSingleWrite)
  ) command1 (
    .clk_i(clk_sdram_i),
    .rst_ni(rst_ni),
    .saddr_i(saddr),
    .nop_i(nop),
    .reada_i(reada),
    .writea_i(writea),
    .refresh_i(refresh),
    .load_mode_i(load_mode),
    .precharge_i(precharge),
    .ref_req_i(ref_req),
    .init_req_i(init_req),
    .ref_ack_o(ref_ack),
    .cm_ack_o(cm_ack),
    .oe_o(oe),
    .pm_stop_i(pm_stop_q),
    .pm_done_i(pm_done_q),
    .sa_o(isa),
    .ba_o(iba),
    .cs_n_o(ics_n),
    .cke_o(icke),
    .ras_n_o(iras_n),
    .cas_n_o(icas_n),
    .we_n_o(iwe_n)
  );

  sdr_data_path #(
    .DataWidth(DataWidth)
  ) data_path1 (
    .clk_i(clk_sdram_i),
    .rst_ni(rst_ni),
    .data_in_i(mdatin),
    .dm_i({(DataWidth/8){1'b0}}),
    .dq_out_o(dqout),
    .dqm_o(idqm)
  );

  // Wizard IP: port names unchanged
  sdram_write_fifo write_fifo1 (
    .data(write_data_i),
    .wrreq(write_request_i),
    .wrclk(clk_host_i),
    .aclr(!rst_ni),
    .rdreq(in_req_q & wr_mask_q),
    .rdclk(clk_sdram_i),
    .q(mdatin),
    .wrfull(write_full_o),
    .wrusedw(write_fifo_wrusedw),
    .rdusedw(write_side_fifo_rusedw)
  );

  assign write_used_o = {{HostUsedPad{1'b0}}, write_fifo_wrusedw};

  sdram_read_fifo read_fifo1 (
    .data(mdataout_q),
    .wrreq(out_valid_q & rd_mask_q),
    .wrclk(clk_sdram_i),
    .aclr(!rst_ni),
    .rdreq(read_request_i),
    .rdclk(clk_host_i),
    .q(read_data_o),
    .wrusedw(read_side_fifo_wusedw),
    .rdempty(read_empty_o),
    .rdusedw(read_fifo_rdusedw)
  );

  assign read_used_o = {{HostUsedPad{1'b0}}, read_fifo_rdusedw};

  always_ff @(posedge clk_sdram_i or negedge rst_ni) begin
    if (!rst_ni)
      flag_q <= 1'b0;
    else if (write_side_fifo_rusedw == write_length_i)
      flag_q <= 1'b1;
  end

  always_ff @(posedge clk_sdram_i) begin
    sa_q    <= (st_q == ScCl + mlength_q) ? PmPrechargeSa : isa;
    ba_q    <= iba;
    cs_n_q  <= ics_n;
    cke_q   <= icke;
    ras_n_q <= (st_q == ScCl + mlength_q) ? 1'b0 : iras_n;
    cas_n_q <= (st_q == ScCl + mlength_q) ? 1'b1 : icas_n;
    we_n_q  <= (st_q == ScCl + mlength_q) ? 1'b0 : iwe_n;
    pm_stop_q <= (st_q == ScCl + mlength_q);
    pm_done_q <= (st_q == ScCl + ScRcd + mlength_q + 2);
    dqm_q   <= (active && (st_q >= ScCl))
        ? (((st_q == ScCl + mlength_q) && write_active_q) ? {(DataWidth/8){1'b1}}
                                                         : {(DataWidth/8){1'b0}})
        : {(DataWidth/8){1'b1}};
    mdataout_q <= sdram_dq_io;
  end

  assign sdram_dq_io = oe ? dqout : {DataWidth{1'bz}};
  assign active = read_active_q | write_active_q;

  always_ff @(posedge clk_sdram_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_q           <= 2'b00;
      st_q            <= 10'd0;
      pre_rd_q        <= 1'b0;
      pre_wr_q        <= 1'b0;
      read_active_q   <= 1'b0;
      write_active_q  <= 1'b0;
      out_valid_q     <= 1'b0;
      in_req_q        <= 1'b0;
      mwr_done_q      <= 1'b0;
      mrd_done_q      <= 1'b0;
    end else begin
      pre_rd_q <= mrd_q;
      pre_wr_q <= mwr_q;

      case (st_q)
        10'd0: begin
          if ({pre_rd_q, mrd_q} == 2'b01) begin
            read_active_q  <= 1'b1;
            write_active_q <= 1'b0;
            cmd_q          <= 2'b01;
            st_q           <= 10'd1;
          end else if ({pre_wr_q, mwr_q} == 2'b01) begin
            read_active_q  <= 1'b0;
            write_active_q <= 1'b1;
            cmd_q          <= 2'b10;
            st_q           <= 10'd1;
          end
        end
        10'd1: begin
          if (cmdack) begin
            cmd_q <= 2'b00;
            st_q  <= 10'd2;
          end
        end
        default: begin
          if (st_q != ScCl + ScRcd + mlength_q + 1)
            st_q <= st_q + 10'd1;
          else
            st_q <= 10'd0;
        end
      endcase

      if (read_active_q) begin
        if (st_q == ScCl + ScRcd + 1)
          out_valid_q <= 1'b1;
        else if (st_q == ScCl + ScRcd + mlength_q + 1) begin
          out_valid_q   <= 1'b0;
          read_active_q <= 1'b0;
          mrd_done_q    <= 1'b1;
        end
      end else
        mrd_done_q <= 1'b0;

      if (write_active_q) begin
        if (st_q == ScCl - 1)
          in_req_q <= 1'b1;
        else if (st_q == ScCl + mlength_q - 1)
          in_req_q <= 1'b0;
        else if (st_q == ScCl + ScRcd + mlength_q) begin
          write_active_q <= 1'b0;
          mwr_done_q     <= 1'b1;
        end
      end else
        mwr_done_q <= 1'b0;
    end
  end

  always_ff @(posedge clk_sdram_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rwr_addr_q <= write_addr_i;
      rrd_addr_q <= read_addr_i;
    end else begin
      if (write_load_i)
        rwr_addr_q <= write_addr_i;
      else if (mwr_done_q & wr_mask_q) begin
        if (rwr_addr_q <= MaxAddr - write_length_i)
          rwr_addr_q <= rwr_addr_q + write_length_i;
        else
          rwr_addr_q <= write_addr_i;
      end

      if (read_load_i)
        rrd_addr_q <= read_addr_i;
      else if (mrd_done_q & rd_mask_q) begin
        if (rrd_addr_q <= MaxAddr - read_length_i)
          rrd_addr_q <= rrd_addr_q + read_length_i;
        else
          rrd_addr_q <= read_addr_i;
      end
    end
  end

  always_ff @(posedge clk_sdram_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mwr_q      <= 1'b0;
      mrd_q      <= 1'b0;
      maddr_q    <= '0;
      mlength_q  <= 9'd0;
      wr_mask_q  <= 1'b0;
      rd_mask_q  <= 1'b0;
    end else begin
      if (!mwr_q && !mrd_q && (st_q == 10'd0) && !wr_mask_q && !rd_mask_q &&
          !write_load_i && !read_load_i && flag_q) begin
        if ((write_side_fifo_rusedw >= write_length_i) && (write_length_i != 9'd0)) begin
          maddr_q   <= rwr_addr_q;
          mlength_q <= write_length_i;
          wr_mask_q <= 1'b1;
          rd_mask_q <= 1'b0;
          mwr_q     <= 1'b1;
          mrd_q     <= 1'b0;
        end else if (read_side_fifo_wusedw < read_length_i) begin
          maddr_q   <= rrd_addr_q;
          mlength_q <= read_length_i;
          wr_mask_q <= 1'b0;
          rd_mask_q <= 1'b1;
          mwr_q     <= 1'b0;
          mrd_q     <= 1'b1;
        end
      end

      if (mwr_done_q) begin
        wr_mask_q <= 1'b0;
        mwr_q     <= 1'b0;
      end

      if (mrd_done_q) begin
        rd_mask_q <= 1'b0;
        mrd_q     <= 1'b0;
      end
    end
  end

endmodule
