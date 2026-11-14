# Task prompt: rebuild `nvidia-srv-p104-gen2`

You are rebuilding the Debian package that unlocks PCIe Gen2 x4 on an NVIDIA
P104-100 (`10de:1b87`) by patching the DKMS NVIDIA module at build time.

Target: a `.deb` that installs over the stock `nvidia-dkms-580-server`
580.178.04 driver, survives kernel upgrades, and can be removed cleanly with
`dpkg -r`. The host must be left **patched and verified** at the end.

Everything you need is in this directory. Do not invent paths, versions or
register offsets — read them from the files and from the system.

```
deb/
├── readme.txt                 end-user install/deinstall notes (also the
│                              source for usr/share/doc/.../README)
├── REBUILD.md                 this file
├── nvidia-srv-p104-gen2_580.178.04-1_all.deb    build output (git-ignored)
└── packaging/                 dpkg tree; this is what you build from
    ├── DEBIAN/{control,postinst,prerm,postrm}
    ├── etc/dkms/nvidia-srv-580.178.04.conf
    ├── etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf
    ├── usr/share/doc/nvidia-srv-p104-gen2/README
    └── usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
```

The kernel patch itself, its pristine and patched sources, the pre-test tools
and the full rationale live one level up in `../patch/` (see
`../patch/README.md`). The canonical patch is `../patch/p104-gen2.patch`.

Paths below are relative to the repository root; `deb/` is this directory. Use
`/tmp/p104-gen2/` for scratch work if you need it.

## Hard rules

1. **Never edit `/usr/src/nvidia-srv-*/nvidia/*.c`.** The patch is applied to
   DKMS's private build copy only. After any install/removal,
   `dpkg -V nvidia-dkms-580-server` must print nothing.
2. **Keep the DKMS patch index at `PATCH[2]`.** DKMS 3.2.2 iterates
   `for ((i=0; i < ${#PATCH[@]}; i++))`, so a sparse index such as `PATCH[3]`
   is silently ignored. Stock defines `PATCH[0]` and `PATCH[1]`.
3. **Version lockstep.** `580.178.04` appears in more than one place; see
   "Bumping the driver version" before changing any of it.
4. **Verify, never assume.** The maintainer script must abort if the built
   module does not contain the `P104-100:` marker, and you must independently
   confirm `/sys` + `lspci` after installing.
5. **Leave the host working.** After the removal test, reinstall the package
   and confirm 5 GT/s again. Do not leave the machine with a stock module
   unless the user asked for it.
6. If `dkms build` fails, read
   `/var/lib/dkms/nvidia-srv/<ver>/<krel>/*/log/make.log`, fix the cause or
   restore the previous package state. Never ship an unverified `.deb`.
7. Do not unload the NVIDIA modules while Xorg, Wayland or a CUDA process is
   running. The scripts check for this; do not bypass the check.

## Step 0 — preflight

```bash
uname -r                                     # 7.0.0-43-generic
dpkg -l nvidia-dkms-580-server | tail -1     # 580.178.04-0ubuntu0.26.04.1
ls -d /usr/src/nvidia-srv-*/                 # must include ...-580.178.04
dkms status                                  # nvidia-srv/580.178.04, <krel>, x86_64: installed
ls -d /usr/src/linux-headers-$(uname -r)     # kernel headers present
lspci -nn -d 10de:1b87                       # the card
sudo -n true && echo sudo-ok
bash -n packaging/DEBIAN/postinst && bash -n packaging/DEBIAN/postrm \
  && bash -n packaging/DEBIAN/prerm && echo scripts-parse
```

If any of these fail, stop and report. If the target machine has no NVIDIA
driver at all, follow "FROM ZERO" in `readme.txt` first.

## Step 1 — confirm the patch is still the validated one

```bash
cd deb
md5sum ../patch/p104-gen2.patch packaging/usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
```

The two must be identical. If they differ, the packaged copy is stale — replace
it from `../patch/p104-gen2.patch` (Step 3). Stay in `deb/` for the rest of the
procedure.

## Step 2 — prove the patch applies to a pristine tree

```bash
T=$(mktemp -d "${TMPDIR:-/tmp}/p104-check.XXXXXX")
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cp ../patch/source/pristine/$f "$T/$f"
done
( cd "$T" && patch -p1 --dry-run < ../patch/p104-gen2.patch )   # exit 0
( cd "$T" && patch -p1           < ../patch/p104-gen2.patch )
cmp "$T/nvidia/nv-pci.c"            ../patch/source/patched/nvidia/nv-pci.c
cmp "$T/nvidia/nv.c"                ../patch/source/patched/nvidia/nv.c
cmp "$T/common/inc/nv-pci.h"        ../patch/source/patched/common/inc/nv-pci.h
```

Any fuzz, offset or `cmp` mismatch means the patch and the sources have
diverged: fix that before building a package.

## Step 3 — sync the patch and the README into the packaging tree

```bash
cp ../patch/p104-gen2.patch \
   packaging/usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
cp readme.txt packaging/usr/share/doc/nvidia-srv-p104-gen2/README
```

