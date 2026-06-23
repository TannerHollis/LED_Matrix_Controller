# LED Panel Controller

A scalable, high-performance RGB LED panel controller designed for driving large arrays of HUB75 LED panels. This system uses SDRAM memory for efficient frame buffering and supports both SPI and Ethernet command interfaces.

![LED Panel Controller Architecture](https://img.shields.io/badge/Status-Compilation%20Successful-brightgreen)
![Verilog](https://img.shields.io/badge/Language-Verilog-blue)
![FPGA](https://img.shields.io/badge/Target-FPGA-orange)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Hardware verification](#hardware-verification)
- [Module Documentation](#module-documentation)
- [Features](#features)
- [Getting Started](#getting-started)
- [Command Protocol](#command-protocol)

## Overview

The LED Panel Controller is a sophisticated FPGA-based system designed to drive multiple HUB75 RGB LED panels in parallel. It features:

- **SDRAM Memory Integration**: High-capacity external memory for frame storage
- **Double Buffering**: Tear-free display updates using SDRAM frame regions
- **Scalable Design**: Support for multiple panel rows and daisy-chained panels
- **Dual Interface**: SPI and Ethernet command reception
- **Real-time Streaming**: Panel drivers stream data directly from DDR

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                       LED Panel Controller                        │
├───────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌───────────────────────┐  │
│  │   SPI Slave │    │  Ethernet   │    │   Command Processor   │  │
│  │             │    │  Interface  │    │                       │  │
│  └─────────────┘    └─────────────┘    └───────────────────────┘  │
│         │                   │                    │                │
│         └───────────────────┼────────────────────┘                │
│                             │                                     │
│                    ┌───────────────────────┐                      │
│                    │     Memory Arbiter    │                      │
│                    │                       │                      │
│                    └───────────────────────┘                      │
│                             │                                     │
│                    ┌───────────────────────┐                      │
│                    │   SDRAM Controller    │                      │
│                    │    (Double Buffer)    │                      │
│                    └───────────────────────┘                      │
│                             │                                     │
│         ┌───────────────────┼────────────────────┐                │
│         │                   │                    │                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐            │
│  │Panel Driver │    │Panel Driver │    │Panel Driver │            │
│  │   Row 0     │    │   Row 1     │    │   Row N     │            │
│  └─────────────┘    └─────────────┘    └─────────────┘            │
└───────────────────────────────────────────────────────────────────┘
```

## Hardware verification

Board bring-up status, recommended verification order, and Quartus BIST project details live in [`verification/README.md`](verification/README.md). Simulation testbenches are in [`test_benches/`](test_benches/README.md).

## Module Documentation

### Core Modules

#### [`led_panel_controller.sv`](./led_panel_controller.sv)
**Top-level module** that orchestrates the entire system.

**Key Features:**
- Parameterized design for scalable panel arrays
- SPI and Ethernet interface integration
- Memory arbiter coordination
- Panel driver generation

**Parameters:**
- `NUM_PANEL_ROWS`: Number of parallel panel rows
- `NUM_PANELS_PER_ROW`: Panels daisy-chained per row
- `PANEL_WIDTH/HEIGHT`: Individual panel dimensions
- `COLOR_DEPTH`: Bits per color channel
- `CMD_WIDTH`: SPI command bus width

---

#### [`memory_arbiter.sv`](./memory_arbiter.sv)
**Priority-based memory access controller** for DDR memory management.

**Key Features:**
- Two-level priority system (high/low priority clients)
- Per-transaction `read_length` / `write_length` (1..8); burst-read grants held until all beats complete
- Real-time streaming support for panel drivers
- Command processor integration
- DDR latency handling

**Priority Levels:**
- **High Priority**: Panel drivers (real-time streaming)
- **Low Priority**: Command processor (background updates)

---

#### [`command_processor.sv`](./command_processor.sv)
**Command parsing and memory access coordinator** for external interfaces.

**Key Features:**

---

#### [`sdram_components/sdram_controller.sv`](./sdram_components/sdram_controller.sv)
**Unified SDRAM controller** — PLL, 50 MHz host port, and SDRAM command engine in one file.

**Host interface:** pulse `wr_enable` / `rd_enable` (hold through the transaction); `busy` and `rd_ready` follow the same rules as `sdram_bist_top`.

**With arbiter:** use [`sdram_arbiter_adapter.sv`](./sdram_components/sdram_arbiter_adapter.sv) between `memory_arbiter` and `sdram_controller`.

**Chip parameters** (override at instantiation for different parts):
- `ROW_WIDTH`, `COL_WIDTH`, `BANK_WIDTH` — address geometry
- `CLK_FREQUENCY`, `REFRESH_TIME`, `REFRESH_COUNT`, `INIT_WAIT_US` — timing
- `MODE_REGISTER` — SDRAM mode register loaded at init

**Default profile (W9825G6KH-6, 32 MB):**
- 4 banks × 8192 rows × 512 columns × 16 bits
- CAS latency 3, burst length 8 (`SC_BL(8)`); production reads use 8-beat bursts via `memory_arbiter` + `sdram_arbiter_adapter`; writes are single-beat (`SC_SINGLE_WRITE=1`, mode-register A9=1)

**Example 64 MB profile:** `.ROW_WIDTH(13), .COL_WIDTH(10), .BANK_WIDTH(2)`

---

#### [`sdram_components/sdram_arbiter_adapter.sv`](./sdram_components/sdram_arbiter_adapter.sv)
**Memory arbiter → SDRAM controller** adapter. Burst reads up to `SC_BL` (8); writes single-beat. Client `read_length` selects arbiter beats delivered per SDRAM burst.

---

#### [`sdram_components/pll_100mhz.v`](./sdram_components/pll_100mhz.v)
**PLL module** for 100 MHz SDRAM clock generation from 50 MHz input.

---

#### [`sdram_components/sdram_model.sv`](./sdram_components/sdram_model.sv)
**Behavioral SDRAM model** for simulation testbenches.

---

### Display Modules

#### [`led_panel_driver.sv`](./led_panel_driver.sv)
**Real-time LED panel driver** with DDR streaming capabilities.

**Key Features:**
- Double-buffered line fetching
- BCM (Binary Coded Modulation) for brightness control
- HUB75 interface timing generation
- DDR streaming with memory arbiter

**Display Features:**
- Non-contiguous row-pair data fetching
- Simultaneous display and fetch operations
- Configurable color depth and panel dimensions

---

### Communication Modules

#### [`spi_slave.sv`](./spi_slave.sv)
**SPI slave interface** for high-speed command reception.

**Key Features:**
- Configurable data width
- Synchronous data transfer
- Command validation
- Real-time command processing

---

#### [`ethernet_interface.sv`](./ethernet_interface.sv)
**Ethernet PHY interface** with UDP/TCP protocol support.

**Key Features:**
- RMII interface support
- UDP command reception
- TCP configuration interface
- MAC address filtering
- Network status monitoring

**Protocol Support:**
- **UDP**: Real-time command reception
- **TCP**: Configuration and setup
- **IPv4**: Standard network protocol

---

### Memory Modules

#### [`ddr_memory_model.sv`](./ddr_memory_model.sv)
**DDR memory simulation model** for testing and development.

**Key Features:**
- Configurable memory size
- Read/write operations
- Latency simulation
- Memory access validation

---

### Test Modules

#### Testbenches
- [`memory_arbiter_tb.sv`](./test_benches/memory_arbiter_tb.sv): Memory arbiter testing (including burst-read routing)
- [`command_processor_tb.sv`](./test_benches/command_processor_tb.sv): Command processing validation
- [`led_panel_driver_tb.sv`](./test_benches/led_panel_driver_tb.sv): Panel driver simulation
- [`frame_buffer_tb.sv`](./test_benches/frame_buffer_tb.sv): Frame buffer testing

---

## Features

### Core Capabilities
- **Scalable Design**: Support for multiple panel rows and daisy-chained panels
- **DDR Integration**: High-capacity external memory for frame storage
- **Double Buffering**: Tear-free display updates using DDR frame regions
- **Real-time Streaming**: Panel drivers stream data directly from DDR
- **Dual Interface**: SPI and Ethernet command reception
- **Priority Arbitration**: Memory access prioritization for real-time display

### Technical Specifications
- **Memory Interface**: DDR3/DDR4 compatible
- **Panel Interface**: HUB75 standard
- **Communication**: SPI (high-speed) + Ethernet (network)
- **Color Depth**: Configurable (typically 4-8 bits per channel)
- **Panel Support**: Configurable dimensions and array sizes

### Display Features
- **BCM Brightness Control**: Binary Coded Modulation for smooth brightness
- **Non-contiguous Fetching**: Efficient memory access patterns
- **Simultaneous Operations**: Display and fetch in parallel
- **Configurable Timing**: HUB75 interface timing generation

## Coding style

Hand-written RTL and testbenches follow the [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md). Project-specific rules, migration status, and exceptions are documented in [`VERILOG_STYLE.md`](VERILOG_STYLE.md).

## Getting Started

### Prerequisites
- Quartus Prime (or compatible FPGA synthesis tool)
- Verilog simulation environment
- DDR memory controller IP core

### Compilation
```bash
# Add all .v files to your Quartus project
# Set led_panel_controller as top-level entity
# Configure DDR memory controller
# Run synthesis and compilation
```

### Configuration
1. **Set Panel Parameters**: Configure `NUM_PANEL_ROWS`, `PANEL_WIDTH`, etc.
2. **Configure DDR**: Set up DDR memory controller and timing
3. **Set Network Parameters**: Configure MAC address, IP address, ports
4. **Configure SPI**: Set up SPI clock and data width

## Command Protocol

### SPI Commands
```
Command Format: [CMD] [ADDR_BYTES] [DATA_BYTES]

CMD_WRITE_PIXEL (0x01):
├── Command: 0x01
├── Address: [ADDR_WIDTH bytes] (little-endian)
└── Data: [COLOR_DEPTH*3 bytes] (little-endian)

CMD_FLIP_BUFFER (0x02):
└── Command: 0x02

CMD_READ_PIXEL (0x03):
├── Command: 0x03
└── Address: [ADDR_WIDTH bytes] (little-endian)
```

### Ethernet Commands
```
UDP Packet Format:
├── Ethernet Header (14 bytes)
├── IP Header (20 bytes)
├── UDP Header (8 bytes)
└── Command Data (variable)
```

## Module Dependencies

```
led_panel_controller.sv
├── spi_slave.sv
├── ethernet_interface.sv
├── command_processor.sv
├── memory_arbiter.sv
└── led_panel_driver.sv

memory_arbiter.sv
└── (standalone)

command_processor.sv
└── (standalone)

led_panel_driver.sv
└── (standalone)
```

## Performance Characteristics

- **Memory Bandwidth**: Optimized for DDR streaming
- **Display Refresh**: Real-time with double buffering
- **Command Latency**: Low-latency SPI interface
- **Network Throughput**: Ethernet for bulk operations
- **Scalability**: Linear scaling with panel count

## Contributing

This project is designed for FPGA implementation. When contributing:

1. Maintain Verilog compatibility (no SystemVerilog features)
2. Follow the existing module structure
3. Update testbenches for new features
4. Ensure DDR memory compatibility
5. Test with multiple panel configurations

## License

This project is designed for educational and development purposes. Please ensure compliance with your target FPGA's licensing requirements.

---

**Status**: SDRAM burst-read path verified on DE2-115; next: `command_processor_bist_top` and `led_panel_controller_bist_top`  
**Last Updated**: May 2026  
**Version**: 1.0.0