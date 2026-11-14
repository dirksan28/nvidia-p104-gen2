# AGENT_PROMPT.md — apply or re-derive the P104-100 PCIe Gen2 x4 unlock

Task prompt for a coding agent, and a step-by-step procedure for a human. The
goal is a P104-100 (`10de:1b87`) whose PCIe link runs at **5.0 GT/s x4** and
returns to it after every adapter re-initialisation.

Everything here was executed on the reference host: Ubuntu 26.04, kernel
`7.0.0-43-generic`, DKMS module `nvidia-srv` 580.178.04. The canonical change is
[`p104-gen2.patch`](p104-gen2.patch); if a snippet below ever disagrees with it,
the patch wins. §11 records why the code looks the way it does, §13 the failure
modes seen in practice.

## Contents

0. How to use this file
1. Mission, boundaries, stop conditions
2. Choose the path and collect inputs
3. Phase A — preflight and baseline
4. Phase B — userspace pre-test (hard gate)
5. Phase C — backups
6. Phase D — patch the kernel module
7. Phase E — build, install, keep the adapter initialised
8. Phase F — reload and verify
9. Phase G — rollback
10. Phase H — report
11. Background: register facts, RM behaviour, measurements
12. Rebasing for another driver version
13. Troubleshooting
14. Related documents

---

## 0. How to use this file

**As an agent.** Load the whole file before acting. Run the phases in order and
stop at the first failed gate — do not improvise register values, skip the
userspace pre-test, or "try" a patch when the gate failed. Two steps require an
explicit go-ahead from the operator: the BAR0 writes in Phase B, and the module
reload in Phase E (which fails if a CUDA client holds the GPU). Report with the
template in §10. If `nvidia-srv-p104-gen2` is installed, do not hand-edit
`/usr/src`; use the package instead ([`../deb/readme.txt`](../deb/readme.txt)).

**As a human.** The same phases apply and every command is meant to be pasted.
Read §11 if you want to know why the code exists, and §13 when something does
not match the expected output. If you only need the finished package, use
[`../deb/readme.txt`](../deb/readme.txt) instead of this file.

**Scope.** One machine, one P104-100, one driver source tree. The code is a
no-op for every other PCI ID, and the NVIDIA driver itself is not redistributed.
The procedure edits the DKMS source tree, so it is the manual counterpart of the
package and not something to run on a machine where the package is installed.

---

## 1. Mission, boundaries, stop conditions

**Deliverable:** `LnkSta: Speed 5GT/s, Width x4` on the GPU and its root port,
`pcie.link.gen.current=2`, persistence mode enabled, and a watchdog thread
(`nv-p104-gen2-wd`) that restores Gen2 after the Resource Manager drops it.

**Boundaries:**

- Never write speculative values to BAR0. The offsets in §11.1 were proven on
  this card with the userspace tool; Phase B is the gate that proves them again
  on the target machine.
- Back up every file under `/usr/src` before editing it (§5), and keep the
  `.bak` files until the result is verified.
- Do not edit the driver tree if `nvidia-srv-p104-gen2` is installed. That
  package applies the patch to DKMS's private copy and depends on the tree
  staying pristine (`dpkg -V` must stay clean).
- Do not unload the NVIDIA modules while Xorg, Wayland or a CUDA process holds
  `/dev/nvidia*`.
- Do not use the NVIDIA `.run` installer; this workflow needs the DKMS tree at
  `/usr/src/nvidia-srv-<ver>`.

**Stop and report if:**

- `lspci` shows no `10de:1b87`, or the driver version is not 580.178.04
  (rebasing is §12; do not apply a mismatched patch).
- `mmio_test apply` does not reach 5 GT/s (Phase B gate).
- `dkms build` emits any `warning:` or `error:` line.
- The module contains no `P104-100:` marker after install.
- The link does not verify after reload, or the device disappears / AER storms
  (power off, cold boot, then restore backups — §13).

---

## 2. Choose the path and collect inputs

Run these first and keep the output for the report:

