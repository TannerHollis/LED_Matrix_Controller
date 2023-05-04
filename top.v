module top(
	// SPI IO
	sck,
	cs_n,
	mosi,
	miso,	
	
	//LED Matrix IO
	r0,
	r1,
	g0,
	g1,
	b0,
	b1,
	line_select,
	stb,
	oe,
	led_clk,
	
	// Universal IO
	reset_n,
	clk_in
	);

localparam PIXELS_PER_ROW = 256;
localparam ADDRESS_WIDTH = 14;
localparam ROWS = 1;
localparam MEMORY_ARBITER_PERIPHERALS = 2;
	
// Define device IO
input sck;
input cs_n;
input mosi;
output miso;

output [ROWS - 1:0] r0;
output [ROWS - 1:0] r1;
output [ROWS - 1:0] g0;
output [ROWS - 1:0] g1;
output [ROWS - 1:0] b0;
output [ROWS - 1:0] b1;
output [4:0] line_select;
output stb;
output oe;
output led_clk;

input reset_n;
input clk_in;

// Define memory arbiter Outputs
wire [7:0] data_out_mem;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] data_out_ready_mem;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] fifo_full_mem;

// Define PLL Outputs
wire clk_sys;
wire clk_device;
wire clk_pixel;
wire clk_pwm;

// inclk = 50MHz, c0 = 50MHz, c1 = 20MHz
pll 
	pll
	(
		.inclk0(clk_in),
		.c0(clk_sys),
		.c1(clk_pixel),
		.c2(clk_device)
	);

// inclk = 50MHz, c0 = 15.36 kHz
pll_pwm 
	pll_pwm
	(
		.inclk0(clk_in),
		.c0(clk_pwm)
	);

// Define SPI slave Outputs
wire [7:0] data_out_spi;
wire data_out_ready_spi;

//spi_slave 
//	#(
//		.SPI_MODE(0)
//	)
//	spi_slave
//   (
//		// Control/Data Signals,
//		.i_Rst_L(reset_n),    			// FPGA Reset, active low
//		.i_Clk(clk_sys),      			// FPGA Clock
//		.o_RX_DV(data_out_ready_spi), // Data Valid pulse (1 clock cycle)
//		.o_RX_Byte(data_out_spi),  	// Byte received on MOSI
//		.o_RX_Byte_Count(),	
//		.i_TX_DV(),   						// Data Valid pulse to register i_TX_Byte
//		.i_TX_Byte(),  					// Byte to serialize to MISO.
//
//		// SPI Interface
//		.i_SPI_Clk(sck),
//		.o_SPI_MISO(miso),
//		.i_SPI_MOSI(mosi),
//		.i_SPI_CS_n(cs_n)        		// active low
//   );

spi_slave0 spi_slave0(
	.reset_n(reset_n),
	.clk_sb(clk_sys),
	.clk_spi(sck),
	.mosi(mosi),
	.miso(miso),
	.cs_n(cs_n),
	
	.miso_tx(),
	.miso_data_in(),
	.miso_en(),
	
	.mosi_rx(data_out_ready_spi),
	.mosi_data_out(data_out_spi)
);

// Define Device Controller Outputs
wire [ADDRESS_WIDTH - 1:0] address_dc;
wire wr_dc;
wire [7:0] data_out_dc;
wire data_out_ready_dc;
wire frame_buffer_select;

device_controller 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH)
	)
	device_controller
	(
		// Clock IO
		.clk_sys(clk_sys),
		.clk_device(clk_device),
		
		// Data IO
		.data_in(data_out_spi),
		.data_in_ready(data_out_ready_spi),
		
		// Memory interface
		.address_mem(address_dc),
		.wr_mem(wr_dc),
		.fifo_full_mem(fifo_full_mem[1]),
		.data_in_mem(data_out_mem),
		.data_in_ready_mem(data_out_ready_mem[1]),
		.data_out_mem(data_out_dc),
		.data_out_ready_mem(data_out_ready_dc),
		
		// Register interface
		.frame_buffer_select(frame_buffer_select),
		
		// General IO
		.cs_n(cs_n),
		.reset_n(reset_n)
	);

// Define LED Matrix Controller Outputs
wire [ADDRESS_WIDTH - 1:0] address_led;
wire wr_led;
wire [7:0] data_in_led;
wire data_out_ready_led;
	
led_matrix_controller 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.PIXELS_PER_ROW(PIXELS_PER_ROW),
		.ROWS(ROWS)
	)
	led_matrix
	(
		.clk(clk_sys),
		.clk_pixel(clk_pixel),
		.clk_pwm(clk_pwm),
		
		// FIFO IO
		.address_fifo(address_led),
		.wr_fifo(wr_led),
		.data_in_fifo(data_out_mem),
		.data_in_ready_fifo(data_out_ready_mem[0]),
		.data_out_ready_fifo(data_out_ready_led),
		.fifo_full(fifo_full_mem[0]),
		
		.frame_buffer_select(frame_buffer_select),
		
		.r0(r0),
		.r1(r1),
		.g0(g0),
		.g1(g1),
		.b0(b0),
		.b1(b1),
		.led_clk(led_clk),
		.strobe(stb),
		.oe(oe),
		.line_select(line_select),
		
		.reset_n(reset_n)
	);

// Define memory arbiter combined signals
wire [ADDRESS_WIDTH * MEMORY_ARBITER_PERIPHERALS - 1:0] address_mem_arb;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] wr_mem_arb;
wire [8 * MEMORY_ARBITER_PERIPHERALS - 1:0] data_in_mem_arb;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] data_in_ready_mem_arb;

assign address_mem_arb = {address_dc, address_led};
assign wr_mem_arb = {wr_dc, wr_led};
assign data_in_mem_arb = {data_out_dc, 8'd0};
assign data_in_ready_mem_arb = {data_out_ready_dc, data_out_ready_led};

memory_arbiter 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.PERIPHERALS(MEMORY_ARBITER_PERIPHERALS),
		.PERIPHERALS_FIFO_DEPTH(8),
		.FIFO_DEPTH(4)
	)
	memory_arbiter
	(
		.clk(clk_sys),
		.address(address_mem_arb),
		.wr(wr_mem_arb),
		.fifo_full(fifo_full_mem),
		
		.data_in(data_in_mem_arb),
		.data_in_ready(data_in_ready_mem_arb),
		
		.data_out(data_out_mem),
		.data_out_ready(data_out_ready_mem),
	
		.reset_n(reset_n)
	);
	
endmodule
