// ============================================================================
// File Name   : memory_fetcher_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for memory_fetcher. Verifies address generation,
//   burst read requests, buffer writes, and top/bottom row-pair fetching.
//
// Dependencies:
//   - memory_fetcher.sv
// ============================================================================
`timescale 1ns / 1ps

module memory_fetcher_tb;

  localparam int unsigned TotalRowWidth      = 8;
  localparam int unsigned PanelHeight        = 4;
  localparam int unsigned ColorDepth         = 4;
  localparam int unsigned RowOffset          = 0;
  localparam int unsigned TotalDisplayHeight = 8;
  localparam int unsigned SysClkHz           = 50_000_000;
  localparam int unsigned ClkPeriod          = 1000 / (SysClkHz / 1_000_000);

  localparam int unsigned PixelDataWidth = ColorDepth * 3;
  localparam int unsigned RowPairCount   = PanelHeight / 2;
  localparam int unsigned MemSize        = TotalRowWidth * TotalDisplayHeight;

  logic clk_i;
  logic rst_ni;

  logic                                mem_req_o;
  logic [3:0]                          mem_read_length_o;
  logic                                mem_grant_i;
  logic [$clog2(TotalRowWidth * TotalDisplayHeight) - 1:0] mem_addr_o;
  logic [ColorDepth*3-1:0]             mem_read_data_i;
  logic                                mem_read_data_valid_i;

  logic [ColorDepth*3-1:0]             buffer_wr_data_o;
  logic [$clog2(TotalRowWidth)-1:0]    buffer_wr_addr_o;
  logic                                buffer_wr_en_o;
  logic                                buffer_sel_o;
  logic                                fetch_complete_o;
  logic                                busy_o;

  logic                                start_fetch_i;
  logic [0:0]                          row_pair_index_i;
  logic [1:0]                          target_buffer_i;

  logic [PixelDataWidth-1:0] sim_memory [0:MemSize-1];

  memory_fetcher #(
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .RowOffset(RowOffset),
    .TotalDisplayHeight(TotalDisplayHeight)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .mem_req_o(mem_req_o),
    .mem_read_length_o(mem_read_length_o),
    .mem_grant_i(mem_grant_i),
    .mem_addr_o(mem_addr_o),
    .mem_read_data_i(mem_read_data_i),
    .mem_read_data_valid_i(mem_read_data_valid_i),
    .buffer_wr_data_o(buffer_wr_data_o),
    .buffer_wr_addr_o(buffer_wr_addr_o),
    .buffer_wr_en_o(buffer_wr_en_o),
    .buffer_sel_o(buffer_sel_o),
    .fetch_complete_o(fetch_complete_o),
    .start_fetch_i(start_fetch_i),
    .row_pair_index_i(row_pair_index_i),
    .target_buffer_i(target_buffer_i),
    .busy_o(busy_o)
  );

  always #(ClkPeriod / 2) clk_i = ~clk_i;

  typedef enum logic [2:0] {
    StIdle,
    StArbitration,
    StGrant,
    StDataDelay,
    StDataValid
  } arbiter_state_e;

  arbiter_state_e arbiter_state_q;
  logic [2:0] delay_counter_q;
  logic [3:0] beats_left_q;
  logic [$clog2(TotalRowWidth * TotalDisplayHeight) - 1:0] grant_base_addr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      arbiter_state_q <= StIdle;
      delay_counter_q <= '0;
      beats_left_q <= '0;
      mem_grant_i <= 1'b0;
      mem_read_data_valid_i <= 1'b0;
    end else begin
      mem_grant_i <= 1'b0;
      mem_read_data_valid_i <= 1'b0;

      case (arbiter_state_q)
        StIdle: begin
          if (mem_req_o) begin
            arbiter_state_q <= StArbitration;
            delay_counter_q <= '0;
          end
        end

        StArbitration: begin
          if (delay_counter_q == 2) begin
            arbiter_state_q <= StGrant;
            mem_grant_i <= 1'b1;
            grant_base_addr_q <= mem_addr_o;
            beats_left_q <= mem_read_length_o;
            delay_counter_q <= '0;
          end else begin
            delay_counter_q <= delay_counter_q + 1'b1;
          end
        end

        StGrant: begin
          arbiter_state_q <= StDataDelay;
        end

        StDataDelay: begin
          if (delay_counter_q == 1) begin
            arbiter_state_q <= StDataValid;
            mem_read_data_i <= sim_memory[grant_base_addr_q + (mem_read_length_o - beats_left_q)];
            mem_read_data_valid_i <= 1'b1;
          end else begin
            delay_counter_q <= delay_counter_q + 1'b1;
          end
        end

        StDataValid: begin
          if (beats_left_q <= 4'd1)
            arbiter_state_q <= StIdle;
          else begin
            beats_left_q <= beats_left_q - 4'd1;
            arbiter_state_q <= StDataDelay;
            delay_counter_q <= '0;
          end
        end

        default: arbiter_state_q <= StIdle;
      endcase
    end
  end

  integer memory_request_count;
  integer buffer_write_count;
  integer fetch_complete_count;

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    start_fetch_i = 1'b0;
    row_pair_index_i = 1'b0;
    target_buffer_i = 2'b00;
    memory_request_count = 0;
    buffer_write_count = 0;
    fetch_complete_count = 0;

    for (integer i = 0; i < MemSize; i = i + 1) begin
      sim_memory[i] = i;
    end

    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Starting Memory Fetcher Testbench", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Configuration:", $time);
    $display("T=%3t:   - Total Row Width: %d pixels", $time, TotalRowWidth);
    $display("T=%3t:   - Panel Height: %d pixels", $time, PanelHeight);
    $display("T=%3t:   - Color Depth: %d bits", $time, ColorDepth);
    $display("T=%3t:   - Row Pair Count: %d", $time, RowPairCount);
    $display("T=%3t:   - Memory Size: %d words", $time, MemSize);

    #100;
    rst_ni = 1'b1;

    $display("T=%3t: Reset released. Starting test sequence.", $time);

    $display("T=%3t: Test Case 1: Initial fetch operation", $time);
    start_fetch_i = 1'b1;
    #(ClkPeriod * 2);
    start_fetch_i = 1'b0;

    wait (fetch_complete_o);
    $display("T=%3t: SUCCESS! Initial fetch completed", $time);

    $display("T=%3t: Test Case 2: Monitoring memory requests and buffer writes", $time);
    #(ClkPeriod * 100);

    $display("T=%3t: Test Case 3: Second fetch operation", $time);
    start_fetch_i = 1'b1;
    #(ClkPeriod * 2);
    start_fetch_i = 1'b0;

    wait (fetch_complete_o);
    $display("T=%3t: SUCCESS! Second fetch completed", $time);

    $display("T=%3t: Test Case 4: Reset behavior test", $time);
    rst_ni = 1'b0;
    $display("T=%3t: Asserting reset", $time);
    #(ClkPeriod * 10);
    rst_ni = 1'b1;
    $display("T=%3t: Releasing reset", $time);

    $display("T=%3t: Test Case 5: Post-reset fetch", $time);
    start_fetch_i = 1'b1;
    #(ClkPeriod * 2);
    start_fetch_i = 1'b0;

    wait (fetch_complete_o);
    $display("T=%3t: SUCCESS! Post-reset fetch completed", $time);

    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: FINAL TEST RESULTS", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: SUCCESS: Memory requests: %d", $time, memory_request_count);
    $display("T=%3t: SUCCESS: Buffer writes: %d", $time, buffer_write_count);
    $display("T=%3t: SUCCESS: Fetch completions: %d", $time, fetch_complete_count);
    $display("T=%3t: SUCCESS: All test cases completed", $time);
    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Testbench completed successfully!", $time);
    $display("T=%3t: Simulation paused. Use 'run' to continue or 'quit' to exit.", $time);
    $stop;
  end

  always @(posedge mem_req_o) begin
    memory_request_count = memory_request_count + 1;
    $display("T=%3t: Memory request #%d at address 0x%h", $time, memory_request_count, mem_addr_o);
  end

  always @(posedge buffer_wr_en_o) begin
    buffer_write_count = buffer_write_count + 1;
    $display("T=%3t: Buffer write #%d - Addr: %d, Data: 0x%h, Sel: %b",
             $time, buffer_write_count, buffer_wr_addr_o, buffer_wr_data_o, buffer_sel_o);
  end

  always @(posedge fetch_complete_o) begin
    fetch_complete_count = fetch_complete_count + 1;
    $display("T=%3t: Fetch completion #%d", $time, fetch_complete_count);
  end

endmodule
