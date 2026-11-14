# AGENTS.md — working agreement for this repository

This file is for anyone (human or coding agent) changing this repository. It is
the short contract: what is authoritative, what must never be touched, and what
"done" means. The long-form rationale lives in the documents linked below; do
not duplicate it here, and do not contradict it.

## Read before editing

| Order | File | Why |
|---|---|---|
| 1 | `README.md` | What the project ships and the measured result it claims |
| 2 | `patch/README.md` | Tree invariants, checksums, tool index, measured behaviour |
| 3 | `patch/doTheGen2Patch.md` §1, §11 | Register facts, why the registry keys fail, why the code looks like this |
| 4 | `deb/REBUILD.md` | Step-by-step build/install/remove runbook — follow it, don't improvise |

`deb/REBUILD.md` is written as a task prompt and is the authority on packaging.
`patch/doTheGen2Patch.md` is the authority on hardware behaviour. If a change
makes either one wrong, update it in the same change.

## What is authoritative

| Artefact | Role |
|---|---|
| `patch/p104-gen2.patch` | **Canonical patch.** 286 lines, `a/`/`b/` prefixes, applies with `patch -p1` to the driver source root |
| `patch/source/patched/` | The three files exactly as validated on hardware; the patch must reproduce them byte for byte |
| `patch/source/pristine/` | Untouched 580.178.04 sources; the patch is anchored to these |
| `patch/final.patch` | Same change as `.bak` → file (`-p0`), for the manual procedure; must stay content-equivalent |
| `patch/diffs/p1-part{1,2,3}.diff` | Per-file pieces concatenated into the canonical patch |
| `deb/packaging/usr/src/.../patches/p104-gen2.patch` | Copy shipped in the `.deb`; must be identical to the canonical patch |
| `deb/readme.txt` | Single source for the shipped doc; `packaging/usr/share/doc/.../README` must be identical |
| `RELEASE_NOTES.md` | User-facing notes for one tagged release; mirrors the install/verify/remove facts in `deb/readme.txt`, so update both together and keep the version in lockstep |

## Hard rules

1. **Never edit `/usr/src/nvidia-srv-*/nvidia/*.c`** or anything else the driver
   package owns. The patch reaches DKMS's private build copy only. After any
   install or removal, `dpkg -V nvidia-dkms-580-server` and
   `dpkg -V nvidia-srv-p104-gen2` must both print nothing.
2. **Back up before touching anything under `/usr/src`** (`cp -a x x.bak`) if
   you are on the manual path, and restore the backups if the build fails. A
   zero-warning `dkms build` is required; on failure read
   `/var/lib/dkms/nvidia-srv/<ver>/<krel>/*/log/make.log` rather than patching
   around it.
3. **Do not unload the NVIDIA modules while Xorg, Wayland or a CUDA client
   holds `/dev/nvidia*`.** The maintainer scripts check with `fuser`; do not
   bypass that check. Stop the clients, reload, then restart them.
4. **The patch must apply with zero fuzz and reproduce `source/patched/`
   byte for byte.** Offsets, fuzz or a `cmp` mismatch mean the tree has
   diverged — fix that before building anything.
5. **Change one thing, change all of it.** A code edit is only half done until
   the canonical patch, `final.patch`, `diffs/`, the stored sources, the
   checksums in `patch/README.md`, the packaged copy and the rebuilt `.deb`
   agree. Partial updates are this repository's main failure mode.
6. **Version lockstep.** `580.178.04` appears in the package `Version`, both
   maintainer scripts, the DKMS override filename, the `usr/src` directory
   name, the `.deb` filename and the docs. Enumerate with
   `grep -rn --exclude='*.deb' '580\.178\.04' .` and update all of them
   together.
7. **Never ship NVIDIA sources.** Only the three patched files are stored, for
   review and diffing; the driver itself is not redistributed. See `NOTICE`.
8. **Keep the `P104-100:` marker strings intact.** The `postinst` abort check
   and the verification steps grep for them; renaming them silently defeats the
   "did the patch reach the compiler?" guard.
9. **Verify, don't assert.** Quote observed command output for any claim you
   make about build, install, link state or performance. Do not report a
   measurement you did not run.
10. **No host-specific detail in tracked files.** No hostnames, user names or
    absolute home paths. `/tmp/p104-gen2/` is the documented scratch location;
    the built `.deb` is `.gitignore`d.

## Consistency checks before saying "done"

Run from the repository root; every one of these must pass.

