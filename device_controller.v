module device_controller
	#(
		parameter ADDRESS_WIDTH = 25,
		parameter DATA_WIDTH = 16
	)
	(
		// Clock IO
		clk_sys,
		clk_device,
		
		
		// Data IO
		data_in,
		data_in_ready,
		
		// Memory interface
		address_mem,
		wr_mem,
		fifo_full_mem,
		data_in_mem,
		data_in_ready_mem,
		data_out_mem,
		data_out_ready_mem,
		
		// Register out
		frame_buffer_select,
		
		// General IO
		cs_n,
		reset_n
	);

input clk_sys;
input clk_device;
input [7:0] data_in;
input data_in_ready;

output reg [ADDRESS_WIDTH - 1:0] address_mem;
output reg wr_mem;
input fifo_full_mem;
input [DATA_WIDTH - 1:0] data_in_mem;
input data_in_ready_mem;
output reg [DATA_WIDTH - 1:0] data_out_mem;
output reg data_out_ready_mem;

output reg frame_buffer_select;

input cs_n;
input reset_n;

// Define registers for data_in
reg [7:0] data_in_r [3:0];

// Data shift
always @ (posedge clk_device or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		data_in_r[0] <= 0;
		data_in_r[1] <= 0;
		data_in_r[2] <= 0;
	end
	else begin
		if(cs_n == 1'b1) begin
			data_in_r[0] <= 0;
			data_in_r[1] <= 0;
			data_in_r[2] <= 0;
		end
		else begin
			if(data_in_ready == 1'b1) begin
				data_in_r[0] <= data_in;
				data_in_r[1] <= data_in_r[0];
				data_in_r[2] <= data_in_r[1];
			end
		end
	end
end

// bytes_rxd counter
reg [3:0] data_in_count;

// Define registers for variables
reg [2:0] state;
localparam [2:0] 
	IDLE = 0,
	CMD_RXD = 1,
	CMD_WRITE_DATA = 2,
	CMD_READ_DATA = 3,
	CMD_DONE = 4;
	
// Define commands
localparam [7:0]
		CMD_WRITE = 10,
		CMD_READ = 11,
		CMD_FLIP = 20;

// Define cmd register
reg [7:0] cmd;

// Define address output
reg [ADDRESS_WIDTH - 1:0] address_in;
reg [ADDRESS_WIDTH - 1:0] address_out_fifo [3:0];
reg [DATA_WIDTH - 1:0] data_out_fifo [3:0];
reg [1:0] head_out;

// Define cs_n buffer
reg [2:0] cs_n_buffer;
reg cs_n_meta;
always @ (posedge clk_sys) cs_n_meta <= cs_n;
always @ (posedge clk_sys) cs_n_buffer <= { cs_n_buffer[1], cs_n_buffer[0], cs_n_meta };

// Define high_low
reg high_low;

always @ (posedge clk_sys or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		state <= IDLE;
		cmd <= 0;
		head_out <= 0;
		wr_mem <= 1'b0;
		data_in_count <= 0;
		frame_buffer_select <= 1'b0;
		high_low <= 1'b0;
	end
	else begin
		if (cs_n_buffer[1]) begin
			state <= IDLE;
			cmd <= 0;
			wr_mem <= 1'b0;
			data_in_count <= 0;
			high_low <= 1'b0;
		end
		else begin
			if(data_in_ready == 1'b1)
				data_in_count <= data_in_count  + 1;
				
			case (state)
				IDLE : begin
					if(data_in_count == 0 && data_in_ready == 1'b1) begin
						state <= CMD_RXD;
						cmd <= data_in;
					end
				end
				
				CMD_RXD: begin
					case(cmd)
						CMD_WRITE: begin
							if(data_in_count == 4 && data_in_ready == 1'b1) begin
								address_in <= {data_in_r[2], data_in_r[1], data_in_r[0], data_in};
								state <= CMD_WRITE_DATA;
								high_low <= 1'b0;
								wr_mem <= 1'b1;
							end
						end
						
						CMD_READ: begin
							wr_mem <= 1'b0;
						end
						
						CMD_FLIP: begin
							frame_buffer_select <= ~frame_buffer_select;
							state <= CMD_DONE;
						end
					endcase
				end
				
				CMD_WRITE_DATA : begin
					if(data_in_ready == 1'b1) begin
						if(high_low) begin
							high_low <= 1'b0;
							address_out_fifo[head_out] <= address_in;
							address_in <= address_in + 1;
							data_out_fifo[head_out] <= {data_in_r[0], data_in};
							head_out <= head_out == 3 ? 0 : head_out + 1;
							state <= CMD_WRITE_DATA;
							high_low <= 1'b0;
						end
						else begin
							high_low <= 1'b1;
						end						
					end
				end
				
				CMD_DONE : begin
					//Do nothing wait for CS to assert high
				end
			endcase
		end
	end
end

// FIFO out
reg [1:0] tail_out;

// Memory FIFO interface
always @ (negedge clk_sys or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		tail_out <= 0;
		data_out_ready_mem <= 1'b0;
		address_mem <= 0;
		data_out_mem <= 0;
	end
	else begin
		if(head_out != tail_out) begin
			address_mem <= address_out_fifo[tail_out];
			data_out_mem <= data_out_fifo[tail_out];
			
			tail_out <= tail_out == 3 ? 0 : tail_out + 1;
			data_out_ready_mem <= 1'b1;
		end
		else begin
			data_out_ready_mem <= 1'b0;
		end
	end
end

endmodule
	