```bash
uname -r
lspci -nn -d 10de:1b87
dpkg-query -W nvidia-dkms-580-server
dkms status
ls -d /usr/src/nvidia-srv-* 2>/dev/null
sudo mokutil --sb-state
ls /usr/src/linux-headers-$(uname -r)/ >/dev/null && echo headers-ok
sudo -n true && echo sudo-ok
sudo fuser /dev/nvidia* 2>/dev/null | wc -l
```

| Finding | Action |
|---|---|
| GPU `10de:1b87`, driver **580.178.04**, tree `/usr/src/nvidia-srv-580.178.04` | proceed to Phase A |
| Link already 5 GT/s and `dmesg` shows `P104-100:` | already done; verify §8 and stop |
| Driver present but a **different version** | stop; rebase the patch (§12) or install the pinned driver (`../deb/readme.txt`) |
| No driver, or a `.run` installation | install the stock DKMS driver first (`../deb/readme.txt`, *FROM ZERO*) and reboot |

Set one path for the rest of the procedure — the clone root. It is the only
machine-specific value here; re-set it if you open a new shell.

```bash
REPO=$(pwd)     # run from the repository root
```

Tools referenced below live in [`tools/`](tools/): `mmio_test.c`,
`linktest.sh`, `dump.sh`, `rollback.sh`, `bwtest.cu`. They are not duplicated in
this file.

---

## 3. Phase A — preflight and baseline

```bash
cat /sys/bus/pci/devices/0000:01:00.0/{current_link_speed,max_link_speed,current_link_width}
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
sudo lspci -s 00:01.0 -vv | grep -E 'LnkCap:|LnkSta:'
pgrep -a 'Xorg|Xwayland|gnome-shell'          # expect nothing on a headless host
lsmod | grep '^nvidia'
```

A stock P104-100 reads `LnkCap: Speed 2.5GT/s` and `LnkSta: 2.5GT/s x4`;
the root port may advertise more (`8 GT/s x16` here). Record both.
`current_link_speed` should be `2.5 GT/s PCIe` before you start.

Locate the anchors in the source tree (line numbers move between branches):

```bash
cd /usr/src/nvidia-srv-580.178.04
grep -n 'nv_check_and_exclude_gpu\|rm_enable_dynamic_power_management\|rm_notify_gpu_addition' nvidia/nv-pci.c
grep -n 'rm_init_adapter' nvidia/nv.c
grep -n 'nv_pci_unregister_driver' nvidia/nv-pci.c
```

The hooks must go:

- **probe:** after `nv_check_and_exclude_gpu(sp, nv);` and **before**
  `rm_enable_dynamic_power_management()`. The source forbids hardware register
  access after DPM is enabled, and nothing may be added after
  `rm_notify_gpu_addition()`.
- **post-init:** immediately after the successful `rm_init_adapter(sp, nv)` in
  `nv_start_device()` — not in `nv_open_device()`, which calls it.
- **unregister:** in `nv_pci_unregister_driver()`, to stop the watchdog.

Check the kernel macros the code needs:

```bash
grep -E 'PCI_EXP_LNKSTA_CLS_5_0GB|PCI_EXP_LNKCTL2_TLS(_5_0GT)?\b' \
  /usr/src/linux-headers-$(uname -r)/include/uapi/linux/pci_regs.h
```

**Gate:** all of the above must hold. If the GPU is not `10de:1b87`, or the
driver/tree is not 580.178.04, stop.

---

## 4. Phase B — userspace pre-test (hard gate)

Purpose: prove the BAR0 offsets on **your** card before touching the kernel. A
wrong write can wedge the link and require a cold boot; doing it from userspace
makes that failure cheap. Run this on the **stock** driver — the patched module
already runs at 5 GT/s and hides the effect.

**Ask the operator before the write step below.** Confirm no job is using the
GPU.

```bash
cd "$REPO"/patch/tools
mkdir -p /tmp/p104-gen2
gcc -O2 -Wall -Wextra -o /tmp/p104-gen2/mmio_test mmio_test.c
cp linktest.sh /tmp/p104-gen2/
cd /tmp/p104-gen2
```

