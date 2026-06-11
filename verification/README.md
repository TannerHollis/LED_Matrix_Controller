# Hardware Verification (Quartus BIST)

Synthesizable board tops for SDRAM and memory-arbiter bring-up on the DE2-115. Each subfolder contains the BIST top, Quartus project (`.qpf`/`.qsf`), and compile output (`output_files/`).

Simulation testbenches live in `[test_benches/](../test_benches/README.md)`.

Shared pin, device, and timing constraints live in `board_assignments.qsf`, `board_no_sdram_assignments.qsf`, `bist_timing.sdc`, and `bist_sdram_timing.sdc`. SDRAM projects source `board_assignments.qsf` (loads `bist_sdram_timing.sdc`); non-SDRAM projects source `board_no_sdram_assignments.qsf` or per-project `board_pins.qsf` (`bist_timing.sdc`); `led_panel_controller/` uses `led_panel_controller_bist_timing.sdc`; `bist_sdram_io.sdc` is optional SDRAM pad I/O delay.

## Coding style

RTL follows the [lowRISC Verilog style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md); see [`VERILOG_STYLE.md`](../VERILOG_STYLE.md) for project rules and migration status.

Hand-written sources are `.sv` and listed in each BIST `.qsf` as `SYSTEMVERILOG_FILE`. Wizard FIFOs stay `.v` as `VERILOG_FILE`. If you add a new Quartus project, follow that split — do not rely on a global `VERILOG_INPUT_VERSION` override.

## Hardware verification checklist

**Legend:** Yes = board verified · Indirect = verified as part of a passing stack · Sim = simulation only · No = not yet verified on hardware · Pending = BIST exists, board run not confirmed

### Recommended order

Work bottom-up: prove each layer before integrating the full `led_panel_controller`.


| Step   | Module(s)                                             | Sim | HW       | Status / BIST top                                                                                                |
| ------ | ----------------------------------------------------- | --- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| **1**  | `sdram_controller` (+ command, data path, FIFOs, PLL) | —   | Yes      | `[sdram_bist_top](sdram_controller/)` — direct SDRAM write/read sweep                                            |
| **2**  | `sdram_arbiter_adapter`                               | —   | Indirect | Exercised by steps 3–4; no standalone BIST yet                                                                   |
| **3**  | `memory_arbiter`                                      | Sim | Yes      | `[memory_arbiter_bist_top](memory_arbiter/)` — mock slave, priority + multi-client                               |
| **4**  | Arbiter + adapter + SDRAM (production path)           | —   | Yes      | `[memory_arbiter_bist_dual_top](memory_arbiter_w_sdram_dual/)` — 2 clients, contention, **16M-word stress pass** |
| **5**  | `line_buffer_ram`                                     | —   | Yes      | `[line_buffer_ram_bist_top](line_buffer_ram/)` — full 768-word line buffer (production width)                    |
| **6**  | `buffer_controller`                                   | —   | Yes      | `[buffer_controller_bist_top](buffer_controller/)` — controller-only ping-pong routing/handshake BIST            |
| **7**  | `memory_fetcher`                                      | Sim | Yes      | `[memory_fetcher_bist_top](memory_fetcher/)` — real SDRAM preload/read → buffer-write checker                    |
| **8**  | `display_driver`                                      | Sim | Yes      | `[display_driver_bist_top](display_driver/)` — driver-only HUB75 timing/data checker                             |
| **9**  | `led_panel_driver`                                    | Sim | Yes      | `[led_panel_driver_bist_top](led_panel_driver/)` — SDRAM-backed integrated display-pipeline BIST                 |
| **10** | `spi_slave`                                           | Sim | Yes      | [`spi_slave_bist_top`](spi_slave/) — internal SPI master byte script → `data_valid` checker                      |
| **11** | `command_processor` + SDRAM                           | Sim | Pending  | [`command_processor_bist_top`](command_processor/) — scripted write/read/flip through SDRAM; SDRAM init gate added |
| **12** | `led_panel_controller` (SPI-only)                     | Sim | Pending  | [`led_panel_controller_bist_top`](led_panel_controller/) — SPI → SDRAM → HUB75; init gate + faster write settle   |
| **13** | `ethernet_interface`                                  | —   | Deferred | Skipped for now; RMII/network verification is intentionally out of scope                                         |
| **14** | `led_panel_controller` (full Ethernet build)          | —   | Deferred | Re-enable `ENABLE_ETHERNET` only after the SPI-only top is proven                                                |


