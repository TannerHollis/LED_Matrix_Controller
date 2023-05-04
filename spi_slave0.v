//spi_slave.v

module spi_slave0(
	input reset_n,
	input clk_sb,
	input clk_spi,
	input mosi,
	output reg miso,
	input cs_n,
	
	input miso_tx,
	input wire [7:0] miso_data_in,
	output reg miso_en,
	
	output reg mosi_rx,
	output reg [7:0] mosi_data_out
);

//Configure SPI Clock polarity and phase
localparam CPOL = 0;
localparam CPHA = 0;

//Clock Buffer for edge trigger detection
reg [2:0] clk;
reg clk_meta;
wire clk_neg;
wire clk_pos;

//Declare clocks configured with CPOL and CPHA
always @(posedge clk_sb) clk_meta <= clk_spi;
always @(posedge clk_sb) clk <= {clk[1], clk[0], clk_meta};
assign clk_pos = ((clk[2:1] == 2'b01) && ((CPOL == 0) || (CPOL == 3))) || ((clk == 2'b10) && ((CPOL == 1) || (CPOL == 2)));
assign clk_neg = ((clk[2:1] == 2'b10) && ((CPOL == 0) || (CPOL == 3))) || ((clk == 2'b01) && ((CPOL == 1) || (CPOL == 2)));

//Input data buffer due to clock buffer
reg [2:0] mosi_buffer;
reg mosi_meta;
always @(posedge clk_sb) mosi_meta <= mosi;
always @(posedge clk_sb) mosi_buffer <= {mosi_buffer[1], mosi_buffer[0], mosi_meta};

//Handle SPI in 24-bits format, so we need a 5 bits counter to count the bits as they come in
reg [4:0] bitcnt_rx;
reg [4:0] bitcnt_tx;

//Declare 24-bit data buffers
reg [7:0] miso_data_out;
reg [7:0] mosi_data_in;

//Implement SPI_RX
always @(posedge clk_sb or negedge reset_n)
begin
	if(~reset_n)
	begin
		bitcnt_rx <= 5'd0;
		mosi_data_in <= 8'd0;
		mosi_rx <= 1'b0;
		mosi_data_out <= 8'd0;
	end
	else
	begin
		if(cs_n)
		begin
			bitcnt_rx <= 5'd0;
			mosi_data_in <= 8'd0;
			mosi_rx <= 1'b0;
			mosi_data_out <= 8'd0;
		end
		else begin
			if(clk_pos) begin
				if(bitcnt_rx == 5'd7) begin
					bitcnt_rx <= 0;
					mosi_data_out <= {mosi_data_in[6:0], mosi_buffer[2]};
					mosi_rx <= 1'b1;
				end
				else begin
					bitcnt_rx <= bitcnt_rx + 5'd1;
					mosi_rx <= 1'b0;
				end

				//Implement left-shift MSB register with buffered miso input(previous value)
				mosi_data_in <= {mosi_data_in[6:0], mosi_buffer[2]};
			end
			else begin
				mosi_rx <= 1'b0;
				mosi_data_in <= mosi_data_in;
			end
		end
	end
end

//Implement SPI_TX
always @(posedge clk_sb)
begin
	if(~reset_n)
	begin
		bitcnt_tx <= 5'd7;
		miso <= 1'b0; 		//miso <= 1'bz; //ICE40UL products do not have tristate capabilities
		miso_en <= 1'b0;	//Use SB_IO_OD primitive with 
	end
	else
	begin
		if(cs_n)
		begin
			if(miso_tx && (bitcnt_tx == 5'd7))
			begin
				bitcnt_tx <= 5'd0;
				miso_data_out <= miso_data_in;
			end
			
			if(bitcnt_tx == 5'd7)
			begin
				miso_en <= 1'b0;
			end
			else
			begin
				miso <= miso_data_out[5'd7];
				miso_en <= 1'b1;
			end
		end
		else if(clk_neg && (bitcnt_tx < 5'd7))
		begin
			bitcnt_tx <= bitcnt_tx + 5'd1;
			
			miso <= miso_data_out[5'd6 - bitcnt_tx];
		end
	end
end

endmodule