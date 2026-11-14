nvidia-srv-p104-gen2
====================

PCIe Gen2 x4 (5.0 GT/s) unlock for the NVIDIA P104-100 mining card
(PCI ID 10de:1b87) on the out-of-tree NVIDIA kernel module.

Package:  nvidia-srv-p104-gen2_580.178.04-1_all.deb
Driver:   nvidia-srv / nvidia-dkms-580-server 580.178.04


WHAT IT DOES
------------

A stock P104-100 advertises and negotiates only 2.5 GT/s (PCIe Gen1) even
though the slot and root port support more. The link is limited by GPU state,
not by anything reachable through PCIe config space, so setpci alone cannot
change it.

This package applies a patch to the NVIDIA kernel module that:

  1. Re-declares 5.0 GT/s capability in the GPU's BAR0 XVE/XP_PL registers
     (0x8C040 LINK_CONFIG_0, 0x8C1C0 NV_XP_PL_LCTRL_2 and related).
  2. Requests 5.0 GT/s as the target link speed on both the GPU and its
     upstream root port and retrains the link, retrying because the first
     attempt after adapter init normally does not take.
  3. Repeats the unlock after every rm_init_adapter(), because the closed
     Resource Manager resets the link to Gen1 when the adapter is
     (re)initialized.
  4. Runs a 250 ms watchdog thread (nv-p104-gen2-wd) that re-applies the
     unlock whenever the link drops to Gen1. The Resource Manager re-asserts
     Gen1 as soon as the link goes quiet while the GPU is busy, so the
     watchdog keeps working for the whole session; at true idle the link
     stays at Gen2 on its own.
  5. Installs a systemd drop-in that runs nvidia-persistenced with
     --persistence-mode instead of --no-persistence-mode. With the stock
     setting the adapter is torn down after every client, so each
     nvidia-smi re-initializes it and resets the link.

Result: LnkSta reports 5GT/s x4. At idle the link stays there indefinitely.
Under a chat-style CUDA workload (one request every ~2.5 s) the Resource
Manager re-asserts Gen1 a few times per second while the link is quiet between
transfers; the watchdog restores Gen2 within ~0.2 s, so the link is at Gen2
for about 76% of busy time (with the original 1 s watchdog it was about 67%).

The patch is applied by DKMS at build time through an override file,
/etc/dkms/nvidia-srv-580.178.04.conf. The driver's own source files under
/usr/src/nvidia-srv-580.178.04/nvidia/ are left untouched and stay pristine.


PRECONDITIONS
-------------

Required, checked by postinst (which aborts with a clear message otherwise).
If the machine has no NVIDIA driver yet, see FROM ZERO below first:

  * The NVIDIA DKMS driver is installed and registered:
        dpkg -l nvidia-dkms-580-server
        dkms status          # must show nvidia-srv/580.178.04 ... installed
  * The matching source tree exists: /usr/src/nvidia-srv-580.178.04/dkms.conf
  * dkms is installed (version 3.x; tested with 3.2.2).
  * Kernel headers for the running kernel
        /usr/src/linux-headers-$(uname -r)/
    and a working compiler toolchain (gcc, make, ld); a full module build
    takes about a minute.
  * An initramfs generator: update-initramfs (initramfs-tools or dracut) is
    present here. If none is found the module is still built, only the
    initramfs step is skipped.
  * Root privileges (sudo).
  * The exact package version matters: the DKMS override file is
    version-specific. It applies only to driver 580.178.04. If the driver is
    upgraded or downgraded, this package no longer takes effect and must be
    rebuilt for the new version.

Not required, but worth knowing:

  * Secure Boot does not need to be disabled: DKMS signs modules with the
    local MOK key. Check with: mokutil --sb-state
  * The GPU does not have to be free at install time, but if any process holds
    /dev/nvidia* the driver is not reloaded automatically and you must reboot
    (or unload/reload the nvidia modules yourself) before the link changes.
  * The driver patch is display-agnostic; on this host the P104-100 is
    headless and an iGPU provides the console, but that is not a requirement.
  * Ideally the GPU's immediate parent is a PCIe root port (00:01.0 here):
    the helper then also sets the target speed and retrains on the root port.
    Behind a PCIe switch only the endpoint is retrained.

Useful to record before installing:

        sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
        nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current \
                   --format=csv,noheader