### Production SDRAM read path

The production stack uses **8-beat SDRAM burst reads** through `memory_arbiter` and `sdram_arbiter_adapter`. **Host writes remain single-beat** (`write_length = 1`, `SC_SINGLE_WRITE = 1`).

| Layer | Behavior |
| ----- | -------- |
| `memory_arbiter` | Per-client `read_length` / `write_length` (1..8). Holds the read grant across N `read_data_valid` beats before the next client can win arbitration. |
| `sdram_arbiter_adapter` | Client `read_length` selects how many arbiter beats to deliver; SDRAM `read_length` is always `SC_BL` (8). Writes are single-beat. `S_RD_SYNC` (write-to-read turnaround) runs only after a write (`writes_pending` or `write_used != 0`); pure read bursts skip sync. Default `WR_TURNAROUND_WAIT = 64` host cycles after FIFO drain. |
| `sdram_controller` | `SC_BL(8)` default on production/BIST tops (except direct `sdram_bist_top`, which parameterizes `BURST_LEN`). `SC_SINGLE_WRITE(1)` programs mode-register **A9 = 1** (*burst read + single write* per W9825G6KH). |
| `memory_fetcher` | Issues `mem_read_length = 8` on column-aligned sequential fetches (`col[2:0] == 0` and ≥ 8 words remain). |
| `command_processor` | `read_length` / `write_length` fixed at 1 (single-beat pixel access). |

**Host rules:** `read_length == SC_BL` on SDRAM read commands; `write_length == 1` when `SC_SINGLE_WRITE = 1`.

**Recommended verify after memory-path changes:** `memory_fetcher_bist_top`, then `memory_arbiter_bist_single_top`.

**Future work:** burst host writes (`SC_SINGLE_WRITE = 0`), sub-burst read lengths without FIFO discard.

### What is already proven on hardware

- **SDRAM stack** — external W9825G6KH; `sdram_bist_top` exercises direct BL=8 burst read/write; production path uses BL=8 reads + single writes via adapter
- **Memory arbitration** — fixed priority, grant/`read_data_valid` routing, post-grant cooldown
- **Adapter handshakes** — write-gated read sync (`WR_TURNAROUND_WAIT`), read flush, sequential burst fast path
- **End-to-end memory path** — same modules wired as `led_panel_controller` (arbiter → adapter → controller)
- **Line buffer RAM** — M9K BRAM at 768×12-bit; fill/verify/rewrite phases via `line_buffer_ram_bist_top`
- **Buffer controller** — controller-only ping-pong routing/handshake behavior via `buffer_controller_bist_top`
- **Memory fetcher** — SDRAM-backed preload/read path and buffer-write sequence via `memory_fetcher_bist_top`
- **Arbiter + SDRAM single-client** — burst read sweep via `memory_arbiter_bist_single_top`
- **Display driver** — driver-only HUB75 timing/data sequence via `display_driver_bist_top`
- **LED panel driver** — SDRAM-backed integrated display-pipeline path via `led_panel_driver_bist_top`
- **SPI slave** — internal SPI master byte script and `data_valid` checker via `spi_slave_bist_top`

### Not yet verified on hardware


| Area                 | Modules                                                                     | Notes                                                          |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------- |
| **Command ingress**  | `command_processor`                                                         | BIST exists; needs board run confirmation                      |
| **Network**          | `ethernet_interface`                                                        | Deferred; skip Ethernet-related verification for now           |
| **Full system**      | `led_panel_controller`                                                      | SPI-only BIST exists; needs board run confirmation             |


### Suggested next BIST targets

