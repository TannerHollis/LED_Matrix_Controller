module crc_8bit
(
	input wire [7:0] data_in,
	output reg [7:0] crc_out
);

reg [7:0] divisor;
reg [7:0] remainder;

integer i;
  
always @(data_in) begin
	divisor = 8'b10001110; // CRC-8 polynomial: x^7 + x^3 + x^2
	remainder = data_in;
    
	for (i = 0; i < 8; i = i + 1) begin
		if (remainder[7] == 1'b1)
			remainder = remainder ^ divisor;
		remainder = remainder << 1;
		end
   
	crc_out = remainder;
	end

endmodule