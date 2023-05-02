module single_port_ram 
	#(
		parameter ADDRESS_WIDTH = 8,
		parameter DATA_WIDTH = 16
	)
	(
		input wire clock,
		input wire wren,
		input wire [ADDRESS_WIDTH-1:0] address,
		input wire [DATA_WIDTH-1:0] data,
		output reg [DATA_WIDTH-1:0] q
	);

reg [DATA_WIDTH-1:0] mem [2**ADDRESS_WIDTH - 1:0];

always @(posedge clock) begin
	if (wren)
		mem[address] <= data;
	q <= mem[address];
end

endmodule