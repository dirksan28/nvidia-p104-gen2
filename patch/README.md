# patch/ — sources and tooling for the P104-100 Gen2 unlock

Driver: `nvidia-srv` 580.178.04 (`nvidia-dkms-580-server`
580.178.04-0ubuntu0.26.04.1), kernel 7.0.0-43-generic.
Device: `10de:1b87` at `01:00.0`, root port `00:01.0`.

Everything here is self-consistent: applying `p104-gen2.patch` to
`source/pristine/` reproduces `source/patched/` byte for byte.

All commands in this file are run from the **repository root** unless a `cd`
line says otherwise. Adjust kernel version, driver version and BDF if your
machine differs.

## Contents

| Path | What it is |
|---|---|
| `p104-gen2.patch` | **Canonical patch.** 286-line unified diff, `a/`–`b/` prefixes, applies with `patch -p1` from the driver source root. This is the file shipped inside the .deb. |
| `final.patch` | The same change expressed as `x.c.bak` → `x.c` (no `a/`/`b/` prefix), for applying to a tree that was edited by hand. Generated from the same pristine/patched sources, so it is byte-equivalent in content; not used by the package. |
| `diffs/p1-part{1,2,3}.diff` | The three per-file pieces that were concatenated into `p104-gen2.patch` (nv-pci.c, nv.c, nv-pci.h). |
| `source/pristine/` | The three driver files exactly as shipped by the driver package (taken from the `.bak` copies, which match `/root/p104-backup/`). |
| `source/patched/` | The same files with the patch applied — the state that was hand-built and validated on hardware. |
| `doTheGen2Patch.md` | Full reproduction guide: preflight, userspace pre-test, BAR0 register facts, the manual patch procedure, build/verify/rollback, troubleshooting, and §12 on the Debian package. Read this to understand *why* the code looks the way it does. |
| `tools/mmio_test.c` | Userspace BAR0 probe (patched `nv-pci.c` before it was patched). Writes `0x8C040` etc. through `/sys/bus/pci/devices/.../resource0` and retrains the link. This is the hard gate that proved the offsets before any kernel change. |
| `tools/linktest.sh` | Control experiment: shows `setpci` on config space alone cannot change the negotiated speed. |
| `tools/dump.sh` | Read-only baseline capture (lspci, sysfs, nvidia-smi, dmesg) into a timestamped directory. |
| `tools/rollback.sh` | Undo for the **manual** patch path: restores the `.bak` files and rebuilds the stock module. Not the package uninstall path (that is `dpkg -r`). |
| `tools/bwtest.cu` | CUDA bandwidth probe for the unlocked link: pinned host↔device `cudaMemcpy` in both directions, printed as MiB/s and GB/s. This is what proves the patch delivers Gen2 *throughput*, not just a 5 GT/s line in `lspci`. Needs `nvcc` and ~256 MiB of free VRAM. |

Not kept here, on purpose: the machine-specific stock capture and the DKMS build
logs from the reference run (`tools/dump.sh` and a normal DKMS build regenerate
them; `.gitignore` excludes `baseline/` and `logs/` if you create them), and the
staged `work/` scratch copies, which were byte-identical to `source/patched/`.
The values worth knowing from the stock state are quoted in `doTheGen2Patch.md`
§0 and §3.2: `LnkCap`/`LnkSta` at 2.5 GT/s x4, `current_link_speed` 2.5 GT/s,
`pcie.link.gen.current=1`.

## Preconditions for a replay

Everything here was verified on a reference test machine (Ubuntu 26.04,
2026-11-14). A replay on another machine needs the same stack; the one-shot
preflight at the end of this section shows what is missing before you start.

### Host and hardware

| Requirement | Value here | Notes |
|---|---|---|
| OS | Ubuntu 26.04 LTS | package names below are the 26.04 ones |
| Kernel + headers | `7.0.0-43-generic` / `linux-headers-7.0.0-43-generic` | headers must match the **running** kernel |
| GPU | `01:00.0`, `10de:1b87` (GP104 P104-100), BAR0 16 MB | the patch is a no-op for any other device ID |
| Upstream port | `00:01.0`, root port | a PCIe switch also works, but only the endpoint is retrained |
| Driver | `nvidia-dkms-580-server` 580.178.04, DKMS module name `nvidia-srv`, kernel module `nvidia.ko` | the patch is version-locked to 580.178.04 |
| Source tree | `/usr/src/nvidia-srv-580.178.04/` (120 MB) | must contain `dkms.conf` |
| GPU idle | no Xorg/Wayland/CUDA process holding `/dev/nvidia*` | otherwise the reload is skipped and a reboot is needed |
| Secure Boot | disabled, platform in Setup Mode | if enabled, DKMS-signed modules need MOK enrolment first |
| Disk | a few hundred MB free under `/var/lib/dkms` | DKMS copies the source and builds there; ~1 min per kernel |

