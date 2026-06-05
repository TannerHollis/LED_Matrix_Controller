# Verilog / SystemVerilog Style

This project follows the [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md) for all hand-written RTL and testbenches.

## Adopted rules (summary)

| Construct | Style |
|-----------|--------|
| Modules | `lower_snake_case` |
| Parameters (tunable) | `UpperCamelCase` with explicit type (`int unsigned`, etc.) |
| Derived `localparam` | `UpperCamelCase` |
| True constants / opcodes | `ALL_CAPS` |
| FSM state enum types | `lower_snake_case_e`; state values `UpperCamelCase` (`StIdle`, …) |
| Signals, ports, functions | `lower_snake_case` |
| Port suffixes | `_i` input, `_o` output, `_io` bidirectional; active-low `_n` before direction (`rst_ni`) |
| Clocks | `clk` or `clk_<domain>`; primary clock port `clk_i` |
| Resets | Active-low async `rst_n` / `rst_ni` |
| Sequential logic | `always_ff`; combinational `always_comb` |
| Storage | `logic` (not `reg` / `wire` in new RTL) |
| Literals | Explicit width (`8'd0`, `1'b0`, `'0`) |
| Indentation | 2 spaces per level; 4 spaces for line continuation |
| FSMs | Separate `always_comb` (next state / outputs) and `always_ff` (state register) |

## Project extensions

- **File headers** — Keep the project header block (`File Name`, `Project`, `Author`, `Description`, `Parameters`, `Dependencies`, `Revision History`) above each hand-written module.
- **File extensions** — Hand-written RTL and testbenches use **`.sv`**. Quartus treats `.sv` as SystemVerilog by default (no global `VERILOG_INPUT_VERSION` override needed). Wizard/vendor megafunctions remain **`.v`** (Verilog-2001).
- **Quartus projects** — BIST `.qsf` files list hand-written sources as `SYSTEMVERILOG_FILE …/*.sv` and wizard FIFOs as `VERILOG_FILE …/*_fifo.v`. PLL is included via `pll_100mhz.qip`.
- **Wizard / vendor IP** — Do not rename or reformat (`pll_100mhz.v`, `pll_100mhz_bb.v`, `sdram_read_fifo.v`, `sdram_write_fifo.v`).
- **Board BIST tops** — Top-level pins (`clk_50mhz`, `btn_start`, `btn_reset`, `led_status`, external `sdram_*`) may keep legacy names for Quartus pin assignments; internal logic uses `clk_i` / `rst_ni` and migrated child port names.

## Migration status

All hand-written RTL, verification BIST tops, and simulation testbenches are migrated to this guide.

| Category | Extension | Status |
|----------|-----------|--------|
| Core RTL (repo root) | `.sv` | Complete |
| SDRAM stack (`sdram_components/` except wizard IP) | `.sv` | Complete |
| Verification BIST tops | `.sv` | Complete |
| Simulation testbenches (`test_benches/`) | `.sv` | Complete |
| Wizard IP (`pll_100mhz*.v`, `sdram_*_fifo.v`) | `.v` | Unchanged (vendor output) |

### Optional follow-ups (non-blocking)

- BIST orchestration FSMs may still use numeric `localparam` state IDs instead of `typedef enum` in a few large tops; behavior is correct.
- Some BIST tops retain `reg`/`wire` on board-facing ports and SDRAM pin exports for Quartus compatibility.

## References

- [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md)
- [Condensed appendix](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md#appendix---condensed-style-guide)