The tool maps `/sys/bus/pci/devices/0000:01:00.0/resource0` directly (no
`/dev/mem`, so `CONFIG_STRICT_DEVMEM` is irrelevant) and needs root.

### 4.1 Read-only dump

```bash
sudo ./mmio_test dump
```

Expected on this card (use as a sanity check, not as an exact requirement):

```
0x2241C = 0x00000000   0x8841C = 0xC0B46500   0x88610 = 0x00000000
0x8872C = 0x00000000   0x8C040 = 0x20085800   0x8C1C0 = 0x00010036
0x8C2C0 = 0x068711B3   0x8C300 = 0x040A00C0
```

All `0xFFFFFFFF` means BAR0 is not decoding (GPU powered down or wrong BDF):
stop.

### 4.2 Control test — config space alone

```bash
sudo ./linktest.sh apply      # LNKCTL2.TLS=5.0GT/s on GPU and root port, retrain
sudo ./linktest.sh status
sudo ./linktest.sh restore    # put TLS back to auto
```

Expected: the link **stays at 2.5 GT/s**; the GPU's config-space write may not
even stick. This is the proof that the cap lives in GPU state, not in PCIe
config space.

### 4.3 Apply the BAR0 writes

```bash
sudo ./mmio_test apply
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
```

Expected immediately: `LnkCap: Speed 5GT/s` but `LnkSta: Speed 2.5GT/s
(downgraded)`. Then retrain; the first attempt usually only latches:

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

Expected: `LnkSta: Speed 5GT/s, Width x4` on `01:00.0` and `00:01.0`.

**Gate:** if this does not reach 5 GT/s, stop and do not patch the kernel. This
state is volatile: the Resource Manager resets it on the next adapter init, so
the stock link is back after `nvidia-smi` or a reboot.

---

## 5. Phase C — backups

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

The sources are root-owned, so stage edits under `/tmp` and install them with
`sudo install`:

```bash
mkdir -p /tmp/p104-gen2/work && cd /tmp/p104-gen2/work
cp -a /usr/src/nvidia-srv-580.178.04/nvidia/nv-pci.c .
cp -a /usr/src/nvidia-srv-580.178.04/nvidia/nv.c .
cp -a /usr/src/nvidia-srv-580.178.04/common/inc/nv-pci.h .
```

---

## 6. Phase D — patch the kernel module

Apply [`p104-gen2.patch`](p104-gen2.patch) with `patch -p1` from the driver
source root, or make the edits below. The listings are explanatory; the patch
is authoritative and reproduces [`source/patched/`](source/patched/) byte for
byte.

```bash
sudo patch -d /usr/src/nvidia-srv-580.178.04 -p1 < "$REPO"/patch/p104-gen2.patch
```

### 6.1 `nvidia/nv-pci.c` — includes

After `#include <linux/iommu.h>`:

```c
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/kthread.h>
```

### 6.2 `nvidia/nv-pci.c` — helpers, watchdog, unlock

Insert before `/* find nvidia devices and set initial state */` (that is, before
`nv_pci_probe`):

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
         * Poll rather than sleeping a fixed interval: the link normally
         * settles in a few tens of milliseconds, and every millisecond
         * between the Resource Manager's downgrade and this retrain is a
         * millisecond the link spends at 2.5 GT/s. 60 ms budget per attempt.
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

### 6.3 `nvidia/nv-pci.c` — hooks

After `nv_check_and_exclude_gpu(sp, nv);` in `nv_pci_probe`:

```c
    /* P104-100: unlock PCIe Gen2 while BAR0 is still accessible */
    if (nvl->pci_dev->device == 0x1b87) {
        nv_force_p104_gen2(nvl->pci_dev);
        nv_p104_gen2_start_watchdog();
    }
```

In `nv_pci_unregister_driver()`, after the `NVreg_RegisterPCIDriver == 0` early
return and before `pci_unregister_driver()`:

```c
    nv_p104_gen2_stop_watchdog();
    return pci_unregister_driver(&nv_pci_driver);
```

### 6.4 `nvidia/nv.c`

After `#include "detect-self-hosted.h"`:

