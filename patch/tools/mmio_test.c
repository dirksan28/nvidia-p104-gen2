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
