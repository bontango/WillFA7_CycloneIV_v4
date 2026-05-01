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

Current implementation: byte-wise writes (4 SPI_Master instances: READ/WRITE/STAT/CMD) with three reliability layers added on top of the v094 baseline:

- **v095 — Per-byte write verify:** after every WIP=0, the just-written byte is read back via the READ master and compared to a snapshot taken at write time (`verify_byte`). Up to 2 retries per byte; persistent mismatch latches `error_latched` which drives the new `EEprom_error` output as a 1 Hz blink. Cleared at the start of each save.
- **v096 — 256-byte shadow cache:** an in-RAM mirror of the EEPROM content, populated during the boot read and updated only after a successful (re-)verify. Each save trigger first scans 0x00..0xFF, comparing `shadow(addr)` vs `q_ram(addr)`, and only writes the bytes that actually differ. Idle saves emit zero SPI traffic.
- **v097 — Delayed re-verify:** after the first verify passes, the FSM waits ~100 ms in `delay_reverify` and then re-reads the same byte. Only a second matching read commits the shadow update. The 100 ms idle window also functions as a recovery gap between consecutive WRITEs — empirically required for marginal M95512 chips whose internal charge pump or VCC-droop margin causes back-to-back writes to fail post-power-cycle even though WIP=0 fires correctly.

`SPI_Master.vhd` is the pre-Stage-A version (no synchronous reset block) — modifying it has caused regressions in the past. **Do not change SPI_Master.vhd unless explicitly requested.**

CMOS RAM region mirrored: 256 bytes, with `selection` (game-select-derived) as the high address byte. The R5101 dual-port RAM port B output is asynchronous with registered address — any state transition that drives a fresh `address_eeprom` toward `q_ram` must allow ≥1 settle cycle (the `Scan_Settle` state uses 5 cycles for margin).