```c
/* Implemented in nv-pci.c: P104-100 PCIe Gen2 unlock */
void nv_force_p104_gen2(struct pci_dev *dev);
```

In `nv_start_device()`, immediately after the successful
`if (!rm_init_adapter(sp, nv)) { ... }` block:

```c
    /*
     * P104-100: rm_init_adapter() has just re-initialized the link state;
     * re-apply the Gen2 unlock so the adapter comes up at 5.0 GT/s.
     */
    if (nvl != NULL && nvl->pci_dev != NULL)
        nv_force_p104_gen2(nvl->pci_dev);
```

### 6.5 `common/inc/nv-pci.h`

Before `#endif`:

```c
/* Implemented in nv-pci.c: P104-100 PCIe Gen2 unlock */
void nv_force_p104_gen2(struct pci_dev *dev);
```

There is no `nvidia/nv-pci.h`; the header is `common/inc/nv-pci.h`. `nv.c` does
not include it, hence the local prototype there (which also keeps
`-Wmissing-prototypes` quiet).

### 6.6 Review the change

```bash
cd /usr/src/nvidia-srv-580.178.04
{ diff -u nvidia/nv-pci.c.bak nvidia/nv-pci.c
  diff -u nvidia/nv.c.bak nvidia/nv.c
  diff -u common/inc/nv-pci.h.bak common/inc/nv-pci.h; } > /tmp/p104-gen2/review.diff
```

This scratch diff is for reading only; `p104-gen2.patch` remains the
authoritative change.

Expected shape: 3 include lines, 219 added lines in `nv-pci.c`, a 6-line probe
hook, a 1-line unregister hook, 10 lines in `nv.c`, 4 lines in `nv-pci.h`. The
validated `a/`–`b/` form is `p104-gen2.patch` (286 lines, +219/+10/+4). Applying
that patch to [`source/pristine/`](source/pristine/) must reproduce
[`source/patched/`](source/patched/) — if you are rebasing, use that as the
correctness test.

---

## 7. Phase E — build, install, keep the adapter initialised

```bash
KREL=$(uname -r)
sudo dkms build   -m nvidia-srv -v 580.178.04 -k "$KREL" --force 2>&1 | tee /tmp/p104-gen2/dkms-build.log
grep -iE 'warning:|error:' /tmp/p104-gen2/dkms-build.log    # must be empty
sudo dkms install -m nvidia-srv -v 580.178.04 -k "$KREL" --force
sudo update-initramfs -u -k "$KREL"
```

Verify the compiled module contains the patch. DKMS 3.2.2 builds in a temporary
directory and deletes it, so check the installed object, not the build tree:

```bash
zstd -dc /lib/modules/$KREL/updates/dkms/nvidia.ko.zst | strings | grep 'P104-100'
# expect: "P104-100: failed to ioremap BAR0 ..." and "P104-100: PCIe Gen2 unlock applied ..."
```

If the build fails, read
`/var/lib/dkms/nvidia-srv/580.178.04/$KREL/x86_64/log/make.log` (or the `tee`d
copy), fix the cause or roll back (§9). Never ship a module built
with warnings you have not explained.

Persistence mode is required, because the stock unit runs
`--no-persistence-mode`: every `nvidia-smi` otherwise tears the adapter down and
the RM resets the link.

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

`systemctl enable` is a no-op: the unit is static and starts from
`sys-bus-pci-drivers-nvidia.device`. A manual `sudo nvidia-smi -pm 1` is enough
for a quick test without the drop-in.

---

## 8. Phase F — reload and verify

**Ask the operator before reloading.** Stop anything holding the GPU first:

```bash
sudo systemctl stop nvidia-persistenced; sleep 1
sudo fuser -v /dev/nvidia*                      # must be empty
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
sudo systemctl start nvidia-persistenced; sleep 5
```

If `fuser` lists a process, do not force the unload: ask the operator to stop
it (CUDA job, compositor, container) or reboot with the module already built.

Acceptance:

```bash
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'   # 5GT/s x4 both
sudo lspci -s 00:01.0 -vv | grep -E 'LnkCap:|LnkSta:'
nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current --format=csv,noheader
sudo dmesg | grep 'P104-100'
ps -eo comm | grep nv-p104-gen2-wd
```