1. **`command_processor_bist_top`** — verify SPI-scripted write/read/flip through SDRAM (wait ~1 ms after reset for SDRAM init before pressing start)
2. **`led_panel_controller_bist_top`** — full SPI-only stack; default smoke is 64×32 (2048 SPI writes — allow several minutes, or shrink `PANEL_WIDTH`/`PANEL_HEIGHT` in Quartus for a faster smoke)
3. **`led_panel_controller` parameter sweep** — scale `NUM_PANEL_ROWS` / `NUM_PANELS_PER_ROW` after the default smoke passes
4. **Burst host writes** — `SC_SINGLE_WRITE = 0`, adapter burst-write path (not yet implemented)
5. **Ethernet** — deferred until the SPI-only top is proven

## Timing constraints

| SDC file | Used by |
| -------- | ------- |
| `bist_timing.sdc` | Single-clock BIST tops (50 MHz only): `memory_arbiter`, `line_buffer_ram`, `display_driver`, `spi_slave`, … |
| `bist_sdram_timing.sdc` | SDRAM BIST tops via `board_assignments.qsf`: `sdram_controller`, `memory_fetcher`, `led_panel_driver`, … |
| `led_panel_controller_bist_timing.sdc` | `led_panel_controller_bist_top` only (100 MHz host + BIST SPI false paths) |
| `buffer_controller_bist_timing.sdc` | `buffer_controller_bist_top` only |

Common rules:

- **50 MHz** board clock `clk_board_50mhz` on `clk_50mhz`
- **100 MHz** host / SDRAM via explicit `create_generated_clock` on `sdram_clock_gen` PLL output (not `derive_pll_clocks` inside `sdram_controller`)
- Host and SDRAM chip clock pin share the same PLL; FIFO CDC is same-clock in the current design
- False paths on `btn_start` / `btn_reset` and `led_status`
- BIST harness @ 50 MHz → DUT (`command_processor`, `spi_slave`) false-pathed where scripted
- Optional SDRAM pad I/O delays in `bist_sdram_io.sdc` (clock `clk_sdram_100mhz` on `sdram_clk`)

After compile, check **Timing Analyzer** or `*.sta.rpt` for setup/hold slack.

If `quartus_map` crashes on exit with an STA/Tcl access violation (24.1 Lite), check whether `output_files/*.map.rpt` was still written — the build may have succeeded. Delete `db/`, recompile, and avoid Tcl `if`/`foreach` in active SDC files.

## Projects


| Folder                           | Top module                       | Path exercised                                            | Board status          |
| -------------------------------- | -------------------------------- | --------------------------------------------------------- | --------------------- |
| `sdram_controller/`              | `sdram_bist_top`                 | BIST FSM → `sdram_controller` (no arbiter)                | Yes — baseline        |
| `memory_arbiter/`                | `memory_arbiter_bist_top`        | Client FSM(s) → `memory_arbiter` → mock slave             | Yes — arbiter-only    |
| `memory_arbiter_w_sdram_single/` | `memory_arbiter_bist_single_top` | Full stack through `sdram_controller`                     | Yes — single client   |
| `memory_arbiter_w_sdram_dual/`   | `memory_arbiter_bist_dual_top`   | 2 clients → production memory path                        | Yes — 16M-word stress |
| `line_buffer_ram/`               | `line_buffer_ram_bist_top`       | `line_buffer_ram` M9K BRAM                                | Yes — 768-word pass   |
| `buffer_controller/`             | `buffer_controller_bist_top`     | `buffer_controller` only; synthetic buffer-port read data | Yes                   |
| `memory_fetcher/`                | `memory_fetcher_bist_top`        | preload client + `memory_fetcher` → arbiter → SDRAM stack | Yes                   |
| `display_driver/`                | `display_driver_bist_top`        | `display_driver` only; synthetic buffer read data         | Yes                   |
| `led_panel_driver/`              | `led_panel_driver_bist_top`      | preload client + `led_panel_driver` → arbiter → SDRAM     | Yes                   |
| `spi_slave/`                     | `spi_slave_bist_top`             | internal SPI master → `spi_slave` byte checker            | Yes                   |
| `command_processor/`             | `command_processor_bist_top`     | scripted command bytes → `command_processor` → SDRAM      | Pending               |
| `led_panel_controller/`          | `led_panel_controller_bist_top`  | SPI byte script → full controller → SDRAM/display path     | Pending               |


