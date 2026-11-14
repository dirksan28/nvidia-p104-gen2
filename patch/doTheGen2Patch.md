# doTheGen2Patch.md — permanently unlock PCIe Gen2 x4 on NVIDIA P104-100 (10de:1b87)

Reproduction guide for the patch that is currently installed on this host.
Everything below has been executed and verified on this machine; the "why" notes
record the traps that cost time, so they do not have to be rediscovered.

---

## 0. Target environment (as verified)

| Item | Value |
|---|---|
| OS | Ubuntu 26.04 LTS |
| Kernel | `7.0.0-43-generic` |
| Driver package / DKMS name | DKMS module **`nvidia-srv`** 580.178.04; the kernel module is `nvidia.ko` |
| Owning dpkg package | `nvidia-dkms-580-server` 580.178.04-0ubuntu0.26.04.1 |
| Source tree | `/usr/src/nvidia-srv-580.178.04/` |
| DKMS | 3.2.2, `source` symlink → `/usr/src/nvidia-srv-580.178.04` |
| GPU | `01:00.0` `10de:1b87` GP104 P104-100, BAR0 `0xf6000000` (16 MB) |
| Root port | `00:01.0` (`LnkCap 8 GT/s x16`) |
| Baseline link | `2.5 GT/s x4` (both GPU and root port) |
| Secure Boot | disabled / Setup Mode (unsigned rebuilds load) |
| Other GPU | Intel iGPU at `00:02.0`, NVIDIA is headless |
| Privileges | passwordless `sudo` was available (`sudo -n`) |

Adapt kernel version, DKMS package/version, and BDF if they differ.

### Result

```
01:00.0  LnkCap: Speed 5GT/s, Width x4
01:00.0  LnkSta: Speed 5GT/s, Width x4
nvidia-smi: persistence_mode=Enabled, pcie.link.gen.current=2, width=4
```

Idle stability: the link holds 5 GT/s indefinitely when the GPU is idle (the
RM only re-asserts Gen1 while the GPU is in P0 and the link is quiet). Under a
chat workload each re-assertion is undone within ~0.2 s by the watchdog, and
the link is at Gen2 for ~80 % of the busy time (see §11).