Idle stability, sampled at 2 Hz (expect all or almost all at 5 GT/s):

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

Reference result: `98/100` — an **idle** check, immediately after install. It is
not a load test. Under a CUDA client the RM re-asserts Gen1 whenever the link
goes quiet, so ~20 % of samples at 2.5 GT/s are normal while a chat workload is
running (§11.3).

Optional bandwidth check (needs `nvcc`, independent of the driver):

```bash
nvcc -O2 -arch=sm_61 -o /tmp/p104-gen2/bwtest "$REPO"/patch/tools/bwtest.cu
/tmp/p104-gen2/bwtest 256 8
```

Reference: H2D `1453 MiB/s` (1.52 GB/s), D2H `1537 MiB/s` (1.61 GB/s), about
90 % of the Gen2 x4 payload ceiling; Gen1 gives roughly half. Sample
`current_link_speed` during the run — the link must stay at 5.0 GT/s, since a
busy link is exactly when the RM has no reason to downgrade.

---

## 9. Phase G — rollback

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

[`tools/rollback.sh`](tools/rollback.sh) does the same and falls back to
`/root/p104-backup/`. The persistence drop-in is harmless and can stay.

If the change came from the Debian package, do not use this section: the driver
tree is pristine, and `sudo dpkg -r nvidia-srv-p104-gen2` rebuilds the stock
module.

After a rollback `LnkSta` returns to 2.5 GT/s immediately; `LnkCap` may keep
reporting 5 GT/s until the next reboot because that state lives in the GPU, not
in the module. `LnkSta` is the authoritative field.

---

## 10. Phase H — report

Return, with observed output rather than assertions:

1. Host: kernel, driver package version, GPU BDF, secure-boot state, sudo mode.
2. Phase A baseline: `LnkCap`/`LnkSta` for the GPU and root port,
   `current_link_speed`.
3. Phase B: dump values, control-test result, whether the BAR0 writes reached
   5 GT/s, and the link state afterwards.
4. Phase D/E: where each hook landed (file and nearby symbol), build result,
   warning/error count, marker found in the installed `.ko.zst`.
5. Phase F: `LnkSta`, `nvidia-smi` line, `dmesg` marker, watchdog thread,
   stability count.
6. Deviations: any step skipped, any command that did not match the expected
   output, whether the reload was skipped and a reboot is required.

Do not report success if the reload was skipped — the module on disk is patched
but the running one is not.

---

## 11. Background: register facts, RM behaviour, measurements

### 11.1 The register set

`LnkCap` cannot be changed through PCIe config space. The 2.5 GT/s ceiling comes
from the GPU's XVE/XP_PL blocks in BAR0:

| Offset | Register | Write in the patch |
|---|---|---|
| `0x2241C` | XVE capability | `|= 0x81` |
| `0x8841C` | XP_PL capability | `&= ~0x6000` |
| `0x8872C` | flush/latch | write `0x6` |
| `0x8C040` | `LINK_CONFIG_0` | `SPEED` bits `[19:18] = 1` (5.0 GT/s) |
| `0x8C1C0` | `NV_XP_PL_LCTRL_2` | target speed bits `[19:16] = 2` |
| `0x8C2C0` | XP_PL control | `&= ~0x4` |
| `0x8C300` | XP_PL control | `&= ~0x10` |
| `0x88610` | XP_PL control | `&= ~0x1000`, `|= 0x1` |

The write order and the final read-back matter: posted MMIO writes must be
flushed before the retrain is triggered. These offsets were proven with
`tools/mmio_test.c` on this card before any kernel code was written.

### 11.2 Why the RM keeps downgrading, and what does not work

Three closed-source Resource Manager behaviours break a one-shot unlock:

1. **Adapter teardown per client.** Ubuntu's `nvidia-persistenced.service` runs
   `--no-persistence-mode`, so nothing holds `/dev/nvidia0` and every
   `nvidia-smi` runs `rm_init_adapter` again, resetting the link. Fixed by the
   drop-in in §7.
