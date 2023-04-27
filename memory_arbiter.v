module memory_arbiter
	#(
		parameter ADDRESS_WIDTH = 25,
		parameter PERIPHERALS = 3,
		parameter PERIPHERALS_FIFO_DEPTH = 32,
		parameter FIFO_DEPTH = 2
	)
	(
		clk,
		address,
		wr,
		fifo_full,
		
		data_in,
		data_in_ready,		
		
		data_out,
		data_out_ready,
	
		reset_n
	);

localparam PERIPHERALS_FIFO_WIDTH = $clog2(PERIPHERALS_FIFO_DEPTH);
localparam FIFO_WIDTH = $clog2(FIFO_DEPTH);
localparam PERIPHERAL_WIDTH = $clog2(PERIPHERALS);

input clk;
input [(ADDRESS_WIDTH * PERIPHERALS) - 1:0] address;
input [PERIPHERALS - 1:0] wr;
output reg [PERIPHERALS - 1:0] fifo_full;
input [(8 * PERIPHERALS) - 1:0] data_in;
input [PERIPHERALS - 1:0] data_in_ready;
output [7:0] data_out;
output [PERIPHERALS - 1:0] data_out_ready;
input reset_n;

// Fanout address and data inputs
wire [ADDRESS_WIDTH - 1:0] address_w [PERIPHERALS - 1:0];
wire [7:0] data_in_w [PERIPHERALS - 1:0];
genvar k;
generate
	for(k = 0; k < PERIPHERALS; k = k + 1) begin : fanout_inst
		assign address_w[k] = address[(k + 1)*ADDRESS_WIDTH - 1:k*ADDRESS_WIDTH];
		assign data_in_w[k] = data_in[(k + 1)*8 - 1:k*8];
	end
endgenerate

// FIFO for each peripheral
reg [ADDRESS_WIDTH - 1:0] address_peripherals_sr [PERIPHERALS - 1:0][PERIPHERALS_FIFO_DEPTH - 1:0];
reg wr_peripherals_sr [PERIPHERALS - 1:0][PERIPHERALS_FIFO_DEPTH - 1:0];
reg [7:0] data_in_peripherals_sr [PERIPHERALS - 1:0][PERIPHERALS_FIFO_DEPTH - 1:0];
reg [PERIPHERALS_FIFO_WIDTH - 1:0] head_peripherals [PERIPHERALS - 1:0];
reg [PERIPHERALS_FIFO_WIDTH - 1:0] head_peripherals_next [PERIPHERALS - 1:0];
reg [PERIPHERALS_FIFO_WIDTH - 1:0] tail_peripherals [PERIPHERALS - 1:0];
reg [PERIPHERALS_FIFO_WIDTH:0] fifo_count [PERIPHERALS - 1:0];

