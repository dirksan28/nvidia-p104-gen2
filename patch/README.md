# patch/ — sources and tooling for the P104-100 Gen2 unlock

This directory holds the kernel change that lifts the P104-100 (`10de:1b87`)
from PCIe Gen1 (2.5 GT/s) to Gen2 (5.0 GT/s x4), together with the files it was
derived from, the tools used to prove the register offsets, and a task prompt
that walks an agent — or a human — through applying it.

Verified against `nvidia-srv` 580.178.04 on Ubuntu 26.04, kernel
`7.0.0-43-generic`.

## Choose your path

| I want to… | Start here |
|---|---|
| install the finished package | [`../deb/readme.txt`](../deb/readme.txt), or the [GitHub release](https://github.com/dirksan28/nvidia-p104-gen2/releases/latest) |
| rebuild the `.deb` | [`../deb/REBUILD.md`](../deb/REBUILD.md) |
| apply the patch by hand, or hand the job to a coding agent | [`AGENT_PROMPT.md`](AGENT_PROMPT.md) |
| understand why the code looks like this | [`AGENT_PROMPT.md` §11](AGENT_PROMPT.md#11-background-register-facts-rm-behaviour-measurements) |
| rebase the patch onto another driver version | [`AGENT_PROMPT.md` §12](AGENT_PROMPT.md#12-rebasing-for-another-driver-version) |
| check that this directory is intact | *Verify the tree*, below |

## What is here

| Path | Contents |
|---|---|
| `AGENT_PROMPT.md` | The task prompt: phases A–H, expected output, gates, rollback, report template, plus the register facts and measured behaviour. Self-contained apart from the tool sources and the patch file. |
| `p104-gen2.patch` | **Canonical change** (286 lines, `a/`–`b/` prefixes, `patch -p1`). This is the file shipped inside the `.deb`. |
| `final.patch` | The same change as `.bak` → file (no prefixes), for a tree edited by hand. Generated from the same sources. |
| `diffs/p1-part{1,2,3}.diff` | The three per-file pieces concatenated into `p104-gen2.patch`. |
| `source/pristine/` | The three 580.178.04 driver files exactly as shipped. |
| `source/patched/` | The same files with the patch applied — the state validated on hardware. |
| `tools/mmio_test.c` | Userspace BAR0 probe: read-only dump or one-shot write + retrain. This proved the offsets before any kernel code existed. |
| `tools/linktest.sh` | Control experiment: shows config-space writes alone cannot raise the link. |
| `tools/dump.sh` | Read-only baseline capture (lspci, sysfs, nvidia-smi, dmesg). |
| `tools/rollback.sh` | Undo for the manual path: restore `.bak` files and rebuild the stock module. |
| `tools/bwtest.cu` | CUDA bandwidth probe for the unlocked link, in both directions. |

The three driver files are stored for review and diffing only. The NVIDIA
driver itself is not distributed here — see [`../NOTICE`](../NOTICE).

## Using `AGENT_PROMPT.md`

The prompt is written to be *executed*, not skimmed. It starts with the
input-collection and branch table, then runs:

**preflight → userspace gate → backups → patch → build/install → verify →
rollback → report.**

- **With an agent:** give it the repository and point it at
  `patch/AGENT_PROMPT.md`. It is expected to stop at the first failed gate and
  to ask before the two irreversible steps: writing BAR0 (Phase B) and
  reloading the module (Phase E). Ask it to report using §10.
- **By hand:** work through the same phases. Every command is copy-paste; the
  expected output is written next to it. The userspace pre-test in Phase B is
  the hard gate — if that does not reach 5 GT/s, stop; do not patch the kernel.
- **Just the facts:** §11 collects the register map, why the Resource Manager
  re-asserts Gen1, the registry keys that were tested and do nothing, and the
  measured Gen2/Gen1 duty and bandwidth.

The prompt ends at a verified running module. Packaging that result is
`../deb/REBUILD.md`, and installing it is `../deb/readme.txt`.

## Doing it by hand

Follow `AGENT_PROMPT.md` Phases A–H. The short version: back up the three
files under `/usr/src/nvidia-srv-580.178.04`, apply `p104-gen2.patch`, build
and install with DKMS, install the `nvidia-persistenced` persistence drop-in,
reload, then verify `LnkSta: Speed 5GT/s, Width x4`. Do not skip Phase B, and
do not hand-edit anything if the `.deb` is installed — the package relies on
the driver tree staying pristine.

## How this connects to `deb/`

`p104-gen2.patch` is the source of truth. `deb/` packages that same patch so it
is applied automatically:

```
                   patch/p104-gen2.patch
                      │             │
       manual path    │             │    package path
       (AGENT_PROMPT) │             │    (deb/packaging)
                      ▼             ▼
        /usr/src/nvidia-srv-…   DKMS override PATCH[2]
        edit + dkms build       + maintainer scripts
                      │             │
                      ▼             ▼
              nvidia.ko (one host)  nvidia-srv-p104-gen2_*.deb
```

| | Manual (`AGENT_PROMPT.md`) | Package (`deb/`) |
|---|---|---|
| Applies to | one machine, one kernel at a time | any kernel the driver supports, rebuilt by DKMS |
| Driver tree | edited in place, with `.bak` backups | stays pristine; patch applied to DKMS's private copy |
| Kernel upgrades | rebuild by hand | automatic (`AUTOINSTALL=yes`) |
| Removal | restore backups, rebuild | `dpkg -r nvidia-srv-p104-gen2` |
| Driver version | you rebase the patch | locked by the package version and `Depends` |

Both paths are locked to driver 580.178.04 and share the same three hooks. A
version bump has to touch both — `../deb/REBUILD.md` lists the packaging side,
`AGENT_PROMPT.md` §12 the patch side.

## Before you start

You need the stock DKMS driver and its source tree (`nvidia-dkms-580-server`
580.178.04, `/usr/src/nvidia-srv-580.178.04`), matching kernel headers, and an
idle GPU for the reload. Secure Boot must be off or a MOK enrolled. Full
prerequisites: `AGENT_PROMPT.md` §2–§3 and `../deb/readme.txt`.

## Verify the tree

```bash
cd patch
md5sum source/pristine/nvidia/nv-pci.c          # 0689a6dbf6302996a16b8ca2aff3d4d3
md5sum source/pristine/nvidia/nv.c              # 568638d4618f89c5cd2b4c3667c831c9
md5sum source/pristine/common/inc/nv-pci.h      # ee89eba3a4470938b78c2068dc64b5cd
md5sum p104-gen2.patch                          # c85f1be347eafecc18bb855b17bb1f26
```

Applying the patch to a scratch copy must reproduce `source/patched/` byte for
byte:

```bash
P=$PWD/p104-gen2.patch
T=$(mktemp -d /tmp/p104-check.XXXXXX)
mkdir -p "$T/nvidia" "$T/common/inc"
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cp "source/pristine/$f" "$T/$f"
done
( cd "$T" && patch -p1 < "$P" ) || exit 1
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    cmp "$T/$f" "source/patched/$f"
done
```

Regenerate `final.patch` from the stored sources (never hand-edit it):

```bash
cd patch
for f in nvidia/nv-pci.c nvidia/nv.c common/inc/nv-pci.h; do
    diff -u --label "$f.bak" --label "$f" "source/pristine/$f" "source/patched/$f"
done > final.patch || true          # diff exits 1 when the files differ
```

## Changing this directory

Read [`../AGENTS.md`](../AGENTS.md) first. It defines which artefact wins, the
version lockstep, and the checks that must pass before a change is done.
