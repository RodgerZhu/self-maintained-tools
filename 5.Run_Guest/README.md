# TDX VM Launcher Usage Guide

This repository includes a launcher script that starts a VM with QEMU, with optional TDX mode and configurable boot log behavior.

## File Overview

- `run_ubu_td.sh`: Main launcher script
- `td-ubunt-1.qcow2`: VM disk image

## Prerequisites

Before running the script, verify the following paths inside `run_ubu_td.sh` are correct for your system:

- `QEMU_BINARY`
- `OVMF_BIOS`
- `DISK_IMAGE`

The script will stop with an error if required files are missing.

## Basic Usage

Run with default settings:

```bash
./run_ubu_td.sh
```

## Configuration Parameters

The script supports these key parameters (set in script and/or via environment variables):

- `TDX_MODE`
  - `1`: Start as TDX VM
  - `0`: Start as regular VM
- `MEMORY_SIZE`
  - Examples: `4G`, `512M`
- `CPU_CORES`
  - Positive integer, such as `1`, `2`, `4`
- `SHOW_BOOT_LOG` (environment variable supported)
  - `1`: Show live VM boot console logs in terminal
  - `0`: Disable console logs and run QEMU in background (`-daemonize`)

## Boot Log Modes

### 1) Live Console Mode (foreground)

Use this mode when you want to watch BIOS/kernel/system boot messages.

```bash
SHOW_BOOT_LOG=1 ./run_ubu_td.sh
```

Behavior:

- Script stays attached to terminal
- Console output is visible live
- Logs are also written to `td-guest.log`

### 2) Silent Background Mode

Use this mode when you want the shell prompt back immediately and then connect via SSH.

```bash
SHOW_BOOT_LOG=0 ./run_ubu_td.sh
```

Behavior:

- QEMU starts in background
- Terminal returns immediately after launch
- No live serial/monitor output in current terminal

## SSH Access

The script configures user-mode networking with:

- Host forward: `tcp::10022-:22`

After VM starts, connect from host:

```bash
ssh -p 10022 <vm_user>@127.0.0.1
```

Example:

```bash
ssh -p 10022 ubuntu@127.0.0.1
```

## Common Examples

Start regular VM in background:

```bash
TDX_MODE=0 SHOW_BOOT_LOG=0 ./run_ubu_td.sh
```

Start TDX VM with live boot logs:

```bash
TDX_MODE=1 SHOW_BOOT_LOG=1 ./run_ubu_td.sh
```

## Stop the VM

A pid file is written to:

- `/tmp/tdx-demo-td-pid.pid`

Stop VM safely:

```bash
kill "$(cat /tmp/tdx-demo-td-pid.pid)"
```

## Troubleshooting

- If launch fails with missing file errors, re-check `QEMU_BINARY`, `OVMF_BIOS`, and `DISK_IMAGE` paths.
- If SSH is not reachable, wait a bit longer for guest boot and verify guest SSH service is enabled.
- If port `10022` is already in use, update the `hostfwd` setting in the script.