`readme.txt` is the single source for the shipped documentation; the copy under
`usr/share/doc/` must be identical (Step 5 verifies it).

The patch directory name must match the installed source tree (`ls -d /usr/src/nvidia-srv-*`)
and the override filename (`/etc/dkms/nvidia-srv-<VER>.conf`) must match the
DKMS module name and version, because DKMS only sources the override when both
agree.

Check the override still reads exactly:

```
PATCH[2]="p104-gen2.patch"
```

## Step 4 — static checks on the package metadata

```bash
sed -n '1,20p' packaging/DEBIAN/control
```

Expected, and all of it matters:

* `Package: nvidia-srv-p104-gen2`, `Architecture: all`
* `Version: 580.178.04-1`
* `Depends: nvidia-dkms-580-server (>= 580.178.04), nvidia-dkms-580-server (<< 580.178.05), dkms, initramfs-tools-core | initramfs-tools | dracut`
  — **do not depend on `initramfs-tools` alone**: this host uses `dracut`, and a
  hard dependency on `initramfs-tools` makes `dpkg -i` fail before anything runs.
  The upper bound is equally load-bearing: with `>=` alone, apt can upgrade to
  580.190, where the version-named DKMS override no longer matches and the
  patch silently stops being applied. The range accepts any packaging revision
  of upstream 580.178.04 but no later driver.
* No `Pre-Depends`, no maintainer scripts other than `postinst`/`prerm`/`postrm`.

Also confirm:

```bash
grep -n 'PATCH\[' packaging/etc/dkms/nvidia-srv-580.178.04.conf
grep -n 'VER=' packaging/DEBIAN/postinst packaging/DEBIAN/postrm
grep -n 'P104-100:' packaging/DEBIAN/postinst        # the abort check must exist
grep -n 'persistence-mode' packaging/etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf
```

`postinst` must, in this order: `dkms build --force` → `dkms install --force` →
verify `/lib/modules/$KREL/updates/dkms/nvidia.ko.zst` contains `P104-100:` and
abort if not → `update-initramfs` → reload the driver only after stopping
`nvidia-persistenced` and only if `fuser /dev/nvidia*` is clean.

`postrm` must rebuild **and reinstall** the stock module, because dpkg has
already deleted the override and the patch file by the time it runs.

## Step 5 — build

Still in `deb/` from Step 1:

```bash
dpkg-deb --build --root-owner-group packaging \
          nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

In a fresh clone there is no pre-existing `.deb`: it is a build output and
`.gitignore` excludes it. The checks below are about *content*, so they work
with or without a reference copy.
Expect exit 0 and a `building package ...` line; the file is about 10 KB (it
tracks the size of `readme.txt`). `dpkg-deb` is **not** bit-reproducible (ar
member timestamps), so do not certify the build by md5 against any earlier
`.deb`. Compare content instead:

```bash
dpkg-deb -c nvidia-srv-p104-gen2_580.178.04-1_all.deb
dpkg-deb -I nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

The payload must be exactly: `DEBIAN/control` and the three maintainer scripts,
the two `etc/` files, the doc `README` and `copyright`, and the patch — nothing
else (no `.bak`, no editor backups, no packaging notes).

Then confirm the packaged README is the same file users read, and that the
packaged patch is the canonical one:

```bash
dpkg-deb --fsys-tarfile nvidia-srv-p104-gen2_580.178.04-1_all.deb | \
  tar -xO ./usr/share/doc/nvidia-srv-p104-gen2/README | cmp - readme.txt
dpkg-deb --fsys-tarfile nvidia-srv-p104-gen2_580.178.04-1_all.deb | \
  tar -xO ./usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch | \
  cmp - ../patch/p104-gen2.patch
```

## Step 6 — install test

Retesting over an existing install is fine and is the normal path: `dpkg -i`
re-runs `postinst`.

