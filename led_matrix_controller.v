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
		
		// Frame Flip
		frame_buffer_select,
		
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

localparam ROWS_WIDTH = $clog2(ROWS);
localparam PIXELS_WIDTH = $clog2(PIXELS_PER_ROW);

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

// Define frame buffer select
input frame_buffer_select;

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
reg [7:0] rgb0 [PIXELS_PER_ROW - 1:0][ROWS - 1:0][1:0];
reg [7:0] rgb1 [PIXELS_PER_ROW - 1:0][ROWS - 1:0][1:0];
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
reg [PIXELS_WIDTH - 1:0] pixel_count;
reg [PIXELS_WIDTH - 1:0] pixels_loaded;
reg [PIXELS_WIDTH - 1:0] pixels_reqd;
	
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
		always @ (negedge clk_pixel or negedge reset_n) begin
			if(reset_n == 1'b0) begin
				r0[i] <= 0;
				r1[i] <= 0;
				g0[i] <= 0;
				g1[i] <= 0;
				b0[i] <= 0;
				b1[i] <= 0;
			end
			else begin
				r0[i] <= rgb0[pixel_count][i][line_buffer][7:5] > pwm;
				//r0[i] <= 2 > pwm;
				r1[i] <= rgb1[pixel_count][i][line_buffer][7:5] > pwm;
				//r1[i] <= 2 > pwm;
				g0[i] <= rgb0[pixel_count][i][line_buffer][4:2] > pwm;
				//g0[i] <= 2 > pwm;
				g1[i] <= rgb1[pixel_count][i][line_buffer][4:2] > pwm;
				//g1[i] <= 2 > pwm;
				b0[i] <= rgb0[pixel_count][i][line_buffer][1:0] > pwm;
				//b0[i] <= 2 > pwm;
				b1[i] <= rgb1[pixel_count][i][line_buffer][1:0] > pwm;
				//b1[i] <= 2 > pwm;
			end
		end
	end
endgenerate
	
// RGB/Pixel counter logic
always @ (posedge clk_pixel or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		pixel_count <= 0;
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
reg line_buffer_load;
reg [4:0] line_select_load;
reg [ROWS_WIDTH - 1:0] row_count_out;
reg [ADDRESS_WIDTH - 1:0] address_base;
localparam ADDRESS_START = 0;
localparam ADDRESS_FLIP_OFFSET = PIXELS_PER_ROW * 16;

// Define load pixel states
reg [2:0] req_state;
localparam [2:0]
	LOAD_IDLE = 0,
	LOAD_0 = 1,
	LOAD_1 = 2,
	LOAD_WAIT = 3;
	
// Pixel RAM read req logic
always @ (negedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		row_count_out <= 0;
		pixels_reqd <= 0;
		req_state <= LOAD_IDLE;
		address_fifo <= ADDRESS_START + PIXELS_PER_ROW;
		address_base <= ADDRESS_START + PIXELS_PER_ROW;
		line_select_load <= 1;
	end
	else begin
		case(req_state)
			LOAD_IDLE : begin
				if(line_buffer_load != line_buffer) begin
					if(line_select_load == 15) begin
						line_select_load <= 0;
						address_fifo <= frame_buffer_select == 1'b0 ? ADDRESS_START : ADDRESS_START + (PIXELS_PER_ROW * 32 * ROWS);
						address_base <= frame_buffer_select == 1'b0 ? ADDRESS_START : ADDRESS_START + (PIXELS_PER_ROW * 32 * ROWS);
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
					address_fifo <= address_fifo + ADDRESS_FLIP_OFFSET;
					req_state <= LOAD_1;
					data_out_ready_fifo <= 1'b1;
				end
				else begin
					data_out_ready_fifo <= 1'b0;
				end
			end
			
			LOAD_1: begin
				if(fifo_full == 1'b0) begin
					if(row_count_out == ROWS - 1) begin
						row_count_out <= 0;
						address_fifo <= address_base + 1;
						address_base <= address_base + 1;
						if(pixels_reqd == PIXELS_PER_ROW - 1) begin
							pixels_reqd <= 0;
							req_state <= LOAD_WAIT; // Done loading pixels entire row
							data_out_ready_fifo <= 1'b0;
						end
						else begin
							pixels_reqd <= pixels_reqd + 1;
							req_state <= LOAD_0; // Load another row
							data_out_ready_fifo <= 1'b1;
						end
					end
					else begin
						row_count_out <= row_count_out + 1;
						address_fifo <= address_fifo + ADDRESS_FLIP_OFFSET;
						req_state <= LOAD_0; // Load another row
						data_out_ready_fifo <= 1'b1;
					end
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
reg [ROWS_WIDTH - 1:0] row_count_in;

always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		flip_in <= 0;
		row_count_in <= 0;
		pixels_loaded <= 0;
		line_buffer_load <= 1'b1;
	end
	else begin
		if(data_in_ready_fifo == 1'b1) begin
			if(flip_in == 1'b1) begin
				if(row_count_in == ROWS - 1) begin
					row_count_in <= 0;
					if(pixels_loaded == PIXELS_PER_ROW - 1) begin
						pixels_loaded <= 0;
						line_buffer_load <= ~line_buffer_load;
					end
					else begin
						pixels_loaded <= pixels_loaded + 1;
					end
				end
				else begin
					row_count_in <= row_count_in + 1;
				end
				
				rgb1[pixels_loaded][row_count_in][line_buffer_load] <= data_in_fifo;
			end
			else begin
				rgb0[pixels_loaded][row_count_in][line_buffer_load] <= data_in_fifo;
			end
			
			flip_in <= ~flip_in;
		end
	end
end


assign wr_fifo = 1'b0;
assign led_clk = clk_pixel & led_clk_en;

endmodule