2. **Per-burst downgrade.** With persistence on, the RM still rewrites
   `LINK_CONFIG_0 (0x8C040)` back to `SPEED=2` as soon as the *link* goes quiet
   while the GPU is in P0: measured ~0.25 s into each burst of work, ~0.55 s
   after the previous request ended. At true idle it does not fire and the link
   holds 5 GT/s indefinitely. It never upshifts on its own. Hence the watchdog.
3. **Retrain timing.** The first retrain of a round only latches
   `LINK_CONFIG_0`; the **second** trains at 5.0 GT/s in ~10 ms. Waiting longer
   after the first (250 ms, 600 ms) does not help — it only stretches the Gen1
   window. The helper polls in 10 ms steps, 60 ms budget per attempt, rewrites
   BAR0 before each attempt, and re-checks `LNKSTA` before retraining again.

These were tested with a controlled local load and did **not** prevent the
downgrade:

| Key | Value tried | Result |
|---|---|---|
| `RMPcieLinkSpeed` | `2` | parsed in `/proc/driver/nvidia/params`, no effect on GP104 |
| `RMPcieGenSwitchOnPmu` | `0` | no effect |
| `RMPcieStickyGenSpeed` | `1` | no effect |
| `RmForceEnablePcieGenSwitching` | `0` | no effect |
| `NVreg_EnablePCIeGen3` | `1` | no effect |
| `NVreg_DynamicPowerManagement` | `0` | no effect |

Clock locking is also not an option: `nvidia-smi -lgc` reports *"Setting locked
GPU clocks is not supported"* on this GPU. Do not add registry parameters or
retry counts expecting to veto the RM; only the watchdog bounds the exposure.

### 11.3 Measured behaviour

| Condition | Gen2 time | Gen1 window |
|---|---|---|
| Idle (no CUDA client) | ~100 % | none |
| Chat workload, 1 request / 2.5 s, 250 ms watchdog | 79 % of wall, 76 % of busy | 0.22 s median |
| Same workload, original 1 s watchdog | 71 % of wall, 67 % of busy | 0.75 s median |

Link throughput, measured with `tools/bwtest.cu` while sampling
`current_link_speed` at 50 ms (all samples 5.0 GT/s):

```
H2D:   2048 MiB in 1409.3 ms ->  1453 MiB/s (1.52 GB/s)
D2H:   2048 MiB in 1332.6 ms ->  1537 MiB/s (1.61 GB/s)
```

That is ~90 % of the Gen2 x4 payload ceiling (~1.7 GB/s); Gen1 measures about
half. An LLM inference workload moves only tens of MiB/s, so monitoring tools
will not show these numbers while serving requests — only model load or an
explicit large copy does.

### 11.4 Caveats

- The RM cannot be told to stop downgrading. Expect Gen1 windows under load;
  they are bounded by the tick, not eliminated by it.
- Each re-assertion costs two retrains (latch + train), ~2 per second under the
  chat workload. They are cheap (~10 ms link-down each) but visible in `dmesg`
  with dynamic debug enabled.
- If the RM ever re-asserts faster than the watchdog can undo, **loosen**
  `NV_P104_GEN2_TICK_MS` rather than shortening it: chasing a faster RM only
  adds retrains without reducing the Gen1 duty.
- Only kernel `7.0.0-43` was rebuilt here; rebuild any other installed kernel
  with the same commands before booting it.
- DKMS has `AUTOINSTALL=yes`, so kernel updates rebuild the patched module
  automatically. Re-verify after a **driver** update: the source anchors and
  the `rm_init_adapter` location can move.
- A cold-boot verification of the initramfs/device-unit path is still
  outstanding.

---

## 12. Rebasing for another driver version

The hooks are anchored to 580.178.04. For a new tree, expect offsets and line
numbers to move; regenerate rather than hand-editing the stored patch.

```bash
S=/usr/src/nvidia-srv-<newver>          # confirm with: ls -d /usr/src/nvidia-srv-*
cd "$REPO"/patch
P=$PWD/p104-gen2.patch
T=$(mktemp -d /tmp/p104-gen.XXXXXX)
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
  cp "$S/$f" "$T/$f"
done
( cd "$T" && patch -p1 < "$P" )         # .rej hunks must be re-applied by hand
```

