# nvidia-p104-gen2

A reproducible fix for the PCIe bandwidth limit on the NVIDIA P104-100 mining card, shipped as a small Debian package plus everything needed to rebuild it.
<br>
<img width="70%" alt="nvtop" src="https://github.com/user-attachments/assets/5fc025d4-07a3-4c11-8fcc-41651049fdaa" />
<br>
Unlocking PCIe Gen2 nearly doubles the PCIe bandwidth for:
* **Faster AI model loading**
* **Quicker data transfers**

While other solutions rely on separate background programs, manual boot scripts, or modifying closed-source driver files, this project takes a "set it and forget it" approach built straight into standard Ubuntu/Debian packaging:

* **Survives system and kernel updates:** Once installed, the fix automatically rebuilds itself whenever your Linux kernel updates—no manual re-applying required.
* **Works out of the box at boot:** Everything runs inside the standard NVIDIA driver itself, so there are no extra background apps to manage or custom startup scripts to maintain.
* **Safe and easy to undo:** It leaves your original NVIDIA driver files untouched and can be completely removed at any time with a single `dpkg -r` command.
* **Easy to update for newer drivers:** Everything needed to rebuild the package for future NVIDIA driver versions is included right in the repository.


## Introduction

**What it is.** A kernel-module patch, a `.deb` that installs it through DKMS,
and the sources, tools and documentation behind both. It does not replace or
redistribute the NVIDIA driver — it patches the driver you already have at
build time.

**What it does.** A P104-100 comes up at PCIe Gen1 (2.5 GT/s) even in a slot
that supports Gen2, because the GPU's BAR0 link registers advertise only
2.5 GT/s and the closed-source Resource Manager restores that state on every
adapter init. The patch re-declares 5.0 GT/s capability in those registers,
retrains the link (with retries, because the first retrain of each round only
latches the register), re-applies the unlock after each `rm_init_adapter()`,
and runs a 250 ms watchdog against the RM's downgrade — the RM re-asserts Gen1
as soon as the link goes quiet, so this has to be undone continuously. A
`nvidia-persistenced` drop-in keeps the adapter initialised so `nvidia-smi`
does not tear the link down. Result: `LnkSta: Speed 5GT/s, Width x4`, held
idly and recovered within ~0.2 s of each RM downgrade.

**Requirements.**

| | |
|---|---|
| OS | Ubuntu 26.04 LTS; developed and verified on kernel `7.0.0-43-generic` |
| Driver | `nvidia-dkms-580-server` exactly 580.178.04 (DKMS module `nvidia-srv`) |
| GPU | P104-100, PCI ID `10de:1b87`; slot/root port must support 5 GT/s (x4 here) |
| Build | kernel headers for the running kernel, `dkms`, gcc/make |
| Secure Boot | disabled, or a MOK enrolled so DKMS-signed modules load |
| GPU at install | idle (nothing holding `/dev/nvidia*`), otherwise one reboot |
| Privileges | root; non-interactive `sudo` expected by the tools and runbook |

Another driver version or another Pascal card means regenerating the patch and
rebuilding the package; the code is a no-op for any device other than
`10de:1b87`. Full prerequisites, including installing the stock driver from
scratch, are in `deb/readme.txt`.

**Why it is beneficial.** The unlock roughly doubles the host↔GPU link
bandwidth — PCIe Gen1 x4 is about 1 GB/s per direction, Gen2 x4 about 2 GB/s —
which helps model loading, PCIe transfers and small-batch inference on a card
that would otherwise leave half its slot bandwidth unused. It costs nothing in
hardware, leaves the stock driver package verifiable (`dpkg -V` stays clean),
survives kernel upgrades through DKMS, and reverts completely with
`sudo dpkg -r nvidia-srv-p104-gen2`. Measured with a chat-style CUDA load: the
link sits at Gen2 for 79 % of wall time and 76 % of busy time, with the
Resource Manager's Gen1 windows lasting 0.22 s (median); at idle it stays at
5 GT/s indefinitely.

## Getting started

The package patches the driver that is already installed; it is not a driver
replacement. Start by identifying your stack:

```bash
uname -r                                    # kernel and ABI
lspci -nn -d 10de:1b87                      # must print the P104-100
dpkg-query -W nvidia-dkms-580-server        # driver version
dkms status                                 # module registered?
ls -d /usr/src/nvidia-srv-* 2>/dev/null     # DKMS source tree present?
```

| You have | Do this |
|---|---|
| driver 580.178.04 and `/usr/src/nvidia-srv-580.178.04` | install the package, below |
| another driver version | don't install it — regenerate the patch against your tree: `deb/readme.txt` (*REBUILDING FOR A NEW DRIVER VERSION*) and `patch/AGENT_PROMPT.md` (*Rebasing for another driver version*) |
| no NVIDIA driver | install the pinned driver below, reboot, then install the package |

### Install the exact driver version

The patch is version-locked: the DKMS override is named after the module
version, and the diff is anchored to the 580.178.04 sources. Install that exact
version from the Ubuntu archive (skip this if `dpkg-query` already reports
`580.178.04-0ubuntu0.26.04.1`):

