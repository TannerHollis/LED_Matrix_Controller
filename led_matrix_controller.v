module led_matrix_controller 
	#( 
		parameter ADDRESS_WIDTH = 25,
		parameter PIXELS_PER_ROW = 10,
		parameter ROWS = 8
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

// Define clock IO
input clk;
input clk_pixel;
input clk_pwm;

output reg [ADDRESS_WIDTH - 1:0] address_fifo;
output wr_fifo;
input [7:0] data_in_fifo;
input data_in_ready_fifo;
output reg data_out_ready_fifo;
input fifo_full;

// Define data IO
output reg [ROWS - 1:0]r0;
output reg [ROWS - 1:0]r1;
output reg [ROWS - 1:0]g0;
output reg [ROWS - 1:0]g1;
output reg [ROWS - 1:0]b0;
output reg [ROWS - 1:0]b1;
output led_clk;
output reg strobe;
output reg oe;
output reg [4:0] line_select;

// Reset active low
input reset_n;

// Define pixel colors, double-buffered = pixel | n or n+16 | row | line_buffer
reg [7:0] rgb [PIXELS_PER_ROW - 1:0][1:0][ROWS - 1:0][1:0];
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
reg [11:0] pixel_count;
reg [11:0] pixels_loaded;
reg [11:0] pixels_reqd;
	
// Define Clock domain crossing registers
reg [1:0] q_clk_pwm;
reg [1:0] q_clk_pixel;

// Define pwm shift register
reg [2:0] pwm;

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
				if(q_clk_pwm == 3'b01) begin // Rising edge of pwm clock
					state <= MATRIX_PUSHING_PIXELS;
					oe <= 1'b1;
				end
				else if(pixels_loaded == PIXELS_PER_ROW - 1) begin
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
				if (pixel_count == PIXELS_PER_ROW - 1) begin
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

// Shift data out logic
genvar i;
generate
	for (i = 0; i < ROWS ; i = i + 1) begin : color_output
		always @ (posedge clk or negedge reset_n) begin
			if(reset_n == 1'b0) begin
				r0[i] <= 0;
				r1[i] <= 0;
				g0[i] <= 0;
				g1[i] <= 0;
				b0[i] <= 0;
				b1[i] <= 0;
			end
			else begin
				if(q_clk_pixel == 3'b10) begin // Falling edge of pixel clock
					r0[i] <= rgb[pixel_count][0][i][line_buffer][7:5] > pwm;
					r1[i] <= rgb[pixel_count][1][i][line_buffer][7:5] > pwm;
					g0[i] <= rgb[pixel_count][0][i][line_buffer][4:2] > pwm;
					g1[i] <= rgb[pixel_count][1][i][line_buffer][4:2] > pwm;
					b0[i] <= rgb[pixel_count][0][i][line_buffer][1:0] > pwm;
					b1[i] <= rgb[pixel_count][1][i][line_buffer][1:0] > pwm;
				end
			end
		end
	end
endgenerate
	
// RGB/Pixel counter logic
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		pixel_count <= 0;
	end
	else begin
		if(state == MATRIX_PUSHING_PIXELS) begin
			if(q_clk_pixel == 3'b01 && led_clk_en == 1'b1) begin // Rising edge of pixel clock
				pixel_count <= pixel_count + 1;
			end
			else begin
				// Do nothing...
			end
		end
		else begin
			pixel_count <= 0;
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
localparam [2:0] PWM_MAX = 7;

// PWM clock logic
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		line_select <= 0;
		pwm <= 0;
		line_buffer <= 1'b0;
	end
	else begin
		if(q_clk_pwm == 3'b01) begin // Rising edge of pwm clock
			if(pwm == PWM_MAX) begin
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
reg flip_out;
reg line_buffer_load;
reg [4:0] line_select_load;
reg [3:0] row_count_out;
reg [ADDRESS_WIDTH - 1:0] address_base;
localparam ADDRESS_START = 0;
localparam ADDRESS_FLIP_OFFSET = PIXELS_PER_ROW * 16;

// Pixel RAM read req logic
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		flip_out <= 0;
		row_count_out <= 0;
		pixels_reqd <= 0;		
		address_base <= ADDRESS_START + PIXELS_PER_ROW;
		line_buffer_load <= 1'b1;
		line_select_load <= 1;
	end
	else begin
		if(pixels_reqd != (PIXELS_PER_ROW )) begin
			if(fifo_full == 1'b0) begin
				if(flip_out == 1'b1) begin
					if(row_count_out == ROWS - 1) begin
						row_count_out <= 0;
						address_fifo <= address_base + 1;
						address_base <= address_base + 1;
						pixels_reqd <= pixels_reqd + 1;
					end
					else begin
						row_count_out <= row_count_out + 1;
						address_fifo <= address_fifo + ADDRESS_FLIP_OFFSET;
					end
				end
				else begin
					address_fifo <= address_fifo + ADDRESS_FLIP_OFFSET;
				end
				
				flip_out <= ~flip_out;
				data_out_ready_fifo <= 1'b1;
			end
			else begin
				data_out_ready_fifo <= 1'b0;
			end
		end
		else begin
			if(line_buffer_load == line_buffer) begin
				// Do nothing...
			end
			else begin
				pixels_reqd <= 0;
				if(line_select_load == 15) begin
					line_select_load <= 0;
					address_base <= ADDRESS_START + PIXELS_PER_ROW;
					address_fifo <= ADDRESS_START;
				end
				else begin
					address_base <= address_base;
					address_fifo <= address_base;
					line_select_load <= line_select_load + 1;
				end
				row_count_out <= 0;
				flip_out <= 1'b0;
				line_buffer_load <= ~line_buffer_load;
			end
			data_out_ready_fifo <= 1'b0;
		end
	end
end

// Pixel RAM read loaded logic
reg flip_in;
reg [3:0] row_count_in;

always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		flip_in <= 0;
		row_count_in <= 0;
		pixels_loaded <= 0;
	end
	else begin
		if(pixels_loaded != (PIXELS_PER_ROW)) begin
			if(data_in_ready_fifo == 1'b1) begin
				if(flip_in == 1'b1) begin
					if(row_count_in == ROWS - 1) begin
						row_count_in <= 0;
						pixels_loaded <= pixels_loaded + 1;
					end
					else begin
						row_count_in <= row_count_in + 1;
					end
				end
				else begin
					// Do nothing... 
				end
				
				flip_in <= ~flip_in;
				rgb[pixels_loaded][flip_in][row_count_in][line_buffer_load] <= data_in_fifo;
			end
		end
		else begin
			pixels_loaded <= 0;
			row_count_in <= 0;
			flip_in <= 1'b0;
		end
	end
end

assign wr_fifo = 1'b0;
assign led_clk = clk_pixel & led_clk_en;

endmodule