Then rebuild the three per-file diffs and refresh the stored sources:

```bash
diff -u --label a/nvidia/nv-pci.c     --label b/nvidia/nv-pci.c     "$S/nvidia/nv-pci.c"     "$T/nvidia/nv-pci.c"     > diffs/p1-part1.diff || true
diff -u --label a/nvidia/nv.c         --label b/nvidia/nv.c         "$S/nvidia/nv.c"         "$T/nvidia/nv.c"         > diffs/p1-part2.diff || true
diff -u --label a/common/inc/nv-pci.h --label b/common/inc/nv-pci.h "$S/common/inc/nv-pci.h" "$T/common/inc/nv-pci.h" > diffs/p1-part3.diff || true
cat diffs/p1-part1.diff diffs/p1-part2.diff diffs/p1-part3.diff > p104-gen2.patch
```

Refresh `source/patched/` from `$T`, `source/pristine/` from `$S`, update the
checksums in [`README.md`](README.md), then bump the package in lockstep:
`../deb/REBUILD.md` ("Bumping the driver version") lists every place that
mentions the version.

Do not regenerate from a tree that was patched by hand. With the package in use
the driver tree is always pristine; compare the file with its `.bak`:

```bash
cmp /usr/src/nvidia-srv-<ver>/nvidia/nv-pci.c \
    /usr/src/nvidia-srv-<ver>/nvidia/nv-pci.c.bak
```

---

## 13. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `LnkCap` stays 2.5 GT/s after `mmio_test apply` | wrong BDF, or BAR0 not decoding | dump must not be all `0xFFFFFFFF`; check `lspci -nn -d 10de:1b87` |
| Link reaches 5 GT/s, then reverts within seconds | RM re-asserts Gen1 once the link goes quiet (§11.2) | watchdog (§6.2) |
| Every `nvidia-smi` re-inits the adapter | persistence mode disabled | systemd drop-in (§7) |
| Hook logs `LNKSTA=0x1041` right after `rm_init_adapter` | first retrain only latches `LINK_CONFIG_0` | 6 attempts, rewrite BAR0, 60 ms settle |
| Gen1 window still ~0.5 s after the faster watchdog | 250 ms tick + latch/train double retrain | expected; see §11.3 |
| `dkms build` says the module is already built | existing build for that kernel | `--force` |
| Patch not visible in `/var/lib/dkms/.../build` | DKMS 3.2.2 builds in a temp dir | `strings` the installed `.ko.zst` |
| `modprobe -r nvidia` fails | dependents or open fds | stop persistenced, remove `nvidia_uvm nvidia_drm nvidia_modeset` first, `fuser -v /dev/nvidia*` |
| `systemctl enable nvidia-persistenced` fails | static unit | use the drop-in; the device unit starts it |
| `dkms build` fails | missing headers/toolchain, or a real error | read `/var/lib/dkms/.../log/make.log`; do not patch around it |
| Registry keys have no effect | parsed but inert on GP104 (§11.2) | watchdog is required |

If the PCIe link wedges (device disappears, AER storm), do **not** try to
recover in place: power off (cold boot), restore backups from
`/root/p104-backup/`, rebuild the stock module, then boot.

---

## 14. Related documents

- [`README.md`](README.md) — human overview of this directory, the three paths,
  and how `patch/` relates to `deb/`.
- [`../deb/readme.txt`](../deb/readme.txt) — end-user install/remove notes,
  including the pinned driver version and Secure Boot.
- [`../deb/REBUILD.md`](../deb/REBUILD.md) — task prompt for rebuilding the
  `.deb`; use this instead of Phases C–G when you want the packaged result.
- [`../AGENTS.md`](../AGENTS.md) — repository-wide rules: authoritative
  artefacts, version lockstep, and the consistency checks before "done".
- [`../NOTICE`](../NOTICE) — licensing of the stored NVIDIA sources and of the
  diff context.
