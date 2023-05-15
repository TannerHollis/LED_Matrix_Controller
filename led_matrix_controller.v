module led_matrix_controller 
	#( 
		parameter ADDRESS_WIDTH = 25,
		parameter DATA_WIDTH = 16,
		parameter PIXELS_PER_ROW = 256,
		parameter ROW = 0,
		parameter ROWS_TOTAL = 1
	)
	(
		// Clock IO
		clk,
		clk_pixel,
		clk_pwm,
		
		// FIFO IO
		address_fifo,
		wr_fifo,
		data_in_fifo,
		data_in_ready_fifo,
		data_out_ready_fifo,
		fifo_full,
		
		// Frame Flip
		frame_buffer_select,
		color_format,
		pixels_per_row_in,
		
		// Color output
		r0,
		r1,
		g0,
		g1,
		b0,
		b1,
		led_clk,
		strobe,
		oe,
		line_select,
		
		// General IO
		reset_n
	);

localparam PIXELS_WIDTH = $clog2(PIXELS_PER_ROW);

// Define clock IO
input clk;
input clk_pixel;
input clk_pwm;

output reg [ADDRESS_WIDTH - 1:0] address_fifo;
output wr_fifo;
input [DATA_WIDTH - 1:0] data_in_fifo;
input data_in_ready_fifo;
output reg data_out_ready_fifo;
input fifo_full;

// Define frame buffer select
input frame_buffer_select;
input color_format; // 0 = RGB_332, 1 = RGB_565
input [9:0] pixels_per_row_in;

// Define data IO
output reg r0;
output reg r1;
output reg g0;
output reg g1;
output reg b0;
output reg b1;
output led_clk;
output reg strobe;
output reg oe;
output reg [4:0] line_select;

// Reset active low
input reset_n;

// Define pixel colors, double-buffered = pixel | n or n+16 | row | line_buffer
reg line_buffer;

// Define matrix state register and states
reg [2:0] state;
localparam [2:0]
	MATRIX_PREPARING_DATA = 0,
	MATRIX_WAITING = 1,
	MATRIX_PUSHING_PIXELS = 2,
	MATRIX_SET_LATCH = 3,
	MATRIX_CLEAR_LATCH = 4;

// Define pixel counter registers
reg [PIXELS_WIDTH:0] pixel_count;
reg [PIXELS_WIDTH - 1:0] pixels_loaded;
reg [PIXELS_WIDTH - 1:0] pixels_reqd;
	
// Define Clock domain crossing registers
reg [1:0] q_clk_pwm;
reg [1:0] q_clk_pixel;

// Define pwm shift register
reg [5:0] pwm;

// Define pixel clk enable
reg led_clk_en;