genvar i;
generate
	for(i = 0; i < PERIPHERALS; i = i + 1) begin : peripheral_inst
		always @ (posedge	clk or negedge reset_n) begin
			if (reset_n == 1'b0) begin
				head_peripherals[i] <= 0;
				head_peripherals_next[i] <= 1;
				fifo_full[i] <= 1'b0;
			end
			else begin
				fifo_full[i] <= head_peripherals_next[i] == tail_peripherals[i];
				
				if(data_in_ready[i] == 1'b1 && fifo_full[i] == 1'b0) begin
					address_peripherals_sr[i][head_peripherals[i]] <= address_w[i];
					wr_peripherals_sr[i][head_peripherals[i]] <= wr[i];
					data_in_peripherals_sr[i][head_peripherals[i]] <= data_in_w[i];
					
					// Increment peripheral head and calculate next value
					head_peripherals[i] <= head_peripherals[i] == (PERIPHERALS_FIFO_DEPTH - 1) ? 0 : head_peripherals[i] + 1;
					head_peripherals_next[i] <= head_peripherals_next[i] == (PERIPHERALS_FIFO_DEPTH - 1) ? 0 : head_peripherals_next[i] + 1;
				end
			end
		end
		
		always @ (posedge clk or negedge reset_n) begin
			if (reset_n == 1'b0) begin
				fifo_count[i] <= 0;
			end
			else begin
				if(head_peripherals[i] >= tail_peripherals[i]) begin
					fifo_count[i] <= head_peripherals[i] - tail_peripherals[i];
				end
				else begin
					fifo_count[i] <= PERIPHERALS_FIFO_DEPTH + head_peripherals[i] - tail_peripherals[i];
				end
			end
		end
	end
endgenerate

// Main FIFO
reg [ADDRESS_WIDTH - 1:0] address_sr [FIFO_DEPTH - 1:0];
reg wr_sr [FIFO_DEPTH - 1:0];
reg [7:0] data_in_sr [FIFO_DEPTH - 1:0];
reg [PERIPHERALS - 1:0] peripheral_select_sr [FIFO_DEPTH - 1:0];
reg [FIFO_WIDTH - 1:0] head;
reg [FIFO_WIDTH - 1:0] head_next;
reg [FIFO_WIDTH - 1:0] tail;
reg [PERIPHERAL_WIDTH - 1:0] peripheral_count;
reg [PERIPHERALS_FIFO_WIDTH - 1:0] weight;
integer j;

always @ (posedge clk or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		head <= 0;
		peripheral_count <= 0;
		weight <= 0;
		for(j = 0; j < PERIPHERALS; j = j + 1) begin
			tail_peripherals[j] <= 0;
		end
	end
	else begin
		peripheral_count <= (peripheral_count == PERIPHERALS - 1) ? 0 : peripheral_count + 1;
		if(head_peripherals[peripheral_count] != tail_peripherals[peripheral_count]) begin
 			address_sr[head] <= address_peripherals_sr[peripheral_count][tail_peripherals[peripheral_count]];
			wr_sr[head] <= wr_peripherals_sr[peripheral_count][tail_peripherals[peripheral_count]];
			data_in_sr[head] <= data_in_peripherals_sr[peripheral_count][tail_peripherals[peripheral_count]];
			peripheral_select_sr[head] <= (1 << peripheral_count);
			
			// Increment peripheral tail and main FIFO head
			tail_peripherals[peripheral_count] <= tail_peripherals[peripheral_count] == (PERIPHERALS_FIFO_DEPTH - 1) ? 0 : tail_peripherals[peripheral_count] + 1;
			head <= head == (FIFO_DEPTH - 1) ? 0 : head + 1;
			weight <= weight - 1;
		end
	end
end

// RAM interface
reg [ADDRESS_WIDTH - 1:0] address_ram;
reg wr_ram;
reg [7:0] data_in_ram;
reg [7:0] data_out_ram;

always @ (negedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		address_ram <= 0;
		wr_ram <= 1'b0;
		data_in_ram <= 0;
	end
	else begin
		if(head != tail) begin
			address_ram <= address_sr[tail];
			wr_ram <= wr_sr[tail];
			data_in_ram <= data_in_sr[tail];
		end
	end
end

reg [PERIPHERALS - 1:0] data_out_ready_sr [2:0];
reg [7:0] data_out_sr [2:0];
wire [7:0] q;

// Data ready output
always @ (posedge clk or negedge reset_n) begin
	if(reset_n == 1'b0) begin
		tail <= 0;
		data_out_ready_sr[0] <= 0;
		data_out_ready_sr[1] <= 0;
		data_out_ready_sr[2] <= 0;
	end
	else begin
		if(head != tail) begin
			data_out_ready_sr[0] <= wr_sr[tail] ? 0 : peripheral_select_sr[tail];
			
			// Increment tail
			tail <= tail == (FIFO_DEPTH - 1) ? 0 : tail + 1;
		end
		else begin
			data_out_ready_sr[0] <= 0;
		end
		data_out_ready_sr[1] <= data_out_ready_sr[0];
		data_out_ready_sr[2] <= data_out_ready_sr[1];
	end
end



always @ (posedge clk or negedge reset_n) begin
	if (reset_n == 1'b0) begin
		data_out_sr[0] <= 0;
		data_out_sr[1] <= 0;
		data_out_sr[2] <= 0;
	end
	else begin
		data_out_sr[0] <= q;
		data_out_sr[1] <= data_out_sr[0];
		data_out_sr[2] <= data_out_sr[1];
	end
end

assign data_out_ready = data_out_ready_sr[1];
assign data_out = q;

// RAM instantiation 8 bit x 16384
ram ram (
	.address(address_ram),
	.clock(clk),
	.data(data_in_ram),
	.wren(wr_ram),
	.q(q)
	);

	
endmodule

