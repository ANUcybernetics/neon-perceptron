---
id: task-13
title: flash Nerves firmware to reTerminal DM eMMC
status: In Progress
assignee: []
created_date: "2026-04-07"
labels: []
dependencies: [task-4]
---

Flash the Nerves firmware to the reTerminal DM's 32GB eMMC storage. The
reTerminal DM has no SD card slot --- it boots exclusively from eMMC, which
requires USB boot mode and `rpiboot` to expose the eMMC as a block device.

## What's done

- firmware builds successfully with `MIX_TARGET=rpi4 MIX_ENV=prod mix firmware`
- upgraded project to OTP 28 / Elixir 1.19.5 (required by kiosk_system_rpi4
  v2.0.1) --- see `mise.toml`
- installed `fwup` on macOS via Homebrew
- fixed `model_25.ex` to guard `EMLX.Backend` struct match with
  `Code.ensure_loaded?/1` (EMLX is host-only, not available on target)
- changed EXLA dep to `targets: :host` since target uses Nx.Eigen
- built with `MIX_ENV=prod` to fit within the rootfs partition size limit
  (dev-only deps like igniter/sourceror were pushing it over 133MB)

## Steps remaining

Do these on a Linux (Ubuntu) box with the reTerminal DM connected via USB-C.

### 1. Install tools on Ubuntu

```bash
sudo apt install git pkg-config make gcc libusb-1.0-0-dev fwup
```

If `fwup` isn't in the repos, install from
https://github.com/fwup-home/fwup/releases.

### 2. Build and run rpiboot

```bash
git clone --depth=1 https://github.com/raspberrypi/usbboot && cd usbboot
make
sudo ./rpiboot
```

### 3. Connect the reTerminal DM

- flip the boot mode switch next to the USB-C port (disables eMMC boot, exposes
  eMMC as USB mass storage)
- connect USB-C cable from reTerminal DM to the Ubuntu box
- `rpiboot` will detect it and the eMMC appears as a block device (e.g.
  `/dev/sda`)
- power the reTerminal DM (12--24V)

### 4. Copy and flash the firmware

```bash
# from the mac, or just build on the linux box
scp _build/rpi4_prod/nerves/images/neon_perceptron.fw ubuntu-server:~/

# on the linux box --- check the correct device with lsblk
sudo fwup neon_perceptron.fw -d /dev/sdX --yes
```

### 5. Boot

- flip the boot switch back to its original position
- power cycle the reTerminal DM
- it should boot into Nerves with the kiosk UI on the display
- SSH in with `ssh nerves@nerves.local` to validate firmware:
  `Nerves.Runtime.validate_firmware()`

## References

- https://wiki.seeedstudio.com/reterminal-dm-flash-OS/
- https://wiki.seeedstudio.com/reterminal-dm-hardware-guide/
