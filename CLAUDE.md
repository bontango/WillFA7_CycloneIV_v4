# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WillFA7 is a VHDL-based FPGA implementation that emulates Williams System 7 pinball machine MPU hardware on an Altera Cyclone IV EP4CE6E22C8 FPGA. Author: Ralf Thelen (bontango), website: www.lisy.dev. Current version: 3.17.

## Build System

This project uses **Quartus Prime 22.1** (GUI-driven, no Makefile or build scripts).

- **Project file:** `WillFA7.qpf`
- **Settings/pins:** `WillFA7.qsf`
- **Timing constraints:** `WillFA7.sdc`
- **Output:** `output_files/WillFA7.sof` (SRAM bitstream), `output_files/WillFA7.pof` (flash)
- **Clean build:** Delete `db/` and `incremental_db/` directories, then recompile in Quartus

Command-line compilation (if Quartus is in PATH):
```bash
quartus_sh --flow compile WillFA7
```

## Architecture

**Top-level entity:** `WillFA7` in `WillFA7.vhd`

### Key Components

| Module | File | Purpose |
|--------|------|---------|
| cpu68 | `cpu68.vhd` | Motorola 6800/6801 CPU core (OpenCores, modified) |
| pia6821 | `pia6821.vhd` | Peripheral Interface Adapter (x5 instances) |
| SD_Card | `SD_Card.vhd` | SPI SD card controller for ROM loading |
| EEprom | `EEprom.vhd` | SPI EEPROM interface (M95256 / M95512, game state persistence) |
| williams_pll | `williams_pll.vhd` | PLL: 50 MHz → 14.28 MHz (Altera IP) |
| ram | `ram.vhd` | System RAM (Altera 1-port syncram IP) |
| rom_2K | `rom_2K.vhd` | ROM blocks x6 (Altera IP, loaded from SD) |
| R5101 / cmos | `R5101.vhd` / `cmos.vhd` | CMOS RAM (dual-port, game settings) |
| boot_message | `boot_message.vhd` | Boot/diagnostic display |
| read_the_dips | `read_the_dips.vhd` | DIP switch reader for game selection |
| flipflops | `flipflops.vhd` | Flipper solenoid control |
| spec_sol_trigger | `spec_sol_trigger.vhd` | Special solenoid trigger with debouncing |

### Clock Domains

- **50 MHz** — External oscillator input (PIN_23)
- **14.28 MHz** — PLL output (williams_pll: ×123 ÷430)
- **~894 KHz** — CPU clock (cpu_clk_gen from 14.28 MHz)
- **900 Hz** — IRQ generator
- Cross-domain synchronization via `Cross_Slow_To_Fast_Clock` modules

### Memory Map (Williams SYS7)

```
$0000-$00FF  System RAM
$0100-$01FF  CMOS RAM (protected)
$1000-$13FF  SYS7 Extended RAM
$2100-$2103  PIA5 (Sound/Comma)
$2200-$2203  PIA4 (Solenoids)
$2400-$2403  PIA3 (Lamps)
$2800-$2803  PIA1 (Display/Diag)
$3000-$3003  PIA2 (Switch Matrix)
$5000-$7FFF  Game ROMs (6×2K from SD card)
```

### Boot Sequence

4-phase: Phase 0 (reset/boot message) → Phase 1 (DIP/game select) → Phase 2 (SD card ROM + EEPROM load) → Phase 3 (game execution).

## Third-Party Cores

- **cpu68** and **pia6821**: From OpenCores.org (John E. Kent), GNU GPL. Modified by bontango for bug fixes (DAA instruction, carry bit, IRQ handling).
- **Altera IP**: ALTPLL, altsyncram (RAM/ROM). Regenerate via Quartus MegaWizard if needed.

## Hardware Target

EP4CE6E22C8 (Cyclone IV E, 6272 LEs). Pin assignments in `WillFA7.qsf`. Physical board interfaces: SPI bus (SD card + EEPROM, active-low chip selects), 8×8 switch matrix, solenoid drivers, 7-segment display multiplexing, DIP switches for game selection, diagnostic/control inputs.