### Packages

| Package | Version here | Needed for |
|---|---|---|
| `dkms` | 3.2.2-1ubuntu1 | building and registering the module |
| `build-essential` | 12.12ubuntu2.26.04.2 (gcc 4:15.2.0-5ubuntu1, make 4.4.1-3, binutils 2.46-3ubuntu2) | compiler, `make`, `ld` |
| `linux-headers-$(uname -r)` | 7.0.0-43.43 | kernel headers |
| `patch` | 2.8-2build1 | `patch -p1` (the .deb applies the patch this way) |
| `pciutils` | 1:3.14.0-1build2 | `lspci`, `setpci` (status checks, pre-test) |
| `zstd` | 1.5.7+dfsg-3 | inspecting the installed `nvidia.ko.zst` |
| `kmod` | 34.2-2ubuntu2 | `modprobe`, `depmod` |
| `psmisc` | 23.7-2ubuntu2 | `fuser` (the reload guard in postinst/postrm) |
| `mokutil` | 0.7.2-2 | `mokutil --sb-state` (informational) |
| `dracut` | 110-11ubuntu0.1 | provides `/usr/sbin/update-initramfs` here (`dpkg -S`) |
| `nvidia-dkms-580-server` | 580.178.04-0ubuntu0.26.04.1 | the driver being patched |

```bash
sudo apt install dkms build-essential linux-headers-$(uname -r) \
                 patch pciutils zstd kmod psmisc mokutil
# only if no initramfs generator is present (here dracut already provides it):
sudo apt install dracut          # or initramfs-tools-core
```

`initramfs-tools-core` 0.151ubuntu1 is also installed here, but
`/usr/sbin/update-initramfs` belongs to **dracut** on this image — which is why
the package depends on `initramfs-tools-core | initramfs-tools | dracut` and
probes the tool at runtime instead of assuming one.

### Passwordless root

The procedure assumes non-interactive root, because several commands and two of
the tools use `sudo -n`:

* `tools/linktest.sh` and `tools/dump.sh` call `sudo -n lspci` / `sudo -n dmesg`
  (a password prompt would corrupt their output and hang a non-tty run);
* every privileged step in `deb/REBUILD.md` is written as `sudo -n ...` so the
  procedure can be paste-run without a prompt. The commands in
  `doTheGen2Patch.md` use plain `sudo`, which is fine when a human is typing.

On the reference machine (`sudo-rs` 0.2.13-0ubuntu1.2) that is provided by a
dedicated sudoers drop-in owned by `root:root` with mode `0440`, containing a
single line like:

```
/etc/sudoers.d/99-p104:   youruser ALL=(root) NOPASSWD: ALL
```

The normal password-protected `(ALL : ALL) ALL` grant stays in place alongside
it. Reproduce it with:

```bash
echo "$USER ALL=(root) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-p104 >/dev/null
sudo chmod 0440 /etc/sudoers.d/99-p104
sudo visudo -c                                   # must print "parsed OK"
sudo -n true && echo "passwordless sudo ok"
```

Alternatives if you do not want a blanket NOPASSWD entry:

* run the whole procedure from a root shell (`sudo -i`) and drop the `sudo`
  prefix from every command — but `linktest.sh`/`dump.sh` still contain
  `sudo -n` internally, so run them as root and ignore those lines, or edit
  them;
* replace `sudo -n` with plain `sudo` in the tools if a human is present to
  type the password.

A blanket `NOPASSWD: ALL` entry is full root without a password: acceptable on a
dedicated test box like this one, not on a shared machine.

### One-shot preflight