**Pinout:** `clk_50mhz`, active-low `btn_start` / `btn_reset`, active-low `led_status`; SDRAM projects also use the full SDRAM bundle.

**LED policy (active-low):** idle OFF, fast blink while running, solid ON pass, slow blink fail.

**Data pattern:** `mem_pattern(addr) = addr[15:0] ^ 16'hA5C3` (12-bit client data zero-padded to 16-bit SDRAM words inside `sdram_arbiter_adapter`).

### `sdram_bist_top`

- Source: `sdram_controller/sdram_bist_top.sv`
- Default `BURST_LEN = 8` (legal values: 1, 2, 4, 8). Passed to `sdram_controller` as `SC_BL`; `write_length` / `read_length` match `BURST_LEN` on each burst.
- Default `LAST_TEST_ADDR = 24'h00FF_FFFF` (full 16M-word sweep). Sweep must be burst-aligned: `(LAST - FIRST + 1) % BURST_LEN == 0`.
- **Smoke test:** `BURST_LEN = 8`, `LAST_TEST_ADDR = 24'h0000_003F` (64 words = 8 bursts).
- **BL=1 regression:** set `BURST_LEN = 1` for single-beat SDRAM behavior.
- Fastest path; use as SDRAM baseline before arbiter tops.

### `memory_arbiter_bist_top` (arbiter-only)

- Source: `memory_arbiter/memory_arbiter_bist_top.sv` + `memory_arbiter_mock_slave.sv`
- Stack: client BIST FSM(s) → `memory_arbiter` → synthesizable mock memory slave (no SDRAM pins)
- Parameter **`NUM_CLIENTS`**: number of client ports to exercise (default 2)
- Parameter **`NUM_LOW_PRI_CLIENTS`**: low-priority client count (default 1; clients `0..N-1`, high-priority from index `NUM_LOW_PRI_CLIENTS`)
- Round A: each client write/read sweep `0..LAST_TEST_ADDR` in its address region
- Round B (if `NUM_CLIENTS >= 2`): simultaneous requests; highest-priority client must grant first
- Defaults: `LAST_TEST_ADDR = 24'h00_003F`, `OP_WAIT_TIMEOUT = 24'd10_000_000`
- Pinout: `clk_50mhz`, buttons, `led_status` only (`board_pins.qsf`)

### `memory_arbiter_bist_single_top` (single-client SDRAM)

- Source: `memory_arbiter_w_sdram_single/memory_arbiter_bist_single_top.sv`
- Full stack with **burst read sweep** (`read_length = 8`, `write_length = 1`); adapter `SC_BL(8)`, controller `SC_SINGLE_WRITE(1)`
- Default `LAST_TEST_ADDR = 24'h00FF_FFFF` in source (full sweep unless overridden in Quartus); `(LAST + 1)` must be a multiple of 8

### `memory_arbiter_bist_dual_top` (dual-client SDRAM)

- Source: `memory_arbiter_w_sdram_dual/memory_arbiter_bist_dual_top.sv`
- `NUM_CLIENTS = 2`, `NUM_LOW_PRI_CLIENTS = 1` (client 0 low, client 1 high)
- One button press runs three test rounds:
  1. **Round A** — client 0 write/read sweep `0..LAST_TEST_ADDR`
  2. **Round B** — client 1 write/read sweep `PROBE_BASE .. PROBE_BASE+PROBE_LEN-1` with `hi_mem_pattern(addr) = mem_pattern(addr ^ 16'hA5C3)`
  3. **Round C** — 16 rounds of simultaneous write requests on different addresses; high-priority client releases first, then low; verify both regions