```bash
sudo -n dpkg -i nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

Expected lines (order may vary slightly):

```
nvidia-srv-p104-gen2: building patched module for kernel <krel> ...
Applying patch p104-gen2.patch... done.
nvidia-srv-p104-gen2: patched module installed.
update-initramfs: Generating /boot/initrd.img-<krel>
nvidia-srv-p104-gen2: NVIDIA modules reloaded with the patch.
```

If instead you see

```
nvidia-srv-p104-gen2: ERROR: installed module does not contain the P104-100 code
```

the patch did not reach the compiler. Do not ignore it. Check, in this order:
`grep -n 'Applying patch' /var/lib/dkms/nvidia-srv/580.178.04/<krel>/*/log/make.log`,
the override filename vs `ls -d /usr/src/nvidia-srv-*`, and the `PATCH[2]`
index. See the triage table.

Then verify the running system:

```bash
sudo -n lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
#   LnkCap ... Speed 5GT/s, Width x4
#   LnkSta ... Speed 5GT/s, Width x4

nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv,noheader
#   Enabled, 2

sudo -n dmesg | grep 'P104-100:' | tail -2
#   ... P104-100: PCIe Gen2 unlock applied, LNKSTA=0x1042 (Speed=2, Width=x4)

ps -eo comm | grep nv-p104-gen2-wd          # watchdog thread present
zstd -dc /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | strings | grep -c 'P104-100:'
#   >= 1
sudo -n dkms status | grep 580.178.04        # installed
dpkg -V nvidia-dkms-580-server               # empty output
```

If the postinst reported `GPU device nodes are in use; not reloading the
driver`, the on-disk module is patched but the running one is not: either
reboot or unload/reload manually once nothing holds `/dev/nvidia*`.

## Step 7 — removal test

```bash
sudo -n dpkg -r nvidia-srv-p104-gen2
```

Expected: `rebuilding stock module ...`, `dkms build/install`, `depmod`,
`update-initramfs`, then `nvidia-srv-p104-gen2: stock module restored.`

Verify the revert:

```bash
dpkg -l nvidia-srv-p104-gen2 | grep -c '^ii'                 # 0
ls /etc/dkms/nvidia-srv-580.178.04.conf \
   /usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch \
   /etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf
#   all three: No such file or directory
zstd -dc /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | strings | grep -c 'P104-100:'
#   0
sudo -n lspci -s 01:00.0 -vv | grep LnkSta:                  # Speed 2.5GT/s, Width x4
nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv,noheader
#   Disabled, 1
```

`LnkCap` may keep reporting 5 GT/s until the next reboot: that bit lives in GPU
state, not in the module. `LnkSta` is authoritative. State this in your report
so it is not mistaken for a failed revert.

## Step 8 — reinstall and leave it patched

```bash
sudo -n dpkg -i nvidia-srv-p104-gen2_580.178.04-1_all.deb
sudo -n lspci -s 01:00.0 -vv | grep LnkSta:                  # 5GT/s, x4
nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv,noheader
#   Enabled, 2
```

## Step 9 — report

State: package version and size, the payload check result, the three
maintainer-script syntax checks, the patch-apply dry run, the install/remove/
reinstall evidence with the commands and observed values above, and the final
link state. Report honestly if reload was skipped and a reboot is needed.

## Bumping the driver version

Do this when `nvidia-dkms-580-server` moves (for example to 580.190.xx), or
when the Ubuntu package name changes (`nvidia-dkms-590-server`). Everything
below must end up consistent, or the patch silently stops being applied:

```bash
cd ..            # repository root
grep -rn '580\.178\.04' deb/packaging deb/readme.txt | cut -d: -f1 | sort -u
```

Expected places to touch:

| Place | Change |
|---|---|
| `deb/packaging/DEBIAN/control` | `Version`, both `Depends` bounds on `nvidia-dkms-<newmajor>-server` (`>= <newver>`, `<< <next upstream version>`), description text that names the override path |
| `deb/packaging/DEBIAN/postinst` | `VER=<newver>` (and `MOD=` if the DKMS module name changed) |
| `deb/packaging/DEBIAN/postrm` | same `VER=` |
| `deb/packaging/etc/dkms/nvidia-srv-<newver>.conf` | rename the file; update the comment that explains the index |
| `deb/packaging/usr/src/nvidia-srv-<newver>/patches/` | rename the directory |
| `deb/packaging/usr/share/doc/nvidia-srv-p104-gen2/README` | paths/version in the text |
| `deb/readme.txt` | paths/version in the text |
| `deb/nvidia-srv-p104-gen2_<newver>-1_all.deb` | output filename |
| `../patch/*` | regenerate the patch against the new source tree (`../patch/AGENT_PROMPT.md` §12) |

Then rerun Steps 2–9. `SRC=/usr/src/$MOD-$VER` in both scripts derives the
source path automatically, so only `MOD`/`VER` need editing.

## Triage

| Symptom | Cause | Fix |
|---|---|---|
| `dpkg: dependency problems ... initramfs-tools` | `Depends` names `initramfs-tools` only | use the alternative list `initramfs-tools-core \| initramfs-tools \| dracut` |
| Build succeeds, no `Applying patch` line, module lacks `P104-100:` | override file name does not match `nvidia-srv-<ver>`, or patch file is not in `<src>/patches/` | fix filename / copy the patch |
| `Applying patch` present but marker missing | patch applied to a tree, but code compiled out / wrong file | inspect `make.log`, confirm the hook landed in `nv-pci.c` |
| Patch fails with fuzz/offset | driver version differs from the patch | regenerate the patch against the new tree |
| `ERROR: installed module does not contain the P104-100 code` | verification caught the above **after** `dkms install` | fix, rerun `dpkg -i`; the stock module is what is currently installed |
| Install works but link stays 2.5 GT/s | running module is stale, or persistenced drop-in not applied | `systemctl cat nvidia-persistenced.service`, check for `--persistence-mode`; reboot if reload was skipped |
| `GPU device nodes are in use` on install | a process holds `/dev/nvidia*` (CUDA, X, or persistenced if the stop failed) | stop the user, or reboot; the module on disk is already correct |
| `dkms build FAILED` | missing headers/toolchain or a real compile error | read `/var/lib/dkms/.../log/make.log`; do not patch around it |
| Removal leaves the link at 5 GT/s | running module was not reloaded | unload/reload or reboot; the on-disk module is stock |