```bash
chk() { printf '%-16s %s\n' "$1" "$2"; }
chk kernel      "$(uname -r)"
chk gpu         "$(lspci -nn -d 10de:1b87 | cut -d' ' -f1)"
chk driver-tree "$(ls -d /usr/src/nvidia-srv-580.178.04 2>/dev/null || echo MISSING)"
chk dkms        "$(dkms status 2>/dev/null | paste -sd' ' -)"
chk headers     "$(ls -d /usr/src/linux-headers-$(uname -r) 2>/dev/null || echo MISSING)"
chk toolchain   "$(for c in gcc make ld patch; do command -v $c >/dev/null || { echo "MISSING $c"; exit; }; done; echo ok)"
chk pciutils    "$(for c in lspci setpci zstd; do command -v $c >/dev/null || { echo "MISSING $c"; exit; }; done; echo ok)"
chk initramfs   "$(command -v update-initramfs || command -v dracut || echo MISSING)"
chk sudo-n      "$(sudo -n true 2>/dev/null && echo ok || echo 'FAIL, no passwordless sudo')"
chk secure-boot "$(mokutil --sb-state 2>/dev/null | head -1)"
chk gpu-holders "$(sudo -n fuser /dev/nvidia* 2>/dev/null | wc -l) pid(s)"
chk nvidia-mod  "$(awk '/^nvidia /{print $1}' /proc/modules)"
```

Expected on the reference host:

```
kernel           7.0.0-43-generic
gpu              01:00.0
driver-tree      /usr/src/nvidia-srv-580.178.04
dkms             nvidia-srv/580.178.04, 7.0.0-42-generic, x86_64: installed nvidia-srv/580.178.04, 7.0.0-43-generic, x86_64: installed
headers          /usr/src/linux-headers-7.0.0-43-generic
toolchain        ok
pciutils         ok
initramfs        /usr/sbin/update-initramfs
sudo-n           ok
secure-boot      SecureBoot disabled
gpu-holders      0 pid(s)
nvidia-mod       nvidia
```

A non-zero `gpu-holders` count is only a problem for the reload step: the module
will still build and install, but you must reboot (or stop the client) before
the link changes.

For the **package** there is one extra precondition — the driver must be exactly
580.178.04 — and `deb/readme.txt` has the end-user version of this list,
including the from-scratch driver installation. `deb/REBUILD.md` repeats the
checks and adds the install/remove verification.

## What the patch changes

| File | Change |
|---|---|
| `nvidia/nv-pci.c` | `nv_p104_write_bar0()`, `nv_force_p104_gen2()`; probe hook after `nv_check_and_exclude_gpu()`; 250 ms watchdog kthread `nv-p104-gen2-wd` started in probe and stopped on driver unregister |
| `nvidia/nv.c` | second hook in `nv_start_device()` immediately after `rm_init_adapter()` succeeds |
| `common/inc/nv-pci.h` | prototype for `nv_force_p104_gen2()` |

All code is scoped to `PCI_DEVICE_ID_NVIDIA_P104` (`10de:1b87`) and is a no-op
for every other device. Details and rationale are in `doTheGen2Patch.md` §1 and
§5.

### Measured behaviour

| Condition | Gen2 time | Gen1 window |
|---|---|---|
| Idle (no CUDA client) | ~100 % | none |
| Chat workload, 1 request / 2.5 s, 250 ms watchdog | 79 % of wall, 76 % of busy | 0.22 s median |
| Same workload, original 1 s watchdog | 71 % of wall, 67 % of busy | 0.75 s median |

The RM re-asserts Gen1 about 0.25 s into each burst of work; there is no way to
disable that on GP104 (see `doTheGen2Patch.md` §1.2), so the watchdog can only
make the exposure short. `NV_P104_GEN2_TICK_MS` is the tuning knob.

Throughput of the link itself, measured with `tools/bwtest.cu` while sampling
`current_link_speed` at 50 ms (all samples 5.0 GT/s):

```
H2D:   2048 MiB in 1409.3 ms ->  1453 MiB/s (1.52 GB/s)
D2H:   2048 MiB in 1332.6 ms ->  1537 MiB/s (1.61 GB/s)
```

That is ~90 % of the Gen2 x4 payload ceiling (~1.7 GB/s); the stock Gen1 link
measures roughly half. Note that an LLM inference workload moves only tens of
MiB/s over PCIe, so `nvidia-smi`/`nvtop` will *not* show these numbers while
serving requests — only model load or an explicit large copy does.

## Verify the tree is intact

```bash
cd patch
md5sum source/pristine/nvidia/nv-pci.c            # 0689a6dbf6302996a16b8ca2aff3d4d3
md5sum source/pristine/nvidia/nv.c                # 568638d4618f89c5cd2b4c3667c831c9
md5sum source/pristine/common/inc/nv-pci.h        # ee89eba3a4470938b78c2068dc64b5cd
md5sum p104-gen2.patch                            # c85f1be347eafecc18bb855b17bb1f26
```

