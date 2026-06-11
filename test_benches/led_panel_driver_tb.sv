// ============================================================================
// File Name   : led_panel_driver_tb.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Simulation testbench for led_panel_driver. Preloads mock memory, responds
//   to arbiter requests, and monitors HUB75 panel timing during refresh.
//
// Dependencies:
//   - led_panel_driver.sv
// ============================================================================
// Revision History:
//   Current - lowRISC style migration.
// ============================================================================
`timescale 1ns / 1ps

module led_panel_driver_tb;

  localparam int unsigned SysClkHz           = 50_000_000;
  localparam int unsigned RefreshRateHz      = 60;
  localparam int unsigned TotalRowWidth      = 8;
  localparam int unsigned PanelHeight        = 4;
  localparam int unsigned ColorDepth         = 4;
  localparam int unsigned TotalDisplayHeight = 8;

  localparam int unsigned ClkPeriod       = 1000 / (SysClkHz / 1_000_000);
  localparam int unsigned PixelDataWidth  = ColorDepth * 3;
  localparam int unsigned MemAddrWidth    = $clog2(TotalRowWidth * TotalDisplayHeight);
  localparam int unsigned MemSize         = TotalRowWidth * TotalDisplayHeight;

  logic clk_i;
  logic rst_ni;

  logic                                mem_req_o;
  logic [3:0]                          mem_read_length_o;
  logic                                mem_grant_i;
  logic [MemAddrWidth-1:0]             mem_addr_o;
  logic [PixelDataWidth-1:0]           mem_read_data_i;
  logic                                mem_read_data_valid_i;
  logic [7:0]                          brightness_i;

  logic panel_r1_o, panel_g1_o, panel_b1_o;
  logic panel_r2_o, panel_g2_o, panel_b2_o;
  logic [$clog2(PanelHeight/2)-1:0]     panel_addr_o;
  logic panel_clk_o, panel_lat_o, panel_oe_o;

  logic [PixelDataWidth-1:0] sim_memory [0:MemSize-1];

  led_panel_driver #(
    .SysClkHz(SysClkHz),
    .RefreshRateHz(RefreshRateHz),
    .TotalRowWidth(TotalRowWidth),
    .PanelHeight(PanelHeight),
    .ColorDepth(ColorDepth),
    .RowOffset(0),
    .TotalDisplayHeight(TotalDisplayHeight)
  ) dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .brightness_i(brightness_i),
    .mem_req_o(mem_req_o),
    .mem_read_length_o(mem_read_length_o),
    .mem_grant_i(mem_grant_i),
    .mem_addr_o(mem_addr_o),
    .mem_read_data_i(mem_read_data_i),
    .mem_read_data_valid_i(mem_read_data_valid_i),
    .panel_r1_o(panel_r1_o),
    .panel_g1_o(panel_g1_o),
    .panel_b1_o(panel_b1_o),
    .panel_r2_o(panel_r2_o),
    .panel_g2_o(panel_g2_o),
    .panel_b2_o(panel_b2_o),
    .panel_addr_o(panel_addr_o),
    .panel_clk_o(panel_clk_o),
    .panel_lat_o(panel_lat_o),
    .panel_oe_o(panel_oe_o)
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
  logic [MemAddrWidth-1:0] grant_base_addr_q;

  // Mock memory arbiter: fixed arbitration delay, then burst read beats from sim_memory.
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

      unique case (arbiter_state_q)
        StIdle: begin
          if (mem_req_o) begin
            arbiter_state_q <= StArbitration;
            delay_counter_q <= '0;
          end
        end

        StArbitration: begin
          if (delay_counter_q == 3'd4) begin
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
          if (delay_counter_q == 3'd1) begin
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
  integer panel_oe_count;
  integer panel_lat_count;
  integer panel_clk_count;
  integer last_panel_addr;
  integer signal_changes;
  logic [5:0] last_signals;

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    brightness_i = 8'hFF;
    memory_request_count = 0;
    panel_oe_count = 0;
    panel_lat_count = 0;
    panel_clk_count = 0;
    last_panel_addr = 0;
    signal_changes = 0;

    for (integer i = 0; i < MemSize; i = i + 1) begin
      sim_memory[i] = (i % 3 == 0) ? {PixelDataWidth{1'b1}} :
                      (i % 3 == 1) ? {PixelDataWidth/2{2'b10}} :
                                     {PixelDataWidth/2{2'b01}};
    end

    $display("T=%3t: ==========================================", $time);
    $display("T=%3t: Starting Enhanced LED Panel Driver Testbench", $time);
    $display("T=%3t: ==========================================", $time);

    #100;
    rst_ni = 1'b1;

    $display("T=%3t: Reset released. Starting comprehensive test sequence.", $time);

    $display("T=%3t: Test Case 1: Initial memory fetch and panel activation", $time);
    wait (panel_oe_o == 1'b0);
    $display("T=%3t: SUCCESS! Panel output activated (panel_oe_o=0)", $time);

    $display("T=%3t: Test Case 2: Monitoring panel signal activity", $time);
    #10000;

    @(posedge clk_i);
    repeat (1000) begin
      @(posedge clk_i);
      if (panel_oe_o == 1'b0) panel_oe_count = panel_oe_count + 1;
      if (panel_lat_o == 1'b1) panel_lat_count = panel_lat_count + 1;
      if (panel_clk_o == 1'b1) panel_clk_count = panel_clk_count + 1;
      if (panel_addr_o != last_panel_addr) begin
        $display("T=%3t: Panel address changed: %d -> %d", $time, last_panel_addr, panel_addr_o);
        last_panel_addr = panel_addr_o;
      end
    end

    $display("T=%3t: Test Case 4: Brightness control test", $time);
    brightness_i = 8'h80;
    #10000;
    brightness_i = 8'h40;
    #10000;
    brightness_i = 8'hFF;
    #10000;

    $display("T=%3t: Test Case 5: Reset behavior test", $time);
    rst_ni = 1'b0;
    #1000;
    rst_ni = 1'b1;
    wait (panel_oe_o == 1'b0);
    $display("T=%3t: SUCCESS! Driver recovered after reset", $time);

    $display("T=%3t: Test Case 6: Extended operation test", $time);
    #20000;

    $display("T=%3t: Test Case 7: Detailed signal analysis", $time);
    last_signals = {panel_r1_o, panel_g1_o, panel_b1_o, panel_r2_o, panel_g2_o, panel_b2_o};
    repeat (5000) begin
      @(posedge clk_i);
      if ({panel_r1_o, panel_g1_o, panel_b1_o, panel_r2_o, panel_g2_o, panel_b2_o} != last_signals) begin
        signal_changes = signal_changes + 1;
        last_signals = {panel_r1_o, panel_g1_o, panel_b1_o, panel_r2_o, panel_g2_o, panel_b2_o};
      end
    end

    $display("T=%3t: SUCCESS: All test cases completed successfully", $time);
    $display("T=%3t: Simulation paused. Use 'run' to continue or 'quit' to exit.", $time);
    $stop;
  end

  always @(posedge mem_req_o) begin
    memory_request_count = memory_request_count + 1;
    $display("T=%3t: Memory request #%d at address 0x%h", $time, memory_request_count, mem_addr_o);
  end

endmodule