```bash
apt-cache policy nvidia-dkms-580-server    # must list 580.178.04-0ubuntu0.26.04.1
sudo apt-get install \
    nvidia-driver-580-server=580.178.04-0ubuntu0.26.04.1 \
    nvidia-dkms-580-server=580.178.04-0ubuntu0.26.04.1
sudo apt-mark hold nvidia-driver-580-server nvidia-dkms-580-server
sudo reboot
```

If the archive no longer carries 580.178.04, rebuild the package for the
version that is available rather than forcing an old driver. Likewise, if a
newer driver is already installed, do not downgrade it just to match this
package — rebuild the package instead. The hold stops an unattended upgrade
from silently disabling the patch; release it with `sudo apt-mark unhold ...`
before rebuilding for a newer driver.

### Install the package

From a release, download `nvidia-srv-p104-gen2_580.178.04-1_all.deb` from the
[Releases page](https://github.com/dirksan28/nvidia-p104-gen2/releases/latest),
then:

```bash
sudo apt install ./nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

From a clone, build it first:

```bash
sudo apt install dkms build-essential linux-headers-$(uname -r)
cd deb
dpkg-deb --build --root-owner-group packaging \
    nvidia-srv-p104-gen2_580.178.04-1_all.deb
sudo apt install ./nvidia-srv-p104-gen2_580.178.04-1_all.deb
```

`apt install ./file.deb` resolves the dependencies; `dpkg -i` does not. The
maintainer script builds the module for the running kernel, verifies that it
contains the patch, and reloads the driver only if nothing holds
`/dev/nvidia*` — otherwise reboot.

### Verify

```bash
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'  # 5GT/s, x4
nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current \
           --format=csv,noheader                       # Enabled, 2
ps -eo comm | grep nv-p104-gen2-wd                     # watchdog thread
```

Removal is `sudo dpkg -r nvidia-srv-p104-gen2`, which rebuilds and reinstalls
the stock module. Full preconditions, Secure Boot notes and troubleshooting are
in `deb/readme.txt`. To rebuild the package for another driver, follow
`deb/REBUILD.md`; to understand or re-derive the patch itself, read
`patch/README.md` and `patch/AGENT_PROMPT.md`.

## Contents

If you are changing the repository rather than just using it, read
[`AGENTS.md`](AGENTS.md) first: it lists the authoritative artefacts, the hard
rules, and the consistency checks that must pass before a change is done.

```
nvidia-p104-gen2/
├── LICENSE    MIT, covers this project's own code and docs
├── NOTICE     third-party notices (NVIDIA MIT sources, driver not included)
├── README.md
├── AGENTS.md  working agreement for anyone changing the repository
├── RELEASE_NOTES.md  install/verify/remove notes for a tagged release
├── patch/    all sources and tooling that produce the kernel patch
│   ├── README.md              directory map, three paths, tree verification
│   ├── AGENT_PROMPT.md        task prompt: apply or re-derive the patch
│   ├── p104-gen2.patch        canonical -p1 patch
│   ├── source/pristine/       untouched driver sources (580.178.04)
│   ├── source/patched/        same files with the patch applied
│   ├── diffs/                 per-file pieces of the patch
│   └── tools/                 mmio_test.c, linktest.sh, dump.sh, rollback.sh,
│                              bwtest.cu (PCIe bandwidth probe)
└── deb/      the shippable artifact
    ├── readme.txt             end-user notes (install, deinstall, preconditions)
    ├── REBUILD.md             prompt for an agent to rebuild the package
    ├── nvidia-srv-p104-gen2_580.178.04-1_all.deb   build output, git-ignored
    └── packaging/             dpkg tree used to build the .deb
```

The stock capture and the DKMS build logs from the reference machine are not
shipped: they are machine-specific and `tools/dump.sh` / a normal DKMS build
generate them (`baseline/` and `logs/` are ignored by git if you create
them). The `.deb` is a build output and is ignored as well — `deb/REBUILD.md`
produces it. A fresh clone contains everything needed to rebuild both the
patch and the package.

## References to similar projects and approaches

| Link | Brief description |
|---|---|
| https://github.com/skbskhud/p104-unlock-v3/tree/main | Windows 10/11 x64 project; useful reference for the same underlying Gen1→Gen2 issue. Its `docs/09-物理层实测记录-2026-10-31.md` and `docs/evidence/` files are especially good sources for register-level detail and measured behavior. |
| https://github.com/skbskhud/p104-gen2-unlock | Related P104-100 Gen2 unlock project; useful for cross-checking the observed Gen1→Gen2 behavior and recovery pattern. |
| https://github.com/dartraiden/NVIDIA-patcher | General NVIDIA patching project for driver and GPU configuration workarounds. |
| https://github.com/WJNKAC/nvidia-p104-unlock-gen2-for-linux | Linux-focused P104-100 Gen2 unlock implementation, useful for comparing the Linux-side approach to the Windows references. |

## License

MIT — see `LICENSE`.

`NOTICE` records the one third-party component: `patch/source/pristine/` and
`patch/source/patched/` are NVIDIA open GPU kernel-module sources (580.178.04),
themselves MIT and © NVIDIA 1999–2025, redistributed with their notices intact.
The diffs in `patch/` quote lines from those files as context and keep the same
terms.

The NVIDIA driver itself (kernel blobs and userspace libraries, installed by
`nvidia-driver-580-server`) is **not** part of this repository and is not
redistributed; your use of it is governed by its own license.