Baseline on this host: LnkCap 2.5GT/s x4, LnkSta 2.5GT/s x4, gen.current 1.


FROM ZERO: INSTALLING THE STOCK DRIVER FIRST
--------------------------------------------

This package is a patch on top of the distribution driver, not a driver
replacement. It needs nvidia-dkms-580-server 580.178.04 registered with DKMS,
because it hooks into that DKMS build. On a machine without NVIDIA drivers,
do the following first (Ubuntu 26.04, driver from the Ubuntu archive).

Step 1 - confirm the card is there

    lspci -nn -d 10de:1b87
    # expect: NVIDIA Corporation GP104 [P104-100] [10de:1b87]
    # "Kernel driver in use: nouveau" is fine; it gets replaced in step 5.

Step 2 - refresh package lists and confirm the wanted version is available

    sudo apt update
    apt-cache policy nvidia-dkms-580-server
    # this package is built for 580.178.04-0ubuntu0.26.04.1

If only another version is offered (for example 580.126.20-0ubuntu3 from the
release pocket, or a newer -updates), then either install exactly 580.178.04
if it is still in the archive, or rebuild this patch package for the version
that is available (see REBUILDING FOR A NEW DRIVER VERSION, below). The DKMS
override filename is version specific; it will not apply to a different
driver version.

Step 3 - build prerequisites for DKMS

    sudo apt install dkms build-essential linux-headers-$(uname -r)
    # if the running kernel has no headers package, use linux-headers-generic

Step 4 - Secure Boot (skip if disabled)

    mokutil --sb-state

If it says "SecureBoot enabled", DKMS-signed modules must be trusted, otherwise
the driver will not load ("Key was rejected by service"). The driver package
prompts for a one-time MOK enrolment password during install; then:

    sudo reboot
    # in the blue MOK Manager: Enroll MOK -> Continue -> Yes -> enter password
    # -> Reboot

If Secure Boot is disabled or the platform is in Setup Mode, nothing to do.

Step 5 - install the stock driver, exactly the version this patch targets

    sudo apt install \
        nvidia-driver-580-server=580.178.04-0ubuntu0.26.04.1 \
        nvidia-dkms-580-server=580.178.04-0ubuntu0.26.04.1

Do not use the NVIDIA .run installer for this workflow: it does not create
/usr/src/nvidia-srv-<ver> or register anything with DKMS, so the patch package
cannot attach to it. If the machine already has a .run installation, remove it
with its --uninstall option and use the packages above instead.

Optional, but recommended while the patch package is in use: stop apt from
silently upgrading the driver out from under the patch.

    sudo apt-mark hold nvidia-driver-580-server nvidia-dkms-580-server

Remember to unhold them when you rebuild the patch for a newer driver.

Step 6 - reboot once so nouveau is gone and the new module is loaded cleanly

    sudo reboot

Step 7 - verify the stock driver works

    nvidia-smi
    dkms status
    # expect: nvidia-srv/580.178.04, $(uname -r), x86_64: installed
    ls /usr/src/nvidia-srv-580.178.04/dkms.conf
    lsmod | grep '^nvidia'
    sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
    # stock state: both 2.5GT/s, Width x4

Once that is true, all preconditions listed in the section above are satisfied
and the patch package can be installed with the INSTALL steps below.


INSTALL
-------

(From the deb/ directory of the project, where this file and the .deb live.)

  sudo apt install ./nvidia-srv-p104-gen2_580.178.04-1_all.deb

or, without apt (no automatic dependency resolution):

  sudo dpkg -i nvidia-srv-p104-gen2_580.178.04-1_all.deb

postinst will:
  - rebuild the NVIDIA module for the running kernel with the patch,
  - verify that the built module really contains the P104-100 code and abort
    without touching the installed module if it does not,
  - reinstall the module and regenerate the initramfs,
  - reload the NVIDIA modules if no process holds /dev/nvidia*, otherwise ask
    for a reboot.

Verify:

  sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
        expect: LnkCap Speed 5GT/s ... / LnkSta Speed 5GT/s, Width x4

  nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv
        expect: Enabled, 2

  sudo dmesg | grep P104-100
        expect: "P104-100: PCIe Gen2 unlock applied, LNKSTA=0x1042"

  ps -eo comm | grep nv-p104-gen2-wd
        expect: the watchdog thread is running

  sudo dkms status
        expect: nvidia-srv/580.178.04, $(uname -r), x86_64: installed

