// ============================================================================
// File Name   : sdram_model.sv
// Project     : LED Matrix Controller
// Author      : Tanner J. Hollis
// Description :
//   Behavioral SDRAM chip model for simulation testbenches. Decodes basic
//   ACTIVATE/READ/WRITE/PRECHARGE commands and models CAS latency. Not
//   cycle-accurate for all JEDEC features.
//
// Parameters  :
//   AddrWidth  - SDRAM address bus width (Default: 13)
//   DataWidth  - SDRAM data bus width (Default: 16)
//   RowWidth   - Row address width (Default: 13)
//   ColWidth   - Column address width (Default: 9)
//   BankWidth  - Bank address width (Default: 2)
//   CasLatency - Read CAS latency in cycles (Default: 3)
//
// Dependencies:
//   (none)
//
// Revision History:
//   Current - Simulation-only SDRAM behavioral model (lowRISC port naming).
// ============================================================================

module sdram_model #(
  parameter int unsigned AddrWidth  = 13,
  parameter int unsigned DataWidth  = 16,
  parameter int unsigned RowWidth   = 13,
  parameter int unsigned ColWidth   = 9,
  parameter int unsigned BankWidth  = 2,
  parameter int unsigned CasLatency = 3
) (
  input  logic                         sdram_clk_i,
  input  logic                         sdram_cke_i,
  input  logic                         sdram_cs_ni,
  input  logic [BankWidth-1:0]         sdram_ba_i,
  input  logic [AddrWidth-1:0]         sdram_addr_i,
  inout  wire  [DataWidth-1:0]         sdram_dq_io,
  input  logic                         sdram_ras_ni,
  input  logic                         sdram_cas_ni,
  input  logic                         sdram_we_ni,
  input  logic [1:0]                   sdram_dqm_i
);

  localparam logic [3:0] CMD_NOP       = 4'b0111;
  localparam logic [3:0] CMD_ACTIVE    = 4'b0011;
  localparam logic [3:0] CMD_READ      = 4'b0101;
  localparam logic [3:0] CMD_WRITE     = 4'b0100;
  localparam logic [3:0] CMD_PRECHARGE = 4'b0010;
  localparam logic [3:0] CMD_LOAD_MR   = 4'b0000;

  logic [DataWidth-1:0] memory_array [0:(1<<RowWidth)-1][0:(1<<ColWidth)-1][0:(1<<BankWidth)-1];

  logic [RowWidth-1:0]  active_row [0:(1<<BankWidth)-1];
  logic [3:0]           cmd_d;
  logic [CasLatency:0]  cas_counter_q;
  logic                 read_pending_q;
  logic [DataWidth-1:0] read_data_q;

  assign sdram_dq_io = (read_pending_q && cas_counter_q == CasLatency)
      ? read_data_q : {DataWidth{1'bz}};

  always_comb begin
    cmd_d = {sdram_ras_ni, sdram_cas_ni, sdram_we_ni, sdram_cs_ni};
  end

  always_ff @(posedge sdram_clk_i) begin
    if (sdram_cke_i) begin
      if (read_pending_q) begin
        if (cas_counter_q < CasLatency)
          cas_counter_q <= cas_counter_q + 1'b1;
        else
          read_pending_q <= 1'b0;
      end

      if (!sdram_cs_ni) begin
        case (cmd_d)
          CMD_ACTIVE: begin
            active_row[sdram_ba_i] <= sdram_addr_i[RowWidth-1:0];
            $display("SDRAM_MODEL: ACTIVATE Bank %d, Row %d", sdram_ba_i, sdram_addr_i);
          end

          CMD_WRITE: begin
            if (!sdram_dqm_i[0])
              memory_array[active_row[sdram_ba_i]][sdram_addr_i[ColWidth-1:0]][sdram_ba_i][7:0]
                  <= sdram_dq_io[7:0];
            if (!sdram_dqm_i[1])
              memory_array[active_row[sdram_ba_i]][sdram_addr_i[ColWidth-1:0]][sdram_ba_i][15:8]
                  <= sdram_dq_io[15:8];
            $display("SDRAM_MODEL: WRITE to Bank %d, Row %d, Col %d, Data %h",
                     sdram_ba_i, active_row[sdram_ba_i], sdram_addr_i, sdram_dq_io);
          end

          CMD_READ: begin
            read_data_q    <= memory_array[active_row[sdram_ba_i]][sdram_addr_i[ColWidth-1:0]][sdram_ba_i];
            cas_counter_q  <= '0;
            read_pending_q <= 1'b1;
            $display("SDRAM_MODEL: READ from Bank %d, Row %d, Col %d",
                     sdram_ba_i, active_row[sdram_ba_i], sdram_addr_i);
          end

          CMD_PRECHARGE: begin
            $display("SDRAM_MODEL: PRECHARGE Bank %d", sdram_ba_i);
          end

          default: ;
        endcase
      end
    end
  end

endmodule