## Apply the patch to a scratch copy

```bash
cd patch
P=$PWD/p104-gen2.patch
T=$(mktemp -d "${TMPDIR:-/tmp}/p104-check.XXXXXX")
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cp source/pristine/$f "$T/$f"
done
( cd "$T" && patch -p1 --dry-run < "$P" )
```

Expected: `checking file ...` three times, exit status 0. Applying it for real
(`patch -p1 < ...`) must then make the three files identical to
`source/patched/`:

```bash
cmp "$T/nvidia/nv-pci.c"            source/patched/nvidia/nv-pci.c
cmp "$T/nvidia/nv.c"                source/patched/nvidia/nv.c
cmp "$T/common/inc/nv-pci.h"        source/patched/common/inc/nv-pci.h
```

## Build and run the pre-test tool

```bash
cd patch
mkdir -p /tmp/p104-gen2
gcc -O2 -Wall -Wextra -o /tmp/p104-gen2/mmio_test tools/mmio_test.c
sudo /tmp/p104-gen2/mmio_test dump        # read-only
sudo /tmp/p104-gen2/mmio_test apply       # writes BAR0, then re-dumps
```

The pre-test is only meaningful on a **stock** driver instance (the patched
module already runs at 5 GT/s, which hides the effect). `doTheGen2Patch.md` §3
is the full procedure and the hard gate.

## Regenerating the patch

If the driver version changes, the three hunks may still apply with offsets, or
may need adjusting where the RM code moved. Rebase them against the new tree:

```bash
cd patch
S=/usr/src/nvidia-srv-<newver>      # confirm with: ls -d /usr/src/nvidia-srv-*
P=$PWD/p104-gen2.patch
T=$(mktemp -d "${TMPDIR:-/tmp}/p104-gen.XXXXXX")
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cp "$S/$f" "$T/$f"                        # pristine, from the new driver
done
( cd "$T" && patch -p1 < "$P" )
# rejected hunks (.rej) must be re-applied by hand, following doTheGen2Patch.md §5
```

Then regenerate the `a/`–`b/` diff from the new pristine files to the rebased
ones:

```bash
diff -u --label a/nvidia/nv-pci.c     --label b/nvidia/nv-pci.c     "$S/nvidia/nv-pci.c"     "$T/nvidia/nv-pci.c"     > diffs/p1-part1.diff || true
diff -u --label a/nvidia/nv.c         --label b/nvidia/nv.c         "$S/nvidia/nv.c"         "$T/nvidia/nv.c"         > diffs/p1-part2.diff || true
diff -u --label a/common/inc/nv-pci.h --label b/common/inc/nv-pci.h "$S/common/inc/nv-pci.h" "$T/common/inc/nv-pci.h" > diffs/p1-part3.diff || true
cat diffs/p1-part1.diff diffs/p1-part2.diff diffs/p1-part3.diff > p104-gen2.patch
```

Refresh the stored sources, repeat the dry-run/`cmp` checks above, then follow
`../deb/REBUILD.md` for the lockstep version bump and the install test:

```bash
cp "$T/nvidia/nv-pci.c"     source/patched/nvidia/nv-pci.c
cp "$T/nvidia/nv.c"         source/patched/nvidia/nv.c
cp "$T/common/inc/nv-pci.h" source/patched/common/inc/nv-pci.h
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do cp "$S/$f" source/pristine/$f; done
```

Do not regenerate from `/usr/src` directly if that tree is patched by hand:
check first with
`cmp /usr/src/nvidia-srv-<ver>/nvidia/nv-pci.c /usr/src/nvidia-srv-<ver>/nvidia/nv-pci.c.bak`.
With the `.deb` in use the tree is always pristine.

## Why the register writes live in the module

`LnkCap` cannot be changed through PCIe config space; the 2.5 GT/s ceiling comes
from the GPU's XVE/XP_PL blocks in BAR0 (`0x8C040` LINK_CONFIG_0, `0x8C1C0`
NV_XP_PL_LCTRL_2 and neighbours). The userspace pre-test (`tools/mmio_test.c`)
proves those writes work, but the Resource Manager rewrites the register on
every adapter init and again when the link idles, so the fix has to live in the
kernel module, with a hook per `rm_init_adapter()` and a watchdog. The complete
reasoning, including the registry keys that were tried and do not work on
580.178.04, is in `doTheGen2Patch.md` §1.