If the link is still 2.5 GT/s, check:

  sudo dmesg | grep -iE 'P104|nvrm' | tail -30
  ls /etc/dkms/nvidia-srv-580.178.04.conf
  ls /usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
  sudo dkms build -m nvidia-srv -v 580.178.04 -k $(uname -r) --force

A reboot is always a valid way to activate a freshly built module.


DEINSTALL
---------

  sudo dpkg -r nvidia-srv-p104-gen2

or, to also drop any remaining package state:

  sudo dpkg -P nvidia-srv-p104-gen2

prerm stops nvidia-persistenced so the driver can be reloaded. postrm then:
  - rebuilds and reinstalls the stock (unpatched) module for the running
    kernel,
  - restores the stock nvidia-persistenced behaviour (the drop-in is removed
    by dpkg, so --no-persistence-mode applies again),
  - reloads the modules if the GPU is idle.

Verify the revert:

  sudo lspci -s 01:00.0 -vv | grep LnkSta:
        expect: Speed 2.5GT/s, Width x4

  nvidia-smi --query-gpu=persistence_mode,pcie.link.gen.current --format=csv
        expect: Disabled, 1

  zstd -dc /lib/modules/$(uname -r)/updates/dkms/nvidia.ko.zst | strings \
        | grep 'P104-100:'
        expect: no output   (the colon matters: the device name string
                             "NVIDIA P104-100" is always present)

Note: LnkCap may still report 5GT/s until the next reboot. The capability bit
lives in GPU state, not in the module; LnkSta (the actual negotiated speed)
is authoritative and returns to 2.5 GT/s immediately.

Removal does not touch the driver package, the DKMS module registration, or
any user data.

If the GPU was busy during removal, the running module stays patched until the
next reboot; the on-disk module is already the stock one.


FILES INSTALLED
---------------

  /etc/dkms/nvidia-srv-580.178.04.conf
      DKMS override: PATCH[2]="p104-gen2.patch"
  /usr/src/nvidia-srv-580.178.04/patches/p104-gen2.patch
      the kernel module patch (applied at build time only)
  /etc/systemd/system/nvidia-persistenced.service.d/p104-gen2.conf
      --persistence-mode, StopWhenUnneeded=no
  /usr/share/doc/nvidia-srv-p104-gen2/README
      same notes as this file
  /usr/share/doc/nvidia-srv-p104-gen2/copyright
      MIT license text; notes that the NVIDIA driver itself is not
      redistributed by this package

All of the above are removed by dpkg -r. The driver source tree under
/usr/src/nvidia-srv-580.178.04/nvidia/ is never modified, so the stock driver
package stays verifiable with: dpkg -V nvidia-dkms-580-server


REBUILDING FOR A NEW DRIVER VERSION
-----------------------------------

The override filename and the patch content are tied to 580.178.04. After a
driver upgrade, regenerate the patch against the new source tree and bump the
version in DEBIAN/control, DEBIAN/postinst and DEBIAN/postrm, then:

  dpkg-deb --build --root-owner-group packaging \
            nvidia-srv-p104-gen2_<version>-1_all.deb

The packaging tree used to build this file is not installed with the package.
If you have the source distribution it contains:

  deb/packaging/   the dpkg tree the package is built from
  deb/REBUILD.md   step-by-step rebuild instructions (including the lockstep
                   version bump and the install/remove verification)
  patch/           the patch, pristine and patched sources, pre-test tools


KNOWN LIMITATIONS
-----------------

  * The Resource Manager cannot be told to stop downgrading (its registry
    keys have no effect on GP104), so it still forces Gen1 whenever the PCIe
    link goes quiet during CUDA work. The watchdog corrects this within
    ~0.2 s. Expect ~20% of samples at 2.5 GT/s while a chat workload is
    running, and none at idle.
  * Each correction costs two link retrains (one to latch the register, one to
    train), so expect ~2 retrains per second during such a workload. They are
    invisible unless dynamic debug is enabled.
  * The unlock is specific to 10de:1b87 (P104-100); the code is a no-op for
    any other device.
  * A cold reboot is the recovery path if an experimental BAR0 write ever
    wedges the PCIe link.
