module device_controller
	#(
		parameter ADDRESS_WIDTH = 25
	)
	(
		// Clock IO
		clk,
		
		// Data IO
		data_in,
		data_in_ready,
		data_in_count,
		
		// Memory interface
		address_mem,
		wr_mem,
		fifo_full_mem,
		data_in_mem,
		data_in_ready_mem,
		data_out_mem,
		data_out_ready_mem,
		
		
		// General IO
		cs_n,
		reset_n
	);

input clk;
input [7:0] data_in;
input data_in_ready;
input [7:0] data_in_count;

output reg [ADDRESS_WIDTH - 1:0] address_mem;
output wr_mem;
input fifo_full_mem;
input [7:0] data_in_mem;
input data_in_ready_mem;
output reg [7:0] data_out_mem;
output reg data_out_ready_mem;

input cs_n;
input reset_n;

// Define registers for data_in
reg [7:0] data_in_r [3:0];

// Data shift
always @ (posedge clk or negedge reset_n) begin
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

// Define registers for variables
reg [2:0] state;
localparam [2:0] 
	IDLE = 0,
	CMD_RXD = 1,
	DATA_RXD = 2;

localparam [7:0]
		CMD_WRITE = 10,
		CMD_READ = 11;

reg [7:0] cmd;

always @ (posedge clk or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		state <= IDLE;
		cmd <= 0;
		address_mem <= 0;
		data_out_mem <= 0;
		data_out_ready_mem <= 1'b0;
	end
	else begin
		if (cs_n == 1'b1) begin
			state <= IDLE;
			cmd <= 0;
			address_mem <= 0;
			data_out_mem <= 0;
			data_out_ready_mem <= 1'b0;
		end
		else begin
			if (data_in_ready == 1'b1) begin
				case (state)
					IDLE : begin
						if(data_in_count == 1) begin
							state <= CMD_RXD;
							cmd <= data_in;
						end
					end
					
					CMD_RXD: begin
						case(cmd)
							CMD_WRITE: begin
								if(data_in_count == 5) begin
									address_mem <= {data_in_r[2], data_in_r[1], data_in_r[0], data_in};
									state <= DATA_RXD;
								end
							end
							
							CMD_READ: begin
								// Do nothing...
							end
						endcase
					end
					
					DATA_RXD : begin
						data_out_mem <= data_in;
						data_out_ready_mem <= 1'b1;
					end
				endcase
			end
			else begin
				data_out_ready_mem <= 1'b0;
			end
		end
	end
end

assign wr_mem = cmd == CMD_WRITE;

endmodule
	