// megafunction wizard: %FIFO%
// GENERATION: STANDARD
// VERSION: WM1.0
// MODULE: dcfifo

// ============================================================
// File Name: sdram_read_fifo.v
// Megafunction Name(s):
// 			dcfifo
//
// Simulation Library Files(s):
// 			altera_mf
// ============================================================
// Depth 16 / 4-bit usedw — supports SDRAM burst lengths up to 8.
// Regenerate via Quartus FIFO wizard if retargeting device family.
// ============================================================

// synopsys translate_off
`timescale 1 ps / 1 ps
// synopsys translate_on
module sdram_read_fifo (
	aclr,
	data,
	rdclk,
	rdreq,
	wrclk,
	wrreq,
	q,
	rdempty,
	rdusedw,
	wrfull,
	wrusedw);

	input	  aclr;
	input	[15:0]  data;
	input	  rdclk;
	input	  rdreq;
	input	  wrclk;
	input	  wrreq;
	output	[15:0]  q;
	output	  rdempty;
	output	[3:0]  rdusedw;
	output	  wrfull;
	output	[3:0]  wrusedw;
`ifndef ALTERA_RESERVED_QIS
// synopsys translate_off
`endif
	tri0	  aclr;
`ifndef ALTERA_RESERVED_QIS
// synopsys translate_on
`endif

	wire [15:0] sub_wire0;
	wire  sub_wire1;
	wire [3:0] sub_wire2;
	wire  sub_wire3;
	wire [3:0] sub_wire4;
	wire [15:0] q = sub_wire0[15:0];
	wire  rdempty = sub_wire1;
	wire [3:0] rdusedw = sub_wire2[3:0];
	wire  wrfull = sub_wire3;
	wire [3:0] wrusedw = sub_wire4[3:0];

	dcfifo	dcfifo_component (
				.aclr (aclr),
				.data (data),
				.rdclk (rdclk),
				.rdreq (rdreq),
				.wrclk (wrclk),
				.wrreq (wrreq),
				.q (sub_wire0),
				.rdempty (sub_wire1),
				.rdusedw (sub_wire2),
				.wrfull (sub_wire3),
				.wrusedw (sub_wire4),
				.eccstatus (),
				.rdfull (),
				.wrempty ());
	defparam
		dcfifo_component.intended_device_family = "Cyclone IV GX",
		dcfifo_component.lpm_hint = "RAM_BLOCK_TYPE=M9K",
		dcfifo_component.lpm_numwords = 16,
		dcfifo_component.lpm_showahead = "OFF",
		dcfifo_component.lpm_type = "dcfifo",
		dcfifo_component.lpm_width = 16,
		dcfifo_component.lpm_widthu = 4,
		dcfifo_component.overflow_checking = "ON",
		dcfifo_component.rdsync_delaypipe = 4,
		dcfifo_component.read_aclr_synch = "OFF",
		dcfifo_component.underflow_checking = "ON",
		dcfifo_component.use_eab = "ON",
		dcfifo_component.write_aclr_synch = "OFF",
		dcfifo_component.wrsync_delaypipe = 4;


endmodule