> **Preferred install path:** the change is shipped as a Debian package,
> `nvidia-srv-p104-gen2`, which applies the patch through DKMS at build time
> and can be removed cleanly. See [§12](#12-debian-package-preferred-path).
> Sections 3–9 remain the manual procedure and are what the package automates.

---

## 1. Why this is more than "write two hooks"

The BAR0 register offsets are valid and do flip `LnkCap` to 5 GT/s. But three
closed-source Resource Manager behaviours break a one-shot unlock:

1. **Adapter teardown per client.** Ubuntu's `nvidia-persistenced.service` runs
   `--no-persistence-mode`. Nothing holds `/dev/nvidia0`, so every `nvidia-smi`
   runs `rm_init_adapter` again and resets the link. Verified with `fuser` (no
   holders) and by counting `nv_start_device` calls in `dmesg`.
2. **Per-burst downgrade.** Even with persistence mode on, the RM rewrites
   `LINK_CONFIG_0 (0x8C040)` back to `SPEED=2` as soon as the *link* goes quiet
   while the GPU is in P0 — measured at ~0.25 s into each burst of work, or
   ~0.55 s after the previous one ends. Under a chat workload (~1 request every
   2.5 s) that is 2–3 re-assertions per request; the link is at Gen1 for
   ~30 % of the busy time if the correction takes a second.
   All of these were tested with a controlled local load and **did not**
   prevent it: `RMPcieLinkSpeed=2`, `RMPcieGenSwitchOnPmu=0`,
   `RMPcieStickyGenSpeed=1`, `RmForceEnablePcieGenSwitching=0`,
   `NVreg_EnablePCIeGen3=1`, `NVreg_DynamicPowerManagement=0`. The keys are
   parsed (they appear in `/proc/driver/nvidia/params`) but on GP104 they do
   not change the behaviour. Hence the watchdog thread: there is no way to ask
   this RM to stop downgrading, only to undo it quickly.
3. **Retrain timing.** The first retrain of a round never lands — it only
   latches the new `LINK_CONFIG_0` value; the *second* retrain then trains at
   5.0 GT/s in ~10 ms. Waiting longer after the first one (250 ms, 600 ms) does
   not help, it only stretches the Gen1 window. The helper therefore polls in
   10 ms steps with a 60 ms budget per attempt, up to 6 attempts, rewriting the
   BAR0 state before each one (the RM can revert it in between).

Therefore the shipped patch has **three** entry points: probe, post-RM-init, and
a periodic watchdog.

---

## 2. Preflight

```bash
uname -r
dkms status                                   # expect: nvidia-srv/<ver>, <krel>: installed
lspci -nn -d 10de:1b87
cat /sys/bus/pci/devices/0000:01:00.0/{current_link_speed,max_link_speed,current_link_width}
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
sudo lspci -s 00:01.0 -vv | grep -E 'LnkCap:|LnkSta:'
mokutil --sb-state
pgrep -a 'Xorg|Xwayland|gnome-shell'          # expect nothing (headless)
lsmod | grep '^nvidia'
```

Identify the anchors (line numbers move between driver branches):

```bash
cd /usr/src/nvidia-srv-580.178.04
grep -n 'nv_check_and_exclude_gpu\|rm_enable_dynamic_power_management\|rm_notify_gpu_addition' nvidia/nv-pci.c
grep -n 'rm_init_adapter' nvidia/nv.c
grep -n 'nv_pci_unregister_driver' nvidia/nv-pci.c
```

You need:

* `nv_check_and_exclude_gpu(sp, nv);` in `nv_pci_probe` — the unlock must be
  inserted **before** `rm_enable_dynamic_power_management()`; the source states
  that no hardware register access is allowed after DPM is enabled, and that
  nothing may be added after `rm_notify_gpu_addition()`.
* the `rm_init_adapter(sp, nv)` success block inside `nv_start_device()` —
  **not** in `nv_open_device()` (in 580, `nv_open_device` calls
  `nv_start_device`, which calls `rm_init_adapter`).
* `nv_pci_unregister_driver()` — to stop the watchdog on module unload.

Check required kernel macros exist:

```bash
grep -E 'PCI_EXP_LNKSTA_CLS_5_0GB|PCI_EXP_LNKCTL2_TLS(_5_0GT)?\b' \
  /usr/src/linux-headers-$(uname -r)/include/uapi/linux/pci_regs.h
```

---

## 3. Userspace pre-test (do this first — hard gate)

Purpose: prove the BAR0 offsets work **before** touching the kernel. If the
offsets are wrong for your card/driver, a bad write can wedge the PCIe link and
need a cold reboot; this step makes that failure cheap and reversible.

The tools used below ship with this document in `patch/tools/`
(`mmio_test.c`, `linktest.sh`, `dump.sh`, `rollback.sh`, and `bwtest.cu` for the
bandwidth check at the end of §3); the source of the first
two is also reproduced in the appendices. Build them in a scratch directory —
`/tmp/p104-gen2/` is used for that here and is disposable. Commands below assume
the repository root as the current directory; record it once:

```bash
R=$PWD        # repository root
```

### 3.1 Build the MMIO tool

```bash
cd patch/tools
mkdir -p /tmp/p104-gen2
gcc -O2 -Wall -Wextra -o /tmp/p104-gen2/mmio_test mmio_test.c
cd /tmp/p104-gen2
```

It maps `/sys/bus/pci/devices/0000:01:00.0/resource0` directly (no `/dev/mem`,
so `CONFIG_STRICT_DEVMEM` does not matter) and requires root.

### 3.2 Read-only dump

```bash
sudo ./mmio_test dump
```

Expected on this card (values matter only as a sanity check):

```
0x2241C = 0x00000000   0x8841C = 0xC0B46500   0x88610 = 0x00000000
0x8872C = 0x00000000   0x8C040 = 0x20085800   0x8C1C0 = 0x00010036
0x8C2C0 = 0x068711B3   0x8C300 = 0x040A00C0
```

If every register reads `0xFFFFFFFF`, BAR0 is not decoding (GPU powered down or
wrong BDF): stop.

### 3.3 Control test (config space only)

Use `patch/tools/linktest.sh` (also [Appendix B](#appendix-b--linktestsh)):

```bash
cp "$R"/patch/tools/linktest.sh .     # still in /tmp/p104-gen2 from §3.1
sudo ./linktest.sh apply      # sets LNKCTL2.TLS=5.0GT/s on GPU+root port, retrains
sudo ./linktest.sh status
sudo ./linktest.sh restore    # put TLS back to auto afterwards
```

Expected: the link **stays at 2.5 GT/s**. The GPU's config-space write to
`LNKCTL2` may not even stick. This confirms the cap comes from GPU state, not
config space.

### 3.4 Apply the BAR0 writes

```bash
sudo ./mmio_test apply
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
```

Expected immediately after: **`LnkCap: Speed 5GT/s`** and
`LnkSta: Speed 2.5GT/s (downgraded)`.

Then retrain (repeat the loop; the first attempt usually fails):

```bash
for i in 1 2 3 4 5; do
  sudo ./mmio_test apply >/dev/null
  sudo setpci -s 00:01.0 CAP_EXP+10.w=$(printf '%04x' $(( 0x$(sudo setpci -s 00:01.0 CAP_EXP+10.w) | 0x20 )))
  sleep 0.4
  s=$(sudo setpci -s 01:00.0 CAP_EXP+12.w)
  echo "try $i: $s"
  [ "$((0x$s & 0xf))" = "2" ] && break
done
```

Expected: `LnkSta: Speed 5GT/s, Width x4` on both `01:00.0` and `00:01.0`.

**Gate:** if this does not reach 5 GT/s, stop. Do not patch the kernel.

---

## 4. Backups

```bash
cd /usr/src/nvidia-srv-580.178.04
sudo mkdir -p /root/p104-backup
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
  sudo cp -a "$f" "$f.bak"
  sudo cp -a "$f" "/root/p104-backup/$(basename "$f")"
done
cmp nvidia/nv-pci.c nvidia/nv-pci.c.bak && cmp nvidia/nv.c nvidia/nv.c.bak && \
  cmp common/inc/nv-pci.h common/inc/nv-pci.h.bak && echo BACKUPS_OK
```

The source files are root-owned; the editor tool cannot write them. Stage edits
in `/tmp` and install with `sudo install`:

```bash
mkdir -p /tmp/p104-gen2/work && cd /tmp/p104-gen2/work
cp -a /usr/src/nvidia-srv-580.178.04/nvidia/nv-pci.c .
cp -a /usr/src/nvidia-srv-580.178.04/nvidia/nv.c .
cp -a /usr/src/nvidia-srv-580.178.04/common/inc/nv-pci.h .
```

---

## 5. Patch the kernel module

Edit the three staged copies, then install:

```bash
sudo install -o root -g root -m 644 nv-pci.c  /usr/src/nvidia-srv-580.178.04/nvidia/nv-pci.c
sudo install -o root -g root -m 644 nv.c      /usr/src/nvidia-srv-580.178.04/nvidia/nv.c
sudo install -o root -g root -m 644 nv-pci.h  /usr/src/nvidia-srv-580.178.04/common/inc/nv-pci.h
```

### 5.1 `nvidia/nv-pci.c`

**(a) Includes** — after `#include <linux/iommu.h>`:

```c
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/kthread.h>
```

**(b) Helpers + main function** — insert immediately before
`/* find nvidia devices and set initial state */` (i.e. before `nv_pci_probe`):
full text in [Appendix C](#appendix-c--nv_pci_helpers). It contains
`nv_p104_write_bar0()`, the watchdog, and `nv_force_p104_gen2()`.

**(c) Probe hook** — after `nv_check_and_exclude_gpu(sp, nv);`:

```c
    /* P104-100: unlock PCIe Gen2 while BAR0 is still accessible */
    if (nvl->pci_dev->device == 0x1b87) {
        nv_force_p104_gen2(nvl->pci_dev);
        nv_p104_gen2_start_watchdog();
    }
```

**(d) Stop the watchdog** — in `nv_pci_unregister_driver()`, after the
`NVreg_RegisterPCIDriver == 0` early return, before `pci_unregister_driver()`:

```c
    nv_p104_gen2_stop_watchdog();
    return pci_unregister_driver(&nv_pci_driver);
```

### 5.2 `nvidia/nv.c`

**(a) Prototype** — after `#include "detect-self-hosted.h"`:

```c
/* Implemented in nv-pci.c: P104-100 PCIe Gen2 unlock */
void nv_force_p104_gen2(struct pci_dev *dev);
```

**(b) Post-init hook** — in `nv_start_device()`, immediately after the
`if (!rm_init_adapter(sp, nv)) { ... goto failed_release_irq; }` block:

```c
    /*
     * P104-100: rm_init_adapter() has just re-initialized the link state;
     * re-apply the Gen2 unlock so the adapter comes up at 5.0 GT/s.
     */
    if (nvl != NULL && nvl->pci_dev != NULL)
        nv_force_p104_gen2(nvl->pci_dev);
```

### 5.3 `common/inc/nv-pci.h`

Before `#endif`:

```c
/* Implemented in nv-pci.c: P104-100 PCIe Gen2 unlock */
void nv_force_p104_gen2(struct pci_dev *dev);
```

> Note: there is **no** `nvidia/nv-pci.h`; the header is
> `common/inc/nv-pci.h`. `nv.c` does not include it, hence the local prototype
> there (also keeps `-Wmissing-prototypes` quiet).

### 5.4 Review

```bash
cd /usr/src/nvidia-srv-580.178.04
{ diff -u nvidia/nv-pci.c.bak nvidia/nv-pci.c
  diff -u nvidia/nv.c.bak nvidia/nv.c
  diff -u common/inc/nv-pci.h.bak common/inc/nv-pci.h; } > /tmp/p104-gen2/final.patch
```

Expected shape: 3 include lines, 219 added lines in `nv-pci.c`, 6-line probe
hook, 1-line unregister hook, 10 lines in `nv.c`, 4 lines in `nv-pci.h`. The
validated `a/`–`b/` form of the same change is `p104-gen2.patch` in this
directory (286 lines, +219/+10/+4).

---

## 6. Build and install

```bash
KREL=$(uname -r)
sudo dkms build   -m nvidia-srv -v 580.178.04 -k "$KREL" --force 2>&1 | tee /tmp/p104-gen2/dkms-build.log
grep -iE 'warning:|error:' /tmp/p104-gen2/dkms-build.log    # must be empty
sudo dkms install -m nvidia-srv -v 580.178.04 -k "$KREL" --force
sudo update-initramfs -u -k "$KREL"
```

Verify the compiled module really contains the patch (DKMS 3.2.2 builds in a
temporary directory that is removed afterwards, so checking the build tree does
not work):

```bash
zstd -dc /lib/modules/$KREL/updates/dkms/nvidia.ko.zst | strings | grep 'P104-100'
# expect: "P104-100: failed to ioremap BAR0 ..." and "P104-100: PCIe Gen2 unlock applied ..."
```

If the build fails, read the log at
`/var/lib/dkms/nvidia-srv/580.178.04/$KREL/x86_64/log/make.log` (or the `tee`d
copy above), fix, or run the rollback in §9.

---

## 7. Keep the adapter initialized (systemd drop-in)

Ubuntu's stock unit runs `--no-persistence-mode`, which is what caused the
per-client re-init. Override it:

```bash
sudo mkdir -p /etc/systemd/system/nvidia-persistenced.service.d
sudo tee /etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf >/dev/null <<'EOF'
# P104-100 PCIe Gen2 unlock: the stock unit runs --no-persistence-mode, so the
# adapter is torn down after every client and the RM resets the PCIe link to
# 2.5 GT/s on each re-init. Keep persistence mode enabled so the adapter stays
# initialized and holds the retrained 5.0 GT/s link.
[Unit]
StopWhenUnneeded=no

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --persistence-mode --verbose
EOF
sudo systemctl daemon-reload
sudo systemctl restart nvidia-persistenced
```

`systemctl enable` is a no-op here: the unit is `static` and starts via
`WantedBy=sys-bus-pci-drivers-nvidia.device`.

Quick manual alternative for testing without the drop-in: `sudo nvidia-smi -pm 1`.

---

## 8. Reload and verify

```bash
sudo systemctl stop nvidia-persistenced; sleep 1
sudo fuser -v /dev/nvidia*                      # must be empty
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
sudo systemctl start nvidia-persistenced; sleep 5
```

Acceptance:

```bash
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'   # 5GT/s x4 both
sudo lspci -s 00:01.0 -vv | grep -E 'LnkCap:|LnkSta:'
nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader
sudo dmesg | grep 'P104-100'
ps -eo comm | grep nv-p104-gen2-wd
```

Stability sampling (expect ≥ 95 % at 5 GT/s):

```bash
ok=0; tot=0
for i in $(seq 1 100); do
  s=$(sudo setpci -s 01:00.0 CAP_EXP+12.w); sp=$((0x$s & 0xf))
  tot=$((tot+1)); [ "$sp" = "2" ] && ok=$((ok+1))
  [ $((i % 25)) -eq 0 ] && nvidia-smi >/dev/null 2>&1
  sleep 0.5
done
echo "5GT/s: $ok/$tot"
```

Reference result: `98/100` — this is the *idle* check, run right after install.
It is not a load test: with a CUDA client active the RM re-asserts Gen1 every
time the link goes quiet, so expect ~20 % of samples at 2.5 GT/s while a chat
workload runs and ~0 % at idle (§11).

Bandwidth check (optional, needs `nvcc`; independent of the driver):

```bash
nvcc -O2 -arch=sm_61 -o /tmp/p104-gen2/bwtest patch/tools/bwtest.cu
/tmp/p104-gen2/bwtest 256 8
```

Reference result: `H2D 1453 MiB/s (1.52 GB/s)`, `D2H 1537 MiB/s (1.61 GB/s)`,
i.e. ~90 % of the Gen2 x4 payload ceiling; the stock Gen1 link gives about
half. Sample `current_link_speed` while it runs — the link must stay at
5.0 GT/s, since a busy link is exactly when the RM has no reason to downgrade.

---

## 9. Rollback

```bash
cd /usr/src/nvidia-srv-580.178.04
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do sudo cp -a "$f.bak" "$f"; done
KREL=$(uname -r)
sudo dkms build   -m nvidia-srv -v 580.178.04 -k "$KREL" --force
sudo dkms install -m nvidia-srv -v 580.178.04 -k "$KREL" --force
sudo update-initramfs -u -k "$KREL"
sudo systemctl stop nvidia-persistenced
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
sudo systemctl start nvidia-persistenced
```

`patch/tools/rollback.sh` does the same, with fallback to `/root/p104-backup/`;
the script expects the `.bak` files next to the sources. The systemd drop-in
(persistence mode) is harmless and can stay.

If the change was installed as the Debian package instead, this section does not
apply: the driver tree is pristine, and the package is removed with
`sudo dpkg -r nvidia-srv-p104-gen2`, which rebuilds the stock module (§12).

---

## 10. Troubleshooting (observed failure modes)

| Symptom | Cause | Fix |
|---|---|---|
| `LnkCap` stays 2.5 GT/s after `mmio_test apply` | wrong BDF, or BAR0 not decoding | dump must not return all `0xFFFFFFFF`; check `lspci -nn -d 10de:1b87` |
| Link reaches 5 GT/s then reverts within seconds | RM re-asserts Gen1 once the link goes quiet (§1.2) | watchdog (§5.1b) |
| Every `nvidia-smi` re-inits the adapter | persistence mode disabled | systemd drop-in (§7) |
| Hook logs `LNKSTA=0x1041` right after `rm_init_adapter` | the first retrain only latches `LINK_CONFIG_0`, the RM reverts it between tries | 6 attempts, rewrite BAR0 each attempt, 60 ms settle each |
| Gen1 window still ~0.5 s after the faster watchdog | 250 ms tick + latch/train double retrain | expected; see §11 |
| `dkms build` says module already built | existing build for that kernel | `--force` |
| Can't find the patch in `/var/lib/dkms/.../build` | DKMS 3.2.2 builds in a temp dir | check `strings` on the installed `.ko.zst` |
| `modprobe -r nvidia` fails | dependents / open fds | stop persistenced, remove `nvidia_uvm nvidia_drm nvidia_modeset` first, `fuser -v /dev/nvidia*` |
| `systemctl enable nvidia-persistenced` fails | unit is `static` | use the drop-in; it is auto-started by the device unit |
| Registry keys `RMPcieLinkSpeed`, `RMPcieGenSwitchOnPmu`, `RMPcieStickyGenSpeed`, `RmForceEnablePcieGenSwitching`, `NVreg_EnablePCIeGen3`, `NVreg_DynamicPowerManagement=0` | tested with a controlled load, ineffective on GP104 | watchdog is required |

If the PCIe link wedges (device disappears, AER storm), do **not** try to
recover in place: power off (cold boot), then restore backups from `/root/p104-backup/`
before booting with a rebuilt module.

---

## 11. Caveats

- The RM cannot be told to stop downgrading: the registry keys it exposes
  (see §1.2) are parsed but have no effect on GP104. The link therefore still
  drops to Gen1 for a fraction of a second whenever the link goes quiet.
  Measured on this host with one request every ~2.5 s: Gen1 for 21 % of wall
  time and 24 % of busy time, with individual windows of 0.22 s (median).
  Before the faster watchdog it was 29–33 % and 0.75 s windows. For workloads
  that keep the link busy, the RM stops interfering and the duty is far better.
- Each re-assertion costs two link retrains (latch + train), i.e. ~2 retrains
  per second under that chat workload. They are cheap (the link is down for
  ~10 ms) but they do show up in `dmesg` when dynamic debug is enabled.
- If the RM ever starts re-asserting faster than the watchdog can undo it,
  loosen `NV_P104_GEN2_TICK_MS` rather than shortening it further: chasing a
  faster RM only adds retrains without reducing the Gen1 duty.
- Only kernel `7.0.0-43` was rebuilt. Kernel `7.0.0-42` still has the unpatched
  module; rebuild it with the same commands if it is ever booted.
- DKMS `AUTOINSTALL=yes`, so kernel updates rebuild the patched module
  automatically — but re-verify after a **driver** update, since the source
  anchors and the `rm_init_adapter` location can move.
- Reboot was not exercised; the initramfs and device-unit path are expected to
  work but a cold-boot verification is still outstanding.

---

## 12. Debian package (preferred path)

The manual procedure above is automated by `nvidia-srv-p104-gen2`, tested on
this host (install → verified patched → remove → verified stock → reinstall).

Artefacts — all in the repository root:

```
deb/nvidia-srv-p104-gen2_580.178.04-1_all.deb   built package
deb/readme.txt                                  end-user notes (install/deinstall)
deb/REBUILD.md                                  rebuild prompt, agent-facing
deb/packaging/                                  dpkg tree the .deb is built from
patch/                                          patch, sources, tools, this doc
```

### 12.1 Install / remove

```bash
cd deb        # from the repository root
sudo apt install ./nvidia-srv-p104-gen2_580.178.04-1_all.deb   # or dpkg -i
sudo dpkg -r nvidia-srv-p104-gen2                              # or apt remove
```

`postinst` runs `dkms build/install --force` for the running kernel, refuses to
continue if the built module does not contain the P104-100 code, regenerates the
initramfs and reloads the driver if the GPU is idle (otherwise it asks for a
reboot). `postrm` rebuilds and reinstalls the stock module and reloads it.

After removal `LnkSta` returns to 2.5 GT/s immediately; `LnkCap` keeps reporting
5 GT/s until the next reboot because the BAR0 register state lives in the GPU,
not in the module.

### 12.2 What it installs

| Path | Purpose |
|---|---|
| `/etc/dkms/nvidia-srv-580.178.04.conf` | DKMS override adding `PATCH[2]="p104-gen2.patch"` |
| `/usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch` | the patch (applied at build time, source tree stays stock) |
| `/etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf` | `--persistence-mode`, `StopWhenUnneeded=no` |
| `/usr/share/doc/nvidia-srv-p104-gen2/README` | end-user notes |
| `/usr/share/doc/nvidia-srv-p104-gen2/copyright` | MIT license text + note that the NVIDIA driver itself is not redistributed |

Because the patch is applied to DKMS's private copy of the source, the files in
`/usr/src/nvidia-srv-580.178.04/nvidia/` remain **pristine**; `dpkg -V` on the
driver package stays clean.

### 12.3 Rebuilding the package

`deb/REBUILD.md` is the complete procedure (preflight, patch dry-run gate,
metadata checks, install → verify → remove → verify → reinstall). In short:

```bash
cd deb        # from the repository root
cp ../patch/p104-gen2.patch \
   packaging/usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
cp readme.txt packaging/usr/share/doc/nvidia-srv-p104-gen2/README
dpkg-deb --build --root-owner-group packaging \
          nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

If the driver version changes, more than `VER` has to move: `DEBIAN/control`
(`Version`, `Depends`), `DEBIAN/postinst` and `DEBIAN/postrm` (`VER`), the
override filename `/etc/dkms/nvidia-srv-<VER>.conf`, the patch directory
`/usr/src/nvidia-srv-<VER>/patches/`, and the version text in `readme.txt`.
The patch itself is regenerated against the new source tree as described in
`README.md` in this directory.

The patch must apply with `patch -p1` from the DKMS build root (paths
`a/nvidia/...`, `b/nvidia/...`).

### 12.4 Packaging gotchas found the hard way

* **`PATCH[n]` index must be contiguous.** DKMS 3.2.2 iterates with
  `for ((i=0; i < ${#PATCH[@]}; i++))`, so a sparse `PATCH[3]` is silently
  ignored. Stock defines `PATCH[0]`/`PATCH[1]`, therefore use **`PATCH[2]`**.
* **DKMS deletes `/var/lib/dkms/<pkg>/<ver>/build` after a build**, so verify the
  patch in `/lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst` (or in the
  make.log), not in the build tree.
* **Do not depend on `initramfs-tools`**: it is not installed on this host
  (dracut provides `update-initramfs`). Use
  `initramfs-tools-core | initramfs-tools | dracut` and probe the tool at runtime.
* **Check `fuser` for GPU users *after* stopping `nvidia-persistenced`.**
  Otherwise the daemon's own file descriptors make the reload look unsafe and
  it is skipped on every install.
* **`deb/readme.txt` is the single source of the shipped documentation.** Copy
  it to `packaging/usr/share/doc/nvidia-srv-p104-gen2/README` before building,
  otherwise the installed doc silently drifts from the one users read (that is
  how the package once shipped a README documenting the wrong `PATCH[3]`).
* A driver upgrade creates a new `/usr/src/nvidia-srv-<newver>` tree; the
  version-specific override then no longer applies and the new driver builds
  stock. Rebuild the package for the new version.

## Appendix A — `mmio_test.c`



```c
/*
 * mmio_test.c - read-only dump / one-shot apply of the P104-100
 * PCIe Gen2 unlock BAR0 register set.
 *
 * Usage:
 *   mmio_test dump    (default)  read the 8 registers, no writes
 *   mmio_test apply              apply the register writes, then re-dump
 *
 * Bars are mapped straight from the PCI resource file, so this does not
 * depend on CONFIG_STRICT_DEVMEM. Must run as root.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define DEV_RES       "/sys/bus/pci/devices/0000:01:00.0/resource0"
#define BAR0_MAP_SIZE 0x00100000UL

static const unsigned int target_regs[] = {
    0x2241Cu, 0x8841Cu, 0x88610u, 0x8872Cu,
    0x8C040u, 0x8C1C0u, 0x8C2C0u, 0x8C300u,
};
#define NREGS (sizeof(target_regs) / sizeof(target_regs[0]))

static volatile uint32_t *bar;

static uint32_t rd32(unsigned int off) { return bar[off >> 2]; }
static void wr32(unsigned int off, uint32_t v) { bar[off >> 2] = v; }

static int dump_regs(const char *tag)
{
    unsigned int i;
    int dead = 0;

    printf("--- %s ---\n", tag);
    for (i = 0; i < NREGS; i++) {
        uint32_t v = rd32(target_regs[i]);
        printf("  0x%05X = 0x%08X\n", target_regs[i], v);
        if (v == 0xFFFFFFFFu)
            dead++;
    }
    if (dead == (int)NREGS) {
        printf("!! all registers read 0xFFFFFFFF: BAR0 not decoding\n");
        return -1;
    }
    if (dead)
        printf("!! %d of %zu registers read 0xFFFFFFFF\n", dead, NREGS);
    return 0;
}

static void apply_unlock(void)
{
    uint32_t val;

    /* 1. XVE / XP_PL Gen2 capability declarations */
    wr32(0x8872Cu, 0x6);
    wr32(0x2241Cu, rd32(0x2241Cu) | 0x81u);
    wr32(0x8841Cu, rd32(0x8841Cu) & ~0x6000u);
    wr32(0x8C2C0u, rd32(0x8C2C0u) & ~0x4u);
    wr32(0x8C300u, rd32(0x8C300u) & ~0x10u);

    /* 2. LINK_CONFIG_0: SPEED = 1 (5.0 GT/s) */
    val = (rd32(0x8C040u) & ~(0x3u << 18)) | (0x1u << 18);
    wr32(0x8C040u, val);

    /* 3. NV_XP_PL_LCTRL_2: target 5.0 GT/s */
    val = (rd32(0x8C1C0u) & ~(0xFu << 16)) | (0x2u << 16);
    wr32(0x8C1C0u, val);

    wr32(0x88610u, (rd32(0x88610u) & ~0x1000u) | 0x1u);

    /* flush posted writes */
    (void)rd32(0x8872Cu);
}

int main(int argc, char **argv)
{
    int do_apply = (argc > 1 && strcmp(argv[1], "apply") == 0);
    int fd;
    void *map;

    if (geteuid() != 0) {
        fprintf(stderr, "must run as root\n");
        return 1;
    }

    fd = open(DEV_RES, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", DEV_RES, strerror(errno));
        return 1;
    }

    map = mmap(NULL, BAR0_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    bar = (volatile uint32_t *)map;

    printf("BAR0 mapped at %p (%lu bytes)\n", map, (unsigned long)BAR0_MAP_SIZE);

    if (dump_regs("before") != 0) {
        fprintf(stderr, "aborting: BAR0 is not decoding\n");
        munmap(map, BAR0_MAP_SIZE);
        close(fd);
        return 2;
    }

    if (!do_apply) {
        printf("read-only dump complete (pass 'apply' to write)\n");
        munmap(map, BAR0_MAP_SIZE);
        close(fd);
        return 0;
    }

    apply_unlock();
    printf("writes applied\n");
    dump_regs("after");

    munmap(map, BAR0_MAP_SIZE);
    close(fd);
    return 0;
}
```

## Appendix B — `linktest.sh`

```bash
#!/bin/bash
# Config-space-only control: request 5.0 GT/s and retrain.
#   linktest.sh           set TLS=5.0GT/s on GPU+root port, retrain, sample LNKSTA
#   linktest.sh restore   put TLS back to "auto" (0) on both, retrain
#   linktest.sh status    read-only
set -u
GPU=01:00.0
RP=00:01.0

rd()  { setpci -s "$1" "CAP_EXP+${2}.w"; }

set_tls() { # bdf value
  local cur new
  cur=$(rd "$1" 30) || return 1
  new=$(printf '%04x' $(( (0x$cur & ~0x000f) | ($2 & 0x000f) )))
  echo "  $1 LNKCTL2 0x$cur -> 0x$new"
  setpci -s "$1" "CAP_EXP+30.w=$new"
}

retrain() { # bdf
  local cur new
  cur=$(rd "$1" 10) || return 1
  new=$(printf '%04x' $(( 0x$cur | 0x0020 )))
  echo "  $1 LNKCTL 0x$cur -> 0x$new (RL)"
  setpci -s "$1" "CAP_EXP+10.w=$new"
}

status() {
  for d in "$GPU" "$RP"; do
    printf '%s  LNKCTL2=0x%s  LNKCTL=0x%s  LNKSTA=0x%s\n' \
      "$d" "$(rd "$d" 30)" "$(rd "$d" 10)" "$(rd "$d" 12)"
    sudo -n lspci -s "$d" -vv | grep -E 'LnkCap:|LnkSta:'
  done
}

case "${1:-apply}" in
  status)
    status
    ;;
  restore)
    echo "restoring TLS to auto:"
    set_tls "$GPU" 0
    set_tls "$RP"  0
    retrain "$RP"
    sleep 0.1
    status
    ;;
  apply)
    echo "== before =="
    status
    echo "== requesting 5.0 GT/s =="
    set_tls "$GPU" 2
    set_tls "$RP"  2
    retrain "$GPU"
    retrain "$RP"
    sleep 0.2
    echo "== after =="
    status
    echo "NOTE: leaving TLS at 5.0GT/s; run '$0 restore' to revert"
    ;;
  *)
    echo "usage: $0 [apply|restore|status]" >&2
    exit 1
    ;;
esac
```

Run it with `sudo` (all `setpci`/`lspci` calls inside need root).

## Appendix C — `nv_pci` helpers

Insert verbatim before `/* find nvidia devices and set initial state */` in
`nvidia/nv-pci.c`:

```c
static void nv_p104_write_bar0(void __iomem *bar0)
{
    u32 val;

    /* 1. Unlock BAR0 XVE/XP_PL Gen2 capability declarations */
    iowrite32(0x6, bar0 + 0x8872C);
    iowrite32(ioread32(bar0 + 0x2241C) | 0x81, bar0 + 0x2241C);
    iowrite32(ioread32(bar0 + 0x8841C) & ~0x6000, bar0 + 0x8841C);
    iowrite32(ioread32(bar0 + 0x8C2C0) & ~0x4, bar0 + 0x8C2C0);
    iowrite32(ioread32(bar0 + 0x8C300) & ~0x10, bar0 + 0x8C300);

    /* 2. LINK_CONFIG_0 (0x8C040) SPEED = 1 (5.0 GT/s) */
    val = (ioread32(bar0 + 0x8C040) & ~(0x3U << 18)) | (0x1U << 18);
    iowrite32(val, bar0 + 0x8C040);

    /* 3. NV_XP_PL_LCTRL_2 (0x8C1C0): target 5.0 GT/s */
    val = (ioread32(bar0 + 0x8C1C0) & ~(0xFU << 16)) | (0x2U << 16);
    iowrite32(val, bar0 + 0x8C1C0);

    iowrite32((ioread32(bar0 + 0x88610) & ~0x1000U) | 0x1U, bar0 + 0x88610);

    /* Flush posted MMIO writes before triggering link retrain */
    (void)ioread32(bar0 + 0x8872C);
}

/*
 * The Resource Manager re-asserts its own 2.5 GT/s setting (it rewrites
 * LINK_CONFIG_0) roughly 0.25 s into every burst of GPU work, i.e. as soon as
 * the link itself goes quiet while the GPU is in P0. A one-shot unlock does
 * not hold; the correction has to be re-applied once per burst.
 *
 * Measured cost of the downshift is entirely the detection latency, so poll
 * fast: one PCIe config read every 250 ms while the link is already at
 * 5.0 GT/s, which is 4 reads/s and negligible.
 *
 * Within a round the first retrain only latches LINK_CONFIG_0; the second one
 * is what actually trains at 5.0 GT/s. So the settle window per attempt is
 * short: waiting longer for the first retrain just stretches the window.
 */
#define NV_P104_GEN2_TICK_MS      250
#define NV_P104_GEN2_SETTLE_MS     10
#define NV_P104_GEN2_SETTLE_TRIES   6   /* 60 ms upper bound per attempt */

static struct task_struct *nv_p104_gen2_task;
static NvBool nv_p104_gen2_logged = NV_FALSE;

static int nv_p104_gen2_watchdog(void *unused)
{
    while (!kthread_should_stop()) {
        struct pci_dev *dev = pci_get_device(0x10de, 0x1b87, NULL);

        if (dev != NULL) {
            nv_force_p104_gen2(dev);
            pci_dev_put(dev);
        }

        msleep(NV_P104_GEN2_TICK_MS);
    }

    return 0;
}

static void nv_p104_gen2_start_watchdog(void)
{
    if (nv_p104_gen2_task != NULL)
        return;

    nv_p104_gen2_task = kthread_run(nv_p104_gen2_watchdog, NULL,
                                    "nv-p104-gen2-wd");
    if (IS_ERR(nv_p104_gen2_task)) {
        nv_printf(NV_DBG_ERRORS,
                  "NVRM: failed to start P104-100 Gen2 watchdog\n");
        nv_p104_gen2_task = NULL;
    }
}

static void nv_p104_gen2_stop_watchdog(void)
{
    if (nv_p104_gen2_task == NULL)
        return;

    kthread_stop(nv_p104_gen2_task);
    nv_p104_gen2_task = NULL;
}

/*
 * P104-100 (10de:1b87) PCIe Gen2 unlock.
 *
 * The P104-100 restricts its PCIe link to 2.5 GT/s through GPU state rather
 * than through anything visible in PCIe config space, so re-declare 5.0 GT/s
 * as the capability in the BAR0 XVE/XP_PL registers, request 5.0 GT/s as the
 * target link speed, and retrain the link via PCIe config space.
 *
 * The Resource Manager resets this state on adapter init / teardown, so this
 * helper is called both from probe and right after rm_init_adapter(). A single
 * retrain right after adapter init frequently does not take, hence the retry
 * loop. The writes are idempotent and the function is a no-op once the link is
 * already running at 5.0 GT/s.
 */
void nv_force_p104_gen2(struct pci_dev *dev)
{
    void __iomem *bar0;
    struct pci_dev *root;
    resource_size_t bar0_phys;
    resource_size_t bar0_len;
    u16 lnksta = 0;
    int attempt;
    int settle;

    if (!dev || dev->vendor != 0x10de || dev->device != 0x1b87)
        return;

    /* Already at 5.0 GT/s (Gen2 == 0x2 in bits [3:0])? */
    pcie_capability_read_word(dev, PCI_EXP_LNKSTA, &lnksta);
    if ((lnksta & PCI_EXP_LNKSTA_CLS) == PCI_EXP_LNKSTA_CLS_5_0GB)
        return;

    root = (dev->bus && dev->bus->self) ? dev->bus->self : NULL;
    if (root && pci_pcie_type(root) != PCI_EXP_TYPE_ROOT_PORT)
        root = NULL;

    bar0_phys = pci_resource_start(dev, 0);
    bar0_len  = pci_resource_len(dev, 0);
    if (!bar0_phys || bar0_len < 0x100000)
        return;

    bar0 = ioremap(bar0_phys, 0x100000);
    if (!bar0) {
        pci_warn(dev, "P104-100: failed to ioremap BAR0 for Gen2 unlock\n");
        return;
    }

    /* BAR does not decode while the GPU is powered down: do not poke it. */
    if (ioread32(bar0 + 0x8C040) == 0xFFFFFFFF) {
        iounmap(bar0);
        return;
    }

    for (attempt = 0; attempt < 6; attempt++) {
        /*
         * The previous attempt's link training may simply still be settling.
         * Re-check before clobbering the registers again; retraining a link
         * that is already coming up only adds another link-down event.
         */
        if (attempt > 0) {
            pcie_capability_read_word(dev, PCI_EXP_LNKSTA, &lnksta);
            if ((lnksta & PCI_EXP_LNKSTA_CLS) == PCI_EXP_LNKSTA_CLS_5_0GB)
                break;
        }

        /*
         * The Resource Manager can revert the BAR0 link state between
         * attempts, so rewrite it before every retrain.
         */
        nv_p104_write_bar0(bar0);

        /* Target 5.0 GT/s on the GPU and its upstream root port */
        pcie_capability_clear_and_set_word(dev, PCI_EXP_LNKCTL2,
                                           PCI_EXP_LNKCTL2_TLS,
                                           PCI_EXP_LNKCTL2_TLS_5_0GT);
        if (root) {
            pcie_capability_clear_and_set_word(root, PCI_EXP_LNKCTL2,
                                               PCI_EXP_LNKCTL2_TLS,
                                               PCI_EXP_LNKCTL2_TLS_5_0GT);
        }

        if (root)
            pcie_capability_set_word(root, PCI_EXP_LNKCTL, PCI_EXP_LNKCTL_RL);
        pcie_capability_set_word(dev, PCI_EXP_LNKCTL, PCI_EXP_LNKCTL_RL);

        /*
         * Poll rather than sleeping a fixed 250 ms: the link normally settles
         * in a few tens of milliseconds, and every millisecond between the
         * Resource Manager's downgrade and this retrain is a millisecond the
         * link spends at 2.5 GT/s. Same 250 ms upper bound per attempt.
         */
        for (settle = 0; settle < NV_P104_GEN2_SETTLE_TRIES; settle++) {
            msleep(NV_P104_GEN2_SETTLE_MS);
            pcie_capability_read_word(dev, PCI_EXP_LNKSTA, &lnksta);
            if ((lnksta & PCI_EXP_LNKSTA_CLS) == PCI_EXP_LNKSTA_CLS_5_0GB) {
                pci_dbg(dev,
                        "nv-p104-gen2: attempt %d reached 5.0 GT/s after %d ms\n",
                        attempt + 1,
                        (settle + 1) * NV_P104_GEN2_SETTLE_MS);
                break;
            }
        }

        if ((lnksta & PCI_EXP_LNKSTA_CLS) == PCI_EXP_LNKSTA_CLS_5_0GB)
            break;
    }

    iounmap(bar0);

    if ((lnksta & PCI_EXP_LNKSTA_CLS) == PCI_EXP_LNKSTA_CLS_5_0GB) {
        if (!nv_p104_gen2_logged) {
            nv_p104_gen2_logged = NV_TRUE;
            pci_info(dev, "P104-100: PCIe Gen2 unlock applied, LNKSTA=0x%04x (Speed=%u, Width=x%u)\n",
                     lnksta,
                     lnksta & PCI_EXP_LNKSTA_CLS,
                     (lnksta & PCI_EXP_LNKSTA_NLW) >> PCI_EXP_LNKSTA_NLW_SHIFT);
        } else {
            pci_dbg(dev, "P104-100: Gen2 re-applied, LNKSTA=0x%04x\n", lnksta);
        }
    } else {
        pci_dbg(dev, "P104-100: link did not reach 5.0 GT/s, LNKSTA=0x%04x\n", lnksta);
    }
}
```