// Clock crossing logic
always @ (posedge clk or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		q_clk_pwm <= 0;
		q_clk_pixel <= 0;
	end
	else begin
		q_clk_pwm <= {q_clk_pwm[0], clk_pwm};
		q_clk_pixel <= {q_clk_pixel[0], clk_pixel};
	end
end
	
// Main state machine logic
always @ (posedge clk or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		state <= MATRIX_PREPARING_DATA;
		strobe <= 1'b0;
		oe <= 1'b0;
	end
	else begin
		case (state)
			MATRIX_PREPARING_DATA: begin
				if(pixels_loaded == pixels_per_row_in - 1) begin
					state <= MATRIX_WAITING;
				end
			end
			
			MATRIX_WAITING: begin
				if(q_clk_pwm == 3'b01) begin // Rising edge of pwm clock
					state <= MATRIX_PUSHING_PIXELS;
					oe <= 1'b1;
				end
			end
			
			MATRIX_PUSHING_PIXELS: begin
				if (pixel_count == pixels_per_row_in) begin
					state <= MATRIX_SET_LATCH;
				end
			end
			
			MATRIX_SET_LATCH: begin
				state <= MATRIX_CLEAR_LATCH;
				strobe <= 1'b1;
			end
			
			MATRIX_CLEAR_LATCH: begin
				state <= MATRIX_PREPARING_DATA;
				strobe <= 1'b0;
				oe <= 1'b0;
			end
			
		endcase
	end
end

// Color output data
localparam
	RGB_332 = 0,
	RGB_565 = 1;

// RGB data out from memory banks
reg [DATA_WIDTH - 1:0] rgb0;
reg [DATA_WIDTH - 1:0] rgb16;
wire [DATA_WIDTH - 1:0] data_out_0;
wire [DATA_WIDTH - 1:0] data_out_1;
wire [DATA_WIDTH - 1:0] data_out_2;
wire [DATA_WIDTH - 1:0] data_out_3;

always @ (negedge clk_pixel or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		r0 <= 0;
		r1 <= 0;
		g0 <= 0;
		g1 <= 0;
		b0 <= 0;
		b1 <= 0;
	end
	else begin
	case(color_format)
		RGB_332: begin
			r0 <= rgb0[7:5] > pwm;
			r1 <= rgb16[7:5] > pwm;
			g0 <= rgb0[4:2] > pwm;
			g1 <= rgb16[4:2] > pwm;
			b0 <= rgb0[1:0] > pwm;
			b1 <= rgb16[1:0] > pwm;
		end
		
		RGB_565: begin
			r0 <= rgb0[15:11] > pwm;
			r1 <= rgb16[15:11] > pwm;
			g0 <= rgb0[10:5] > pwm;
			g1 <= rgb16[10:5] > pwm;
			b0 <= rgb0[4:0] > pwm;
			b1 <= rgb16[4:0] > pwm;
		end
	endcase
	end
end
	
// RGB/Pixel counter logic
always @ (posedge clk_pixel or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		pixel_count <= 0;
		rgb0 <= 0;
		rgb16 <= 0;
	end
	else begin
		if(state == MATRIX_PUSHING_PIXELS) begin
			if(led_clk_en == 1'b1) begin // Rising edge of pixel clock
				pixel_count <= pixel_count + 1;
			end
			else begin
				// Do nothing...
			end
		end
		else begin
			pixel_count <= 0;
		end
		
		if(line_buffer == 1'b1) begin
			rgb0 <= data_out_2;
			rgb16 <= data_out_3;
		end
		else begin
			rgb0 <= data_out_0;
			rgb16 <= data_out_1;
		end
	end
end

// Pixel clock enable logic
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		led_clk_en <= 1'b0;
	end
	else begin
		if(q_clk_pixel == 3'b10) begin // Falling edge of pixel clock
			if(state == MATRIX_PUSHING_PIXELS) begin
				led_clk_en <= 1'b1;
			end
			else begin
				led_clk_en <= 1'b0;
			end
		end
		else begin
			// Do nothing...
		end
	end
end

// Define pwm registers
wire [5:0] pwm_max = color_format ? 63 : 7;

// PWM clock logic
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		line_select <= 0;
		pwm <= 0;
		line_buffer <= 1'b0;
	end
	else begin
		if(q_clk_pwm == 3'b01) begin // Rising edge of pwm clock
			if(pwm == pwm_max) begin
				pwm <= 0;
				line_buffer <= ~line_buffer;
				if (line_select == 15) begin
					line_select <= 0;
				end
				else begin
					line_select <= line_select + 1;
				end
			end
			else begin
				pwm <= pwm + 1;
			end
		end
	end
end

// Define RAM read registers
reg line_buffer_load;
reg [4:0] line_select_load;
reg [ADDRESS_WIDTH - 1:0] address_base;
reg [ADDRESS_WIDTH - 1:0] address_start;
reg [ADDRESS_WIDTH - 1:0] address_flip_row;
reg [ADDRESS_WIDTH - 1:0] address_flip_display;

// Calculate addressing parameters
always @ (posedge clk) begin
	address_flip_row <= pixels_per_row_in * 16;
	address_start <= pixels_per_row_in * 32 * ROW;
	address_flip_display <= pixels_per_row_in * 32 * ROWS_TOTAL;
end

// Define load pixel states
reg [2:0] req_state;
localparam [2:0]
	LOAD_INIT = 0,
	LOAD_IDLE = 1,
	LOAD_0 = 2,
	LOAD_1 = 3,
	LOAD_WAIT = 4;
	
// Pixel RAM read req logic
always @ (negedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		pixels_reqd <= 0;
		req_state <= LOAD_INIT;
		address_fifo <= address_start;
		address_base <= address_start;
		line_select_load <= 0;
		data_out_ready_fifo <= 1'b0;
	end
	else begin
		case(req_state)
			LOAD_INIT : begin
				data_out_ready_fifo <= 1'b1;
				req_state <= LOAD_0;
			end
		
			LOAD_IDLE : begin
				if(line_buffer_load != line_buffer) begin
					if(line_select_load == 15) begin
						line_select_load <= 0;
						address_fifo <= frame_buffer_select == 1'b0 ? address_start : address_start + address_flip_display;
						address_base <= frame_buffer_select == 1'b0 ? address_start : address_start + address_flip_display;
					end
					else begin
						line_select_load <= line_select_load + 1;
						address_fifo <= address_base;
						address_base <= address_base;
					end
					pixels_reqd <= 0;
					data_out_ready_fifo <= 1'b1;
					
					req_state <= LOAD_0;
				end
				else begin
					data_out_ready_fifo <= 1'b0;
				end
			end
			
			LOAD_0: begin
				if(fifo_full == 1'b0) begin
					address_fifo <= address_fifo + address_flip_row;
					req_state <= LOAD_1;
					data_out_ready_fifo <= 1'b1;
				end
				else begin
					data_out_ready_fifo <= 1'b0;
				end
			end
			
			LOAD_1: begin
				if(fifo_full == 1'b0) begin
					if(pixels_reqd == pixels_per_row_in - 1) begin
						pixels_reqd <= 0;
						req_state <= LOAD_WAIT; // Done loading pixels entire row
						data_out_ready_fifo <= 1'b0;
					end
					else begin
						pixels_reqd <= pixels_reqd + 1;
						req_state <= LOAD_0; // Load another row
						data_out_ready_fifo <= 1'b1;
					end
					address_fifo <= address_base + 1;
					address_base <= address_base + 1;
				end
				else begin
					data_out_ready_fifo <= 1'b0;
				end
			end
			
			LOAD_WAIT: begin
				req_state <= line_buffer_load == line_buffer ? LOAD_IDLE : req_state;
			end
		endcase
	end
end

// Pixel RAM read loaded logic
reg flip_in;
reg [2:0] read_state;
reg pixel_data_wr_0;
reg pixel_data_wr_16;
reg [DATA_WIDTH - 1:0] pixel_data_out;
reg [DATA_WIDTH - 1:0] pixel_data_in_0;
reg [DATA_WIDTH - 1:0] pixel_data_in_16;
reg [PIXELS_WIDTH - 1:0] pixel_data_write_address_0;
reg [PIXELS_WIDTH - 1:0] pixel_data_write_address_16;

always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		flip_in <= 0;
		read_state <= LOAD_INIT;
		pixels_loaded <= 0;
		line_buffer_load <= 1'b0;
		pixel_data_wr_0 <= 1'b0;
		pixel_data_wr_16 <= 1'b0;
		pixel_data_in_0 <= 0;
		pixel_data_in_16 <= 0;
		pixel_data_write_address_0 <= 0;
		pixel_data_write_address_16 <= 0;
	end
	else begin
		case(read_state)
			LOAD_INIT : begin
				if(data_in_ready_fifo == 1'b1) begin
					if(flip_in == 1'b1) begin
						if(pixels_loaded == pixels_per_row_in - 1) begin
							pixels_loaded <= 0;
							read_state <= LOAD_WAIT;
						end
						else begin
							pixels_loaded <= pixels_loaded + 1;
						end
						
						pixel_data_write_address_16 <= pixel_data_write_address_16 == pixels_per_row_in - 1 ? 0 : pixel_data_write_address_16 + 1;
						pixel_data_wr_16 <= 1'b1;
						pixel_data_wr_0 <= 1'b0;
						pixel_data_in_16 <= data_in_fifo;
					end
					else begin
						pixel_data_write_address_0 <= pixel_data_write_address_0 == pixels_per_row_in - 1 ? 0 : pixel_data_write_address_0 + 1;
						pixel_data_wr_0 <= 1'b1;
						pixel_data_wr_16 <= 1'b0;
						pixel_data_in_0 <= data_in_fifo;
					end
					
					flip_in <= ~flip_in;
				end
				else begin
					pixel_data_wr_0 <= 1'b0;
					pixel_data_wr_16 <= 1'b0;
				end
			end
			
			LOAD_WAIT : begin
				if(line_buffer_load == line_buffer) begin
					line_buffer_load <= ~line_buffer_load;
					read_state <= LOAD_INIT;
				end
			end
		endcase
	end
end



// Address shift register for memory write delay
reg [PIXELS_WIDTH - 1:0] pixel_data_write_address_0_sr;
reg [PIXELS_WIDTH - 1:0] pixel_data_write_address_16_sr;

always @ (posedge clk) begin
	pixel_data_write_address_0_sr <= pixel_data_write_address_0;
	pixel_data_write_address_16_sr <= pixel_data_write_address_16;
end

// Address multiplexer
wire [PIXELS_WIDTH - 1:0] address_bank_0 = line_buffer_load == 1'b0 ? pixel_data_write_address_0_sr : pixel_count;
wire [PIXELS_WIDTH - 1:0] address_bank_1 = line_buffer_load == 1'b0 ? pixel_data_write_address_16_sr : pixel_count;
wire [PIXELS_WIDTH - 1:0] address_bank_2 = line_buffer_load == 1'b1 ? pixel_data_write_address_0_sr : pixel_count;
wire [PIXELS_WIDTH - 1:0] address_bank_3 = line_buffer_load == 1'b1 ? pixel_data_write_address_16_sr : pixel_count;

// WREN multiplexer
wire wren_0 = line_buffer_load == 1'b0 ? pixel_data_wr_0 : 1'b0;
wire wren_1 = line_buffer_load == 1'b0 ? pixel_data_wr_16 : 1'b0;
wire wren_2 = line_buffer_load == 1'b1 ? pixel_data_wr_0 : 1'b0;
wire wren_3 = line_buffer_load == 1'b1 ? pixel_data_wr_16 : 1'b0;

assign wr_fifo = 1'b0;
assign led_clk = clk_pixel & led_clk_en;

// Define pixel data memory row 0, bank 0
single_port_ram 
	#(
		.ADDRESS_WIDTH(PIXELS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
	)
	single_port_ram_0
	(
		.clock(clk),
		.wren(wren_0),
		.address(address_bank_0),
		.data(pixel_data_in_0),
		.q(data_out_0)
	);

// Define pixel data memory row 16, bank 0
single_port_ram 
	#(
		.ADDRESS_WIDTH(PIXELS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
	)
	single_port_ram_1
	(
		.clock(clk),
		.wren(wren_1),
		.address(address_bank_1),
		.data(pixel_data_in_16),
		.q(data_out_1)
	);

// Define pixel data memory row 0, bank 1
single_port_ram 
	#(
		.ADDRESS_WIDTH(PIXELS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
	)
	single_port_ram_2
	(
		.clock(clk),
		.wren(wren_2),
		.address(address_bank_2),
		.data(pixel_data_in_0),
		.q(data_out_2)
	);

// Define pixel data memory row 16, bank 1
single_port_ram 
	#(
		.ADDRESS_WIDTH(PIXELS_WIDTH),
		.DATA_WIDTH(DATA_WIDTH)
	)
	single_port_ram_3
	(
		.clock(clk),
		.wren(wren_3),
		.address(address_bank_3),
		.data(pixel_data_in_16),
		.q(data_out_3)
	);
	
endmodule