## Conventions

- All source files are VHDL (`.vhd`)
- Signal naming follows Williams hardware conventions (e.g., `sw_strobe`, `sw_return`, `sol_1_8_sel`)
- Active-low signals: reset (`reset_sw`), chip selects (`CS_SDcard`, `CS_EEprom`)
- Version history maintained in `Archive/` directory

## EEPROM Save Path (`lib_common/EEprom.vhd`)

Clean-room rewrite (post-v097) preserving v097 behavior bit-for-bit while restructuring the code:

- **Two parallel processes:** `TOP` (phase FSM) and `SPI_SUB` (shared 3-state SPI handshake `SPI_IDLE → SPI_RUNNING → SPI_RELEASE`). Top FSM picks an op via `spi_op` enum and pulses `spi_start`; sub-FSM drives the matching `TX_Start_*` and pulses `spi_done_p` once the bus is released. Eliminates the duplicated `wait_for_Master_I/II/III/V` boilerplate.
- **18 named phases** (`PH_BOOT_CHECK` … `PH_NEXT_BYTE`) instead of 26 ad-hoc states. Each save step (WREN → WRITE → POLL → VERIFY → REVERIFY) maps to exactly one phase.
- **All timings are generics** with v097 defaults: `INIT_DELAY_CYCLES` (2 s), `PRE_WRITE_CYCLES` (1 s), `GLITCH_CYCLES` (1 µs), `REVERIFY_CYCLES` (100 ms), `HOLD_CYCLES` (20 µs), `SCAN_SETTLE_CYCLES` (5), `MAX_RETRY` (2), `SPI_HZ` (100 kHz), `BLINK_DIV_CYCLES` (1 Hz blink).
- **Opcodes as named constants:** `CMD_READ` x"03", `CMD_WRITE` x"02", `CMD_WREN` x"06", `CMD_RDSR` x"05", `SR_WIP_BIT` 0.
- **Same 4 SPI_Master instances** (32/32/16/8 bit `Laenge`, 100 kHz) with combinatorial `o_SPI_*` mux on `TX_Start_*` — ensures the M95256/M95512 sees identical frames as v097.

Reliability layers (preserved from v095/v096/v097):

- **Per-byte write verify:** after WIP=0, READ back the just-written byte and compare to `verify_byte`. Up to `MAX_RETRY` (=2) retries per byte; persistent mismatch latches `error_latched`.
- **256-byte shadow cache:** populated during boot read, updated only after a successful (re-)verify. `PH_SCAN_COMPARE` writes only bytes where `shadow(addr) /= q_ram(addr)`. Idle saves emit zero SPI traffic.
- **Delayed re-verify:** after first verify passes, wait `REVERIFY_CYCLES` (100 ms) and re-read. Only a second match commits the shadow update. The 100 ms also functions as a recovery gap between consecutive WRITEs — empirically required for marginal M95512 chips.

LED feedback (`EEprom_error` → `LED_active` via top-level mux on `o_wr_in_progress`):

- **Boot-Read + INIT_DELAY:** `o_wr_in_progress='0'`, `save_active='0'` → LED dark ("EEPROM busy at boot").
- **IDLE:** `o_wr_in_progress='1'` → LED follows display blanking (normal).
- **During save (any of 11 save phases):** `o_wr_in_progress='0'`, `save_active='1'` → LED blinks 1 Hz ("save in progress, do not power off"). When blink stops, save is complete.
- **Verify failure:** `error_latched='1'` keeps the blink alive while still in save phase (visible only during the failed save itself).

CMOS region mirrored: 256 bytes. `selection` (game-select-derived) is the SPI high address byte; `address_eeprom` is the low byte. R5101 dual-port RAM port B output is asynchronous with registered address — `PH_SCAN_SETTLE` waits 5 cycles for margin.

`SPI_Master.vhd` is the pre-Stage-A version (no synchronous reset block) — modifying it has caused regressions in the past. **Do not change SPI_Master.vhd unless explicitly requested.**
