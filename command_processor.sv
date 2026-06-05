// ============================================================================
// File Name   : command_processor.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Parses SPI/Ethernet command bytes and issues memory arbiter requests for
//   pixel writes, reads, and buffer flip. Acts as a low-priority memory client.
//   All memory transactions use read_length = 1 and write_length = 1.
//
// Parameters  (UpperCamelCase per VERILOG_STYLE.md):
//   TotalWidth, TotalHeight, ColorDepth, CmdWidth
//
// Dependencies:
//   - memory_arbiter.sv (client port)
// ============================================================================
// Revision History:
//   Current - Multi-byte write/read/flip command protocol over SPI or Ethernet.
// ============================================================================

module command_processor #(
  parameter int unsigned TotalWidth   = 32,
  parameter int unsigned TotalHeight  = 32,
  parameter int unsigned ColorDepth   = 4,
  parameter int unsigned CmdWidth     = 8
) (
  // System Signals
  input  logic clk_i,
  input  logic rst_ni,

  // SPI Interface
  input  logic [CmdWidth-1:0] spi_data_in_i,
  input  logic                spi_data_valid_i,

  // Frame Control (for DDR-based system)
  output logic frame_ready_o,

  // Memory Arbiter Client Interface
  output logic                                mem_req_o,
  output logic                                mem_write_o,
  output logic [3:0]                          mem_read_length_o,
  output logic [3:0]                          mem_write_length_o,
  output logic [$clog2(TotalWidth*TotalHeight)-1:0] mem_addr_o,
  output logic [ColorDepth*3-1:0]             mem_write_data_o,
  input  logic                                mem_grant_i,
  input  logic [ColorDepth*3-1:0]             mem_read_data_i,
  input  logic                                mem_read_data_valid_i,
  output logic [ColorDepth*3-1:0]             read_data_out_o,
  output logic                                read_data_valid_o
);

  localparam logic [7:0] CMD_WRITE_PIXEL = 8'h01;
  localparam logic [7:0] CMD_FLIP_BUFFER = 8'h02;
  localparam logic [7:0] CMD_READ_PIXEL  = 8'h03;

  localparam int unsigned AddrWidth = $clog2(TotalWidth * TotalHeight);
  localparam int unsigned DataWidth = ColorDepth * 3;
  localparam int unsigned AddrBytes = (AddrWidth + 7) / 8;
  localparam int unsigned DataBytes = (DataWidth + 7) / 8;

  typedef enum logic [2:0] {
    StIdle,
    StWaitCmd,
    StWritePixelAddr,
    StWritePixelData,
    StExecuteWrite,
    StReadPixelAddr,
    StExecuteRead,
    StWaitReadData
  } cmd_state_e;

  cmd_state_e cmd_state_d, cmd_state_q;

  logic [$clog2(TotalWidth*TotalHeight)-1:0] addr_reg_q;
  logic [ColorDepth*3-1:0]                   data_reg_q;
  logic [7:0]                                byte_counter_q;
  logic [7:0]                                current_cmd_q;

  logic [AddrWidth-1:0] spi_addr_byte;
  logic [DataWidth-1:0] spi_data_byte;

  assign spi_addr_byte = {{(AddrWidth-CmdWidth){1'b0}}, spi_data_in_i};
  assign spi_data_byte = {{(DataWidth-CmdWidth){1'b0}}, spi_data_in_i};

  always_comb begin
    cmd_state_d = cmd_state_q;

    unique case (cmd_state_q)
      StIdle: begin
        if (spi_data_valid_i) begin
          cmd_state_d = StWaitCmd;
        end
      end

      StWaitCmd: begin
        unique case (current_cmd_q)
          CMD_WRITE_PIXEL: cmd_state_d = StWritePixelAddr;
          CMD_FLIP_BUFFER: cmd_state_d = StIdle;
          CMD_READ_PIXEL:  cmd_state_d = StReadPixelAddr;
          default:         cmd_state_d = StIdle;
        endcase
      end

      StWritePixelAddr: begin
        if (spi_data_valid_i && byte_counter_q == AddrBytes - 1) begin
          cmd_state_d = StWritePixelData;
        end
      end

      StWritePixelData: begin
        if (spi_data_valid_i && byte_counter_q == DataBytes - 1) begin
          cmd_state_d = StExecuteWrite;
        end
      end

      StExecuteWrite: begin
        if (mem_grant_i) begin
          cmd_state_d = StIdle;
        end
      end

      StReadPixelAddr: begin
        if (spi_data_valid_i && byte_counter_q == AddrBytes - 1) begin
          cmd_state_d = StExecuteRead;
        end
      end

      StExecuteRead: begin
        if (mem_grant_i) begin
          cmd_state_d = StWaitReadData;
        end
      end

      StWaitReadData: begin
        if (mem_read_data_valid_i) begin
          cmd_state_d = StIdle;
        end
      end

      default: cmd_state_d = StIdle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_state_q        <= StIdle;
      frame_ready_o      <= 1'b0;
      mem_req_o          <= 1'b0;
      mem_write_o        <= 1'b0;
      mem_read_length_o  <= 4'd1;
      mem_write_length_o <= 4'd1;
      mem_addr_o         <= '0;
      mem_write_data_o   <= '0;
      read_data_out_o    <= '0;
      read_data_valid_o  <= 1'b0;
      byte_counter_q     <= 8'd0;
      current_cmd_q      <= 8'd0;
      addr_reg_q         <= '0;
      data_reg_q         <= '0;
    end else begin
      cmd_state_q <= cmd_state_d;

      frame_ready_o     <= 1'b0;
      read_data_valid_o <= 1'b0;
      mem_read_length_o  <= 4'd1;
      mem_write_length_o <= 4'd1;

      if (cmd_state_q != StExecuteWrite && cmd_state_q != StExecuteRead) begin
        mem_req_o <= 1'b0;
      end

      if (spi_data_valid_i) begin
        unique case (cmd_state_q)
          StIdle: begin
            current_cmd_q  <= spi_data_in_i;
            byte_counter_q <= 8'd0;
            addr_reg_q     <= '0;
            data_reg_q     <= '0;
            if (spi_data_in_i == CMD_FLIP_BUFFER) begin
              frame_ready_o <= 1'b1;
            end
          end

          StWritePixelAddr: begin
            addr_reg_q <= addr_reg_q | (spi_addr_byte << (byte_counter_q * 8));
            byte_counter_q <= byte_counter_q + 8'd1;
            if (byte_counter_q == AddrBytes - 1) begin
              byte_counter_q <= 8'd0;
            end
          end

          StWritePixelData: begin
            data_reg_q <= data_reg_q | (spi_data_byte << (byte_counter_q * 8));
            byte_counter_q <= byte_counter_q + 8'd1;
            if (byte_counter_q == DataBytes - 1) begin
              byte_counter_q <= 8'd0;
            end
          end

          StReadPixelAddr: begin
            addr_reg_q <= addr_reg_q | (spi_addr_byte << (byte_counter_q * 8));
            byte_counter_q <= byte_counter_q + 8'd1;
            if (byte_counter_q == AddrBytes - 1) begin
              byte_counter_q <= 8'd0;
            end
          end

          default: ;
        endcase
      end

      if (cmd_state_q == StExecuteWrite) begin
        mem_req_o        <= !mem_grant_i;
        mem_write_o      <= 1'b1;
        mem_addr_o       <= addr_reg_q;
        mem_write_data_o <= data_reg_q;
      end

      if (cmd_state_q == StExecuteRead) begin
        mem_req_o   <= !mem_grant_i;
        mem_write_o <= 1'b0;
        mem_addr_o  <= addr_reg_q;
      end

      if (cmd_state_q == StWaitReadData && mem_read_data_valid_i) begin
        read_data_out_o   <= mem_read_data_i;
        read_data_valid_o <= 1'b1;
      end
    end
  end

endmodule
