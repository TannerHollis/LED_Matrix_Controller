// ============================================================================
// File Name   : sdram_bist_top.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Hardware BIST top that exercises sdram_controller directly (no memory
//   arbiter). One button press writes then read-verifies a sweep of SDRAM using
//   mem_pattern(addr) = addr[15:0] ^ 16'hA5C3.
//
// Parameters  :
//   AddrWidth       - Host SDRAM address bus width (Default: 24)
//   DataWidth       - Host/SDRAM data bus width (Default: 16)
//   SdramAddrWidth - SDRAM chip address bus width (Default: 13)
//   SdramRowSize    - Row address field width (Default: 13)
//   SdramColSize    - Column address field width (Default: 9)
//   SdramBankSize   - Bank address field width (Default: 2)
//   BurstLen        - SDRAM burst length; must be 1, 2, 4, or 8 (Default: 8)
//   FirstTestAddr  - First address in the write/read sweep (Default: 0)
//   LastTestAddr   - Last address in the write/read sweep (Default: 24'h00FF_FFFF)
//
// Sweep addresses must be burst-aligned: (LAST - FIRST + 1) must be divisible
// by BurstLen.
//
// Dependencies:
//   - sdram_controller.sv
// ============================================================================
// Revision History:
//   Current - Direct SDRAM controller burst write/read sweep BIST.
// ============================================================================