```bash
# 1. documented checksums match
md5sum patch/source/pristine/nvidia/nv-pci.c        # 0689a6dbf6302996a16b8ca2aff3d4d3
md5sum patch/source/pristine/nvidia/nv.c            # 568638d4618f89c5cd2b4c3667c831c9
md5sum patch/source/pristine/common/inc/nv-pci.h    # ee89eba3a4470938b78c2068dc64b5cd
md5sum patch/p104-gen2.patch                        # c85f1be347eafecc18bb855b17bb1f26

# 2. canonical patch applies and reproduces the stored sources
P=$PWD/patch/p104-gen2.patch
T=$(mktemp -d /tmp/p104-check.XXXXXX)
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cp "patch/source/pristine/$f" "$T/$f"
done
( cd "$T" && patch -p1 < "$P" ) || exit 1
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cmp "$T/$f" "patch/source/patched/$f"
done

# 3. repo and package agree (the .deb lines need a built package first)
cmp patch/p104-gen2.patch deb/packaging/usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
cmp deb/readme.txt deb/packaging/usr/share/doc/nvidia-srv-p104-gen2/README
dpkg-deb --fsys-tarfile deb/nvidia-srv-p104-gen2_580.178.04-1_all.deb |
    tar -xO ./usr/share/doc/nvidia-srv-p104-gen2/README | cmp - deb/readme.txt
bash -n deb/packaging/DEBIAN/postinst
bash -n deb/packaging/DEBIAN/postrm
bash -n deb/packaging/DEBIAN/prerm

# 4. host state after install
dpkg -V nvidia-srv-p104-gen2 && dpkg -V nvidia-dkms-580-server
zstd -dc /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | strings | grep -c 'P104-100:'
ps -eo comm | grep nv-p104-gen2-wd
cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed
```

Regenerating `final.patch` (after editing the stored sources) is a diff, not a
hand edit:

```bash
cd patch
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    diff -u --label "$f.bak" --label "$f" "source/pristine/$f" "source/patched/$f"
done > final.patch || true          # diff exits 1 when the files differ
```

## Build, install, remove

Follow `deb/REBUILD.md` steps 0–9. In short: build with
`dpkg-deb --build --root-owner-group packaging <name>.deb`, install with
`dpkg -i`, verify the link, `dpkg -r` to prove the revert, then reinstall and
leave the host patched. The package is not bit-reproducible (ar timestamps) —
compare payload content, never the `.deb` checksum. Before reinstalling, stop
every CUDA client (any container or process using the GPU, plus `nvtop`); the
`postinst` stops `nvidia-persistenced` itself. Restart the clients afterwards.

## Code conventions

- Kernel code in `nv-pci.c` is 4-space indented, NVIDIA style: `NvBool` /
  `NV_TRUE`, `nv_printf`, `IS_ERR`. All of it is scoped to
  `PCI_DEVICE_ID_NVIDIA_P104` and must be a no-op for any other device.
- Timing lives in `#define`s: `NV_P104_GEN2_TICK_MS` (250),
  `NV_P104_GEN2_SETTLE_MS` (10), `NV_P104_GEN2_SETTLE_TRIES` (6). 250 ms is the
  validated value; changing any of them requires re-running the load
  measurement and updating the "Measured behaviour" table in `patch/README.md`
  and the figures in `deb/readme.txt`.
- Do not replace the settle loop with a fixed `msleep`: the first retrain of a
  round only latches the register, so a second attempt is required. That is
  why the loop re-checks `LNKSTA` and retries.
- Error messages use the `NVRM:` prefix; watchdog/settle tracing uses
  `nv-p104-gen2:` so the `P104-100:` marker count stays stable.
- Docs are Markdown hard-wrapped near 80 columns (tables excepted), LF line
  endings, UTF-8 with `—`, `→` and `§` used as in the existing text. Keep the
  tone: state what was observed and how.

## Measurement notes

Any claim about link behaviour must come from a measurement that does not
perturb what it measures.

- Record `current_link_speed` from sysfs at ~100 ms; do not run NVML clients
  (`nvidia-smi`, `nvtop`) during the run — they re-initialise the adapter and
  change the result.
- `dmesg` correction lines are `pci_dbg`; enable them with
  `echo 'file nv-pci.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control`.
- A synthetic LLM load must use **unique prompts**. Identical prompts hit
  llama-server's prefix cache and will not reproduce the Gen1 flap.
- Gen1 windows under load are expected: the RM re-asserts Gen1 ~0.25 s into each
  burst and cannot be vetoed on GP104 (`doTheGen2Patch.md` §1.2). Do not "fix"
  this by adding registry parameters, clock locking or more retries — all were
  tested and are ineffective or unsupported.

## Reporting

State the files changed, the commands run and their observed output, the
`dpkg -V` result, the final link state, and whether the reload was skipped (in
which case a reboot is required). Be explicit when something was not verified.
