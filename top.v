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

localparam ADDRESS_WIDTH = 14;
localparam DATA_WIDTH = 16;
localparam PIXELS_PER_ROW = 512;
localparam ROWS = 1;
localparam MEMORY_ARBITER_PERIPHERALS = 1 + ROWS;
	
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
wire [DATA_WIDTH - 1:0] data_out_mem;
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

// Define memory arbiter combined signals
wire [ADDRESS_WIDTH * MEMORY_ARBITER_PERIPHERALS - 1:0] address_mem_arb;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] wr_mem_arb;
wire [DATA_WIDTH * MEMORY_ARBITER_PERIPHERALS - 1:0] data_in_mem_arb;
wire [MEMORY_ARBITER_PERIPHERALS - 1:0] data_in_ready_mem_arb;	

// Define SPI slave Outputs
wire [7:0] data_out_spi;
wire data_out_ready_spi;

spi_slave spi_slave(
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
wire [DATA_WIDTH - 1:0] data_out_dc;
wire data_out_ready_dc;
wire frame_buffer_select;
wire color_format;
wire [9:0] pixels_per_row_out;
wire [3:0] panel_rows_out;

device_controller 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
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
		.fifo_full_mem(fifo_full_mem[0]),
		.data_in_mem(data_out_mem),
		.data_in_ready_mem(data_out_ready_mem[0]),
		.data_out_mem(data_out_dc),
		.data_out_ready_mem(data_out_ready_dc),
		
		// Register interface
		.frame_buffer_select(frame_buffer_select),
		.color_format(color_format),
		.pixels_per_row(pixels_per_row_out),
		.panel_rows(panel_rows_out),
		
		// General IO
		.cs_n(cs_n),
		.reset_n(reset_n)
	);

// Assign Device Controller signals to the Memory Arbiter
assign address_mem_arb[ADDRESS_WIDTH - 1: 0] = address_dc;
assign wr_mem_arb[0] = wr_dc;
assign data_in_mem_arb[DATA_WIDTH - 1: 0] = data_out_dc;
assign data_in_ready_mem_arb[0] = data_out_ready_dc;

	
// Define LED Matrix Controller Outputs
wire [ADDRESS_WIDTH * ROWS - 1:0] address_led;
wire [ROWS - 1:0] wr_led;
wire [ROWS - 1:0] data_out_ready_led;

// Instantiate LED Matrix Controller modules
genvar i;
generate
	for(i = 0; i < ROWS; i = i + 1) begin : led_matrix_controller_inst
		if(i == 0) begin
			led_matrix_controller 
			#(
				.ADDRESS_WIDTH(ADDRESS_WIDTH),
				.DATA_WIDTH(DATA_WIDTH),
				.PIXELS_PER_ROW(PIXELS_PER_ROW),
				.ROW(i),
				.ROWS_TOTAL(ROWS)
			)
			led_matrix
			(
				.clk(clk_sys),
				.clk_pixel(clk_pixel),
				.clk_pwm(clk_pwm),
				
				// FIFO IO
				.address_fifo(address_led[ADDRESS_WIDTH * (i + 1) - 1:ADDRESS_WIDTH * i]),
				.wr_fifo(wr_led[i]),
				.data_in_fifo(data_out_mem),
				.data_in_ready_fifo(data_out_ready_mem[i + 1]),
				.data_out_ready_fifo(data_out_ready_led[i]),
				.fifo_full(fifo_full_mem[i]),
				
				.frame_buffer_select(frame_buffer_select),
				.color_format(color_format),
				.pixels_per_row_in(pixels_per_row_out),
				
				.r0(r0[i]),
				.r1(r1[i]),
				.g0(g0[i]),
				.g1(g1[i]),
				.b0(b0[i]),
				.b1(b1[i]),

				.led_clk(led_clk),
				.strobe(stb),
				.oe(oe),
				.line_select(line_select),
				
				.reset_n(reset_n)
			);
		end
		else begin
			led_matrix_controller 
			#(
				.ADDRESS_WIDTH(ADDRESS_WIDTH),
				.DATA_WIDTH(DATA_WIDTH),
				.PIXELS_PER_ROW(PIXELS_PER_ROW),
				.ROW(i),
				.ROWS_TOTAL(ROWS)
			)
			led_matrix
			(
				.clk(clk_sys),
				.clk_pixel(clk_pixel),
				.clk_pwm(clk_pwm),
				
				// FIFO IO
				.address_fifo(address_led[ADDRESS_WIDTH * (i + 1) - 1:ADDRESS_WIDTH * i]),
				.wr_fifo(wr_led[i]),
				.data_in_fifo(data_out_mem),
				.data_in_ready_fifo(data_out_ready_mem[i + 1]),
				.data_out_ready_fifo(data_out_ready_led[i]),
				.fifo_full(fifo_full_mem[i]),
				
				.frame_buffer_select(frame_buffer_select),
				.color_format(color_format),
				.pixels_per_row_in(pixels_per_row_out),
				
				.r0(r0[i]),
				.r1(r1[i]),
				.g0(g0[i]),
				.g1(g1[i]),
				.b0(b0[i]),
				.b1(b1[i]),

				.led_clk(),
				.strobe(),
				.oe(),
				.line_select(),
				
				.reset_n(reset_n)
			);
		end
		
		// Assign LED Matrix Controller signals to the Memory Arbiter
		assign address_mem_arb[(i + 2) * ADDRESS_WIDTH - 1: ADDRESS_WIDTH * (i + 1)] = address_led[(i + 1) * ADDRESS_WIDTH - 1: ADDRESS_WIDTH * i];
		assign wr_mem_arb[i + 1] = wr_led[i];
		assign data_in_mem_arb[(i + 2) * DATA_WIDTH - 1: DATA_WIDTH * (i + 1)] = {DATA_WIDTH{1'b0}};
		assign data_in_ready_mem_arb[i + 1] = data_out_ready_led[i];
	end
endgenerate

memory_arbiter 
	#(
		.ADDRESS_WIDTH(ADDRESS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH),
		.PERIPHERALS(MEMORY_ARBITER_PERIPHERALS),
		.PERIPHERALS_FIFO_DEPTH(16),
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