module sdram_bist_top #(
  parameter int unsigned AddrWidth      = 24,
  parameter int unsigned DataWidth      = 16,
  parameter int unsigned SdramAddrWidth = 13,
  parameter int unsigned SdramRowSize   = 13,
  parameter int unsigned SdramColSize   = 9,
  parameter int unsigned SdramBankSize  = 2,
  parameter int unsigned BurstLen       = 8,
  parameter logic [23:0] FirstTestAddr  = 24'h0000_0000,
  parameter logic [23:0] LastTestAddr   = 24'h00FF_FFFF
) (
    input  wire        clk_50mhz,
    input  wire        btn_start,
    input  wire        btn_reset,
    output reg         led_status,
    output wire [SdramAddrWidth-1:0] sdram_addr,
    output wire [1:0]  sdram_ba,
    output wire        sdram_cas_n,
    output wire        sdram_cke,
    output wire        sdram_clk,
    output wire        sdram_cs_n,
    inout  wire [DataWidth-1:0] sdram_dq,
    output wire [DataWidth/8-1:0] sdram_dqm,
    output wire        sdram_ras_n,
    output wire        sdram_we_n
);

    localparam READ_DISABLED   = 9'd0;
    localparam WR_FINISH_WAIT  = 12'd2048;
    localparam [8:0] HOST_BURST_LEN = BurstLen;
    localparam BURST_LEN_BITS  = (BurstLen <= 1) ? 1 : $clog2(BurstLen);

    localparam S_IDLE         = 4'd0;
    localparam S_WR_FILL      = 4'd1;
    localparam S_WR_DRAIN     = 4'd2;
    localparam S_WR_FINISH    = 4'd3;
    localparam S_RD_FLUSH     = 4'd4;
    localparam S_RD_FLUSH_W   = 4'd5;
    localparam S_RD_POP       = 4'd6;
    localparam S_RD_SETTLE    = 4'd7;
    localparam S_RD_CAPTURE   = 4'd8;
    localparam S_RD_COMPARE   = 4'd9;
    localparam S_DONE         = 4'd10;
    localparam S_FAIL         = 4'd11;

    localparam SDRAM_ROWSTART  = SdramColSize;
    localparam SDRAM_COLSTART  = 0;
    localparam SDRAM_BANKSTART = SdramColSize + SdramRowSize;

    logic clk_i;
    logic rst_ni;
    assign clk_i  = clk_50mhz;
    assign rst_ni = btn_reset;

    reg [3:0] state;
    reg [AddrWidth-1:0] curr_addr;
    reg [BURST_LEN_BITS-1:0] wr_fill_idx;
    reg [BURST_LEN_BITS-1:0] rd_word_idx;
    reg [11:0] finish_counter;
    reg [24:0] blink_counter;
    reg start_armed;
    reg [1:0] btn_sync;

    reg write_request;
    reg read_request;
    reg write_load;
    reg read_load;
    reg [AddrWidth-1:0] write_addr;
    reg [AddrWidth-1:0] read_addr;
    reg [DataWidth-1:0] write_data;
    reg [DataWidth-1:0] read_data_sampled;
    reg [DataWidth-1:0] expected_data;
    reg [8:0] ctrl_write_length;
    reg [8:0] ctrl_read_length;

    wire [DataWidth-1:0] read_data;
    wire [15:0] write_used;
    wire [15:0] read_used;
    wire write_full;
    wire read_empty;

    wire [AddrWidth-1:0] first_test_addr = FirstTestAddr[AddrWidth-1:0];
    wire [AddrWidth-1:0] last_test_addr  = LastTestAddr[AddrWidth-1:0];
    wire [AddrWidth-1:0] burst_last_addr = curr_addr + BurstLen - 1;
    wire at_last_burst = (burst_last_addr >= last_test_addr);

    function [DataWidth-1:0] mem_pattern;
        input [AddrWidth-1:0] addr_in;
        begin
            mem_pattern = addr_in[DataWidth-1:0] ^ 16'hA5C3;
        end
    endfunction

    initial begin
        if (BurstLen != 1 && BurstLen != 2 && BurstLen != 4 && BurstLen != 8) begin
            $display("ERROR: sdram_bist_top BurstLen=%0d; legal values are 1, 2, 4, 8", BurstLen);
            $finish;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            btn_sync    <= 2'b11;
            start_armed <= 1'b1;
        end else begin
            btn_sync <= {btn_sync[0], btn_start};
            if (btn_sync[1])
                start_armed <= 1'b1;
            else if (btn_sync == 2'b10 && start_armed)
                start_armed <= 1'b0;
        end
    end

    wire start_event = (btn_sync == 2'b10) && start_armed;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state              <= S_IDLE;
            curr_addr          <= first_test_addr;
            wr_fill_idx        <= {BURST_LEN_BITS{1'b0}};
            rd_word_idx        <= {BURST_LEN_BITS{1'b0}};
            finish_counter     <= 12'd0;
            blink_counter      <= 25'd0;
            led_status         <= 1'b1;
            write_request      <= 1'b0;
            read_request       <= 1'b0;
            write_load         <= 1'b0;
            read_load          <= 1'b0;
            write_addr         <= first_test_addr;
            read_addr          <= first_test_addr;
            write_data         <= {DataWidth{1'b0}};
            read_data_sampled  <= {DataWidth{1'b0}};
            expected_data      <= {DataWidth{1'b0}};
            ctrl_write_length  <= HOST_BURST_LEN;
            ctrl_read_length   <= READ_DISABLED;
        end else begin
            write_request <= 1'b0;
            read_request  <= 1'b0;
            write_load    <= 1'b0;
            read_load     <= 1'b0;
            blink_counter <= blink_counter + 25'd1;

            case (state)
                S_IDLE: begin
                    led_status <= 1'b1;
                    if (start_event) begin
                        write_load        <= 1'b1;
                        write_addr        <= first_test_addr;
                        read_load         <= 1'b1;
                        read_addr         <= first_test_addr;
                        ctrl_write_length <= HOST_BURST_LEN;
                        ctrl_read_length  <= READ_DISABLED;
                        curr_addr         <= first_test_addr;
                        wr_fill_idx       <= {BURST_LEN_BITS{1'b0}};
                        rd_word_idx       <= {BURST_LEN_BITS{1'b0}};
                        finish_counter    <= 12'd0;
                        state             <= S_WR_FILL;
                    end
                end

                S_WR_FILL: begin
                    led_status <= ~blink_counter[21];
                    write_data <= mem_pattern(curr_addr + {{(AddrWidth-BURST_LEN_BITS){1'b0}}, wr_fill_idx});
                    if (!write_full) begin
                        write_request <= 1'b1;
                        if (wr_fill_idx == (BurstLen - 1)) begin
                            wr_fill_idx <= {BURST_LEN_BITS{1'b0}};
                            state       <= S_WR_DRAIN;
                        end else begin
                            wr_fill_idx <= wr_fill_idx + 1'b1;
                        end
                    end
                end

                S_WR_DRAIN: begin
                    led_status <= ~blink_counter[21];
                    if (write_used[8:0] == 9'd0) begin
                        if (at_last_burst) begin
                            ctrl_write_length <= READ_DISABLED;
                            finish_counter    <= 12'd0;
                            state             <= S_WR_FINISH;
                        end else begin
                            curr_addr <= curr_addr + BurstLen;
                            state     <= S_WR_FILL;
                        end
                    end
                end

                S_WR_FINISH: begin
                    if (write_used[8:0] == 9'd0 && finish_counter >= WR_FINISH_WAIT) begin
                        curr_addr        <= first_test_addr;
                        rd_word_idx      <= {BURST_LEN_BITS{1'b0}};
                        ctrl_read_length <= READ_DISABLED;
                        state            <= S_RD_FLUSH;
                    end else begin
                        finish_counter <= finish_counter + 12'd1;
                    end
                end

                S_RD_FLUSH: begin
                    if (!read_empty) begin
                        read_request <= 1'b1;
                        state        <= S_RD_FLUSH_W;
                    end else begin
                        read_load        <= 1'b1;
                        read_addr        <= first_test_addr;
                        ctrl_read_length <= HOST_BURST_LEN;
                        state            <= S_RD_POP;
                    end
                end

                S_RD_FLUSH_W: begin
                    state <= S_RD_FLUSH;
                end

                S_RD_POP: begin
                    led_status <= ~blink_counter[21];
                    if (!read_empty) begin
                        read_request <= 1'b1;
                        state        <= S_RD_SETTLE;
                    end
                end

                S_RD_SETTLE: begin
                    state <= S_RD_CAPTURE;
                end

                S_RD_CAPTURE: begin
                    read_data_sampled <= read_data;
                    expected_data     <= mem_pattern(curr_addr + {{(AddrWidth-BURST_LEN_BITS){1'b0}}, rd_word_idx});
                    state             <= S_RD_COMPARE;
                end

                S_RD_COMPARE: begin
                    if (read_data_sampled != expected_data) begin
                        state <= S_FAIL;
                    end else if (rd_word_idx == (BurstLen - 1)) begin
                        if (at_last_burst) begin
                            state <= S_DONE;
                        end else begin
                            curr_addr   <= curr_addr + BurstLen;
                            rd_word_idx <= {BURST_LEN_BITS{1'b0}};
                            state       <= S_RD_POP;
                        end
                    end else begin
                        rd_word_idx <= rd_word_idx + 1'b1;
                        state       <= S_RD_POP;
                    end
                end

                S_DONE: begin
                    led_status <= 1'b0;
                end

                S_FAIL: begin
                    led_status <= ~blink_counter[23];
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    sdram_controller #(
        .RowStart(SDRAM_ROWSTART),
        .RowSize(SdramRowSize),
        .ColStart(SDRAM_COLSTART),
        .ColSize(SdramColSize),
        .BankStart(SDRAM_BANKSTART),
        .BankSize(SdramBankSize),
        .SaSize(SdramAddrWidth),
        .AddrSize(AddrWidth),
        .DataWidth(DataWidth),
        .ScBl(BurstLen),
        .ScSingleWrite(0),
        .MaxBurstLen(8)
    ) sdram_ctrl_inst (
        .clk_50mhz_i(clk_i),
        .rst_ni(rst_ni),
        .write_data_i(write_data),
        .write_request_i(write_request),
        .write_addr_i(write_addr),
        .write_length_i(ctrl_write_length),
        .write_load_i(write_load),
        .write_full_o(write_full),
        .write_used_o(write_used),
        .read_data_o(read_data),
        .read_request_i(read_request),
        .read_addr_i(read_addr),
        .read_length_i(ctrl_read_length),
        .read_load_i(read_load),
        .read_empty_o(read_empty),
        .read_used_o(read_used),
        .sdram_addr_o(sdram_addr),
        .sdram_ba_o(sdram_ba),
        .sdram_cas_n_o(sdram_cas_n),
        .sdram_cke_o(sdram_cke),
        .sdram_clk_o(sdram_clk),
        .sdram_cs_n_o(sdram_cs_n),
        .sdram_dq_io(sdram_dq),
        .sdram_dqm_o(sdram_dqm),
        .sdram_ras_n_o(sdram_ras_n),
        .sdram_we_n_o(sdram_we_n)
    );

endmodule
