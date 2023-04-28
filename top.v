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
localparam ADDRESS_WIDTH = 25;
localparam ROWS = 1;
localparam MEMORY_ARBITER_PERIPHERALS = 2;
	
// Define signals
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

// Define memory arbiter IO
wire [7:0] data_out_mem;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] data_out_ready_mem;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] fifo_full_mem;

// Define PLL IO
wire clk_sys;
wire clk_led_driver;
wire clk_pixel;
wire clk_pwm;

// inclk = 50MHz, c0 = 60MHz, c1 = 20MHz
pll 
	pll
	(
		.inclk0(clk_in),
		.c0(clk_sys),
		.c1(clk_pixel),
		.c2(clk_led_driver)
	);

// inclk = 50MHz, c0 = 15.36 kHz
pll_pwm 
	pll_pwm
	(
		.inclk0(clk_in),
		.c0(clk_pwm),
	);

// Define SPI slave IO
wire [7:0] data_out;
wire [7:0] byte_count;	

spi_slave 
	#(
		.SPI_MODE(0)
	)
	spi_slave
   (
		// Control/Data Signals,
		.i_Rst_L(reset_n),    		// FPGA Reset, active low
		.i_Clk(clk_sys),      			// FPGA Clock
		.o_RX_DV(data_ready_rx),   // Data Valid pulse (1 clock cycle)
		.o_RX_Byte(data_out),  		// Byte received on MOSI
		.o_RX_Byte_Count(byte_count),
		.i_TX_DV(data_ready_tx),   // Data Valid pulse to register i_TX_Byte
		.i_TX_Byte(),  				// Byte to serialize to MISO.

		// SPI Interface
		.i_SPI_Clk(sck),
		.o_SPI_MISO(miso),
		.i_SPI_MOSI(mosi),
		.i_SPI_CS_n(cs_n)        	// active low
   );

wire [ADDRESS_WIDTH - 1:0] address_dc;
wire wr_dc;
wire [7:0] data_out_dc;
wire data_out_ready_dc;

device_controller 
	device_controller
	(
		// Clock IO
		.clk(clk_sys),
		
		// Data IO
		.data_in(data_out),
		.data_in_ready(data_ready_rx),
		.data_in_count(byte_count),
		
		// Memory interface
		.address_mem(address_dc),
		.wr_mem(wr_dc),
		.fifo_full_mem(fifo_full_mem[1]),
		.data_in_mem(data_out_mem),
		.data_in_ready_mem(data_out_ready_mem[1]),
		.data_out_mem(data_out_dc),
		.data_out_ready_mem(data_out_ready_dc),
		
		// General IO
		.cs_n(cs_n),
		.reset_n(reset_n)
	);

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

memory_arbiter 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.PERIPHERALS(MEMORY_ARBITER_PERIPHERALS),
		.PERIPHERALS_FIFO_DEPTH(32),
		.FIFO_DEPTH(2)
	)
	memory_arbiter
	(
		.clk(clk_sys),
		.address({ address_dc, address_led }),
		.wr({ wr_dc, wr_led }),
		.fifo_full(fifo_full_mem),
		
		.data_in({ data_out_dc, 8'd0 }),
		.data_in_ready({data_out_ready_dc, data_out_ready_led }),
		
		.data_out(data_out_mem),
		.data_out_ready(data_out_ready_mem),
	
		.reset_n(reset_n)
	);
	
endmodule