- Defaults: `LAST_TEST_ADDR = 24'h00FF_FFFF`, `PROBE_BASE = 24'h01_0000`, `PROBE_LEN = 16711680`, `CONTENTION_ROUNDS = 16`
- Full sweep ~1–2 min @ 50 MHz; use `24'h00_003F` for a quick smoke test

### `line_buffer_ram_bist_top`

- Source: `line_buffer_ram/line_buffer_ram_bist_top.sv`
- Stack: BIST FSM → `line_buffer_ram` (no SDRAM, no panel pins)
- Default geometry: `DATA_WIDTH = 12`, `DEPTH = 768` (64 px/panel × 12 panels — one full M9K at 9216 bits)
- Phases: fill → read verify → read-old/write-new rewrite → alt-pattern verify
- Runtime: ~7700 cycles (~150 µs @ 50 MHz); override `DEPTH = 64` in Quartus for a quick smoke test
- Pinout: `clk_50mhz`, buttons, `led_status` only (`board_pins.qsf`)

### `buffer_controller_bist_top`

- Source: `buffer_controller/buffer_controller_bist_top.sv`
- Stack: mock fetch/display agents → `buffer_controller` only; buffer read data is synthetic
- Default geometry: `TOTAL_ROW_WIDTH = 64`, `PANEL_HEIGHT = 32`, `COLOR_DEPTH = 4`, `SWAP_ROUNDS = 4` (override `TOTAL_ROW_WIDTH = 768` for production row width)
- Tests: row-pair priming from buffer set 0 (`ready` after first fetch complete), second priming fetch before display, `row_pair_done`-paced buffer swaps, write-port routing, read-address fanout, read-data muxing, and ignored mid-run start bounce
- Handshake: one mock fetch = one row pair (top + bottom line); steady-state fetches start on `row_pair_done`
- Runtime: ~`(2 × ROW_WIDTH) + (ROW_WIDTH × SWAP_ROUNDS)` cycles @ 50 MHz for mock agents
- Pinout: `clk_50mhz`, buttons, `led_status` only (`board_pins.qsf`)

### `memory_fetcher_bist_top`

- Source: `memory_fetcher/memory_fetcher_bist_top.sv`
- Stack: preload client + `memory_fetcher` → `memory_arbiter` → `sdram_arbiter_adapter` → `sdram_controller` (`SC_BL(8)`, burst reads from fetcher)
- Default geometry: `TOTAL_ROW_WIDTH = 1024`, `PANEL_HEIGHT = 32`, `TOTAL_DISPLAY_HEIGHT = 4`, `ROW_OFFSET = 0`
- Flow: preload one row pair (`2 × TOTAL_ROW_WIDTH` words) with `mem_pattern(addr)`, pulse `start_fetch` with `row_pair_index = 0`, then verify `buffer_wr_en`, `buffer_sel`, `buffer_wr_addr`, and `buffer_wr_data`
- Client priority: preload client 0 is low priority; `memory_fetcher` client 1 is high priority
- Pinout: `clk_50mhz`, buttons, `led_status`, and the full SDRAM bundle (`board_assignments.qsf`)

### `display_driver_bist_top`

- Source: `display_driver/display_driver_bist_top.sv`
- Stack: synthetic buffer pattern source → `display_driver` → internal HUB75 timing/data checker
- Default geometry: `TOTAL_ROW_WIDTH = 1024`, `PANEL_HEIGHT = 32`, `COLOR_DEPTH = 4`, `REFRESH_RATE_HZ = 60`
- Tests: start/busy/complete sequencing, `row_pair_done` pulse count, buffer read address countdown, panel clock pulse count, latch count/address, OE activity, and RGB bit selection for each BCM plane
- Pinout: `clk_50mhz`, buttons, `led_status` only (`board_no_sdram_assignments.qsf`); HUB75 outputs are internal checker signals in this first BIST

### `led_panel_driver_bist_top`

