# v580.178.04-1 — PCIe Gen2 x4 for the NVIDIA P104-100

Unlocks PCIe Gen2 (5.0 GT/s) x4 on a P104-100 (`10de:1b87`) by patching the
NVIDIA kernel module at DKMS build time. The driver itself is not included:
the package installs a build-time patch, a DKMS override and an
`nvidia-persistenced` drop-in, and leaves `/usr/src/nvidia-srv-*` untouched.

**This release is locked to driver 580.178.04.** The patch is a diff against
that source tree and the DKMS override is named `nvidia-srv-580.178.04.conf`.
On any other driver version the override does not match, so the module would
build unpatched; the maintainer script verifies the built module and aborts
rather than loading it. Do not install it on a newer driver; rebuild the
package instead.

## Requirements

| | |
|---|---|
| OS | Ubuntu 26.04 LTS (Debian-family packaging) |
| Driver | `nvidia-dkms-580-server` exactly `580.178.04-0ubuntu0.26.04.1` |
| Kernel | any kernel that driver supports, with `linux-headers-$(uname -r)` |
| GPU | P104-100, PCI ID `10de:1b87`; slot/root port must support 5 GT/s |
| Build | `dkms`, `build-essential`, kernel headers, `zstd`, `pciutils` |
| Secure Boot | disabled, or a MOK enrolled for DKMS-signed modules |
| GPU at install | idle (nothing holding `/dev/nvidia*`), otherwise one reboot |

## Install

Pin the driver first. `apt-get` with explicit versions is deliberate: a newer
driver would silently disable the patch. Skip the pin if `dpkg-query` already
reports `580.178.04-0ubuntu0.26.04.1`; if a newer driver is installed, rebuild
the package rather than downgrading the driver.

```bash
apt-cache policy nvidia-dkms-580-server    # must list 580.178.04-0ubuntu0.26.04.1
sudo apt-get install \
    nvidia-driver-580-server=580.178.04-0ubuntu0.26.04.1 \
    nvidia-dkms-580-server=580.178.04-0ubuntu0.26.04.1
sudo apt-mark hold nvidia-driver-580-server nvidia-dkms-580-server
sudo reboot
```

If the archive no longer offers 580.178.04, rebuild this package for the
version that is available — see *REBUILDING FOR A NEW DRIVER VERSION* in
`deb/readme.txt`. Do not force an old driver just to match the package.

Then install the package from this release:

```bash
sudo apt install ./nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

`apt install ./file.deb` resolves dependencies; `dpkg -i` does not. The script
builds the patched module for the running kernel, aborts if the built module
does not contain the patch, regenerates the initramfs, and reloads the driver
only when no process holds `/dev/nvidia*`.

## Verify

```bash
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
#   LnkSta: ... Speed 5GT/s, Width x4

nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv,noheader
#   Enabled, 2

ps -eo comm | grep nv-p104-gen2-wd    # watchdog thread present
sudo dmesg | grep 'P104-100:'         # "PCIe Gen2 unlock applied, LNKSTA=0x1042"
```

If `LnkSta` still says 2.5 GT/s, the module was built but not loaded: stop
whatever holds `/dev/nvidia*` and reboot, then check again.

## What to expect

- **Idle:** the link stays at 5.0 GT/s indefinitely.
- **Under a CUDA load:** the closed Resource Manager re-asserts Gen1 whenever
  the link goes quiet. The 250 ms watchdog restores Gen2 within ~0.2 s; with a
  chat-style workload that measured 79 % of wall time (76 % of busy time) at
  Gen2.
- **Bandwidth:** measured 1.52 GB/s host→device and 1.61 GB/s device→host.
  LLM inference moves only tens of MiB/s over PCIe, so `nvidia-smi`/`nvtop`
  will not show those numbers while serving requests — model load or an
  explicit large copy will.

## Remove

```bash
sudo dpkg -r nvidia-srv-p104-gen2
```

This rebuilds and reinstalls the stock module and removes the DKMS override,
the patch and the systemd drop-in. Release the driver hold when you are done
with the patch:

```bash
sudo apt-mark unhold nvidia-driver-580-server nvidia-dkms-580-server
```

## Checksums

The `.deb` is not bit-reproducible (archive and tar timestamps), so verify the
exact uploaded file rather than trusting a hash from another build:

```bash
sha256sum -c SHA256SUMS
```

Release assets are the `.deb` and `SHA256SUMS`. The generated source archives
do not contain a package: the `.deb` is a build output and is git-ignored.

## License

MIT for this project's code and documentation. The patch quotes lines from the
NVIDIA open GPU kernel-module sources, which are themselves MIT; the NVIDIA
driver is not redistributed here. See `LICENSE` and `NOTICE` in the source
archive.