- Source: `led_panel_driver/led_panel_driver_bist_top.sv`
- Stack: preload client + `led_panel_driver` → `memory_arbiter` → `sdram_arbiter_adapter` → `sdram_controller`
- Default geometry: `TOTAL_ROW_WIDTH = 1024`, `PANEL_HEIGHT = 32`, `TOTAL_DISPLAY_HEIGHT = 32`, `COLOR_DEPTH = 4`, `REFRESH_RATE_HZ = 60`
- Tests: SDRAM preload, row-pair fetch into line buffers, buffer-controller priming from set 0, internal HUB75 clock/latch/OE activity, row-address sequencing, and RGB bit selection for one display frame
- Pinout: `clk_50mhz`, buttons, `led_status`, and the full SDRAM bundle (`board_assignments.qsf`); HUB75 outputs are internal checker signals in this first BIST

### `spi_slave_bist_top`

- Source: `spi_slave/spi_slave_bist_top.sv`
- Stack: internal synthetic SPI master → `spi_slave` → byte/data-valid checker
- Default config: `WIDTH = 8`, `SPI_HALF_PERIOD_CYCLES = 8`
- Tests: MSB-first SPI mode 0 byte reception, multiple scripted bytes, one-cycle `data_valid`, and no valid pulse after a partial-byte transfer
- Pinout: `clk_50mhz`, buttons, `led_status` only (`board_no_sdram_assignments.qsf`)

### `command_processor_bist_top`

- Source: `command_processor/command_processor_bist_top.sv`
- Stack: scripted command-byte source → `command_processor` → `memory_arbiter` → `sdram_arbiter_adapter` → `sdram_controller`
- Default geometry: `TOTAL_WIDTH = 1024`, `TOTAL_HEIGHT = 32`, `COLOR_DEPTH = 4`, `ADDR_WIDTH = 24`
- Tests: several `CMD_WRITE_PIXEL` transactions, SDRAM-backed `CMD_READ_PIXEL` readback through `read_data_out`/`read_data_valid`, write request address/data checking, and one `CMD_FLIP_BUFFER` `frame_ready` pulse
- Pinout: `clk_50mhz`, buttons, `led_status`, and the full SDRAM bundle (`board_assignments.qsf`)

### `led_panel_controller_bist_top`

- Source: `led_panel_controller/led_panel_controller_bist_top.sv`
- Stack: internal synthetic SPI master → `spi_slave` → `command_processor` → `memory_arbiter` → `sdram_arbiter_adapter` → `sdram_controller` → `led_panel_driver`
- Default smoke geometry: `NUM_PANEL_ROWS = 1`, `NUM_PANELS_PER_ROW = 16`, `PANEL_WIDTH = 64`, `PANEL_HEIGHT = 32`, `COLOR_DEPTH = 4`
- Tests: SPI-commanded framebuffer writes, `CMD_FLIP_BUFFER` panel enable, SDRAM-backed row-pair fetch/display pipeline, and HUB75 clock/latch/OE/RGB behavior for `CHECK_PANEL_ROW`
- `COMMAND_SETTLE_CYCLES` default 256 (inter-write SDRAM margin between SPI pixel commands)
- SDRAM init gate: 50k cycles (~1 ms) after reset before button can start BIST
- Ethernet is compiled out with `ENABLE_ETHERNET = 0`; no RMII pins or Ethernet module are included in this BIST
- Pinout: `clk_50mhz`, buttons, `led_status`, full SDRAM bundle, and exposed `hub75_*` matrix outputs; physical HUB75 location assignments still need the target connector mapping

## Quartus bring-up checklist

1. Open the `.qpf` in the target folder above
2. Quick smoke: default `LAST_TEST_ADDR = 24'h00_003F` (64 words) on arbiter tops — expect solid LED (pass)
3. Stress: full `24'h00FF_FFFF` sweep on `memory_arbiter_bist_dual_top` (verified)
4. Optional SignalTap: `state`, `curr_addr`, `client_mem_grant`, `client_mem_read_data_valid`, `fail_latched`, adapter `state`
5. Next hardware targets: see [Suggested next BIST targets](#suggested-next-bist-targets) above

Shared adapter module: `sdram_components/sdram_arbiter_adapter.sv` (also used by `led_panel_controller.sv`).