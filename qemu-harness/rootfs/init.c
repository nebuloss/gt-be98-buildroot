/*
 * Minimal static aarch64 PID1 for the QEMU FullMAC RE harness.
 *
 * Boots, mounts the pseudo-filesystems, enables dynamic_debug for any
 * Broadcom WiFi module, insmods the harness modules found in /, lets the
 * probe run, prints a marker, then powers the machine off cleanly so the
 * QEMU run is non-interactive and scriptable.
 *
 * Build static so we need no libc/loader in the initramfs:
 *   aarch64-linux-gcc -static -O2 -o init init.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/reboot.h>
#include <linux/reboot.h>

static int finit(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    long r = syscall(SYS_finit_module, fd, "", 0);
    close(fd);
    return (int)r;
}

static void writef(const char *path, const char *val)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0)
        return;
    write(fd, val, strlen(val));
    close(fd);
}

int main(void)
{
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    puts("\n==== QEMU FullMAC RE harness init (aarch64) ====");

    /* Turn on dynamic debug for the Broadcom drivers BEFORE loading them, so we
     * capture the verbose dhd IPC complaints / brcmfmac messages. */
    writef("/sys/kernel/debug/dynamic_debug/control", "module dhd +p");
    writef("/sys/kernel/debug/dynamic_debug/control", "module bcmfmac_probe +p");
    writef("/sys/kernel/debug/dynamic_debug/control", "module brcmfmac +p");

    /* List the PCI bus so we can confirm the 14e4 device enumerated. */
    puts("---- /sys/bus/pci/devices ----");
    DIR *d = opendir("/sys/bus/pci/devices");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.')
                continue;
            char p[256], buf[64];
            int fd, n;
            snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/vendor", e->d_name);
            fd = open(p, O_RDONLY); n = fd >= 0 ? read(fd, buf, sizeof buf - 1) : -1;
            if (n > 0) { buf[n] = 0; printf("  %s vendor=%s", e->d_name, buf); }
            if (fd >= 0) close(fd);
            snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/device", e->d_name);
            fd = open(p, O_RDONLY); n = fd >= 0 ? read(fd, buf, sizeof buf - 1) : -1;
            if (n > 0) { buf[n] = 0; printf("  device=%s", buf); }
            if (fd >= 0) close(fd);
            snprintf(p, sizeof p, "/sys/bus/pci/devices/%s/class", e->d_name);
            fd = open(p, O_RDONLY); n = fd >= 0 ? read(fd, buf, sizeof buf - 1) : -1;
            if (n > 0) { buf[n] = 0; printf("  class=%s", buf); }
            if (fd >= 0) close(fd);
        }
        closedir(d);
    }

    /* Load every .ko sitting at / (insertion order: deps first if present). */
    static const char *mods[] = {
        /* dhd dep chain (only present in the merlin-ABI rootfs variant) */
        "/bcmlibs.ko", "/hnd.ko", "/bdmf.ko", "/wlshared.ko",
        "/rdpa_gpl.ko", "/bcm_knvram.ko", "/emf.ko", "/igs.ko",
        "/bcmmcast.ko", "/wfd.ko", "/bcm_pcie_hcd.ko",
        /* the FullMAC driver under test */
        "/dhd.ko",
        /* stock-kernel exerciser */
        "/bcmfmac_probe.ko",
        NULL
    };
    for (int i = 0; mods[i]; i++) {
        if (access(mods[i], F_OK) != 0)
            continue;
        printf("---- finit_module %s ----\n", mods[i]);
        fflush(stdout);
        int r = finit(mods[i]);
        printf("     -> %s (rc=%d)\n", r == 0 ? "OK" : "FAIL", r);
        fflush(stdout);
    }

    sync();
    sleep(1);
    puts("==== harness done; powering off ====");
    fflush(stdout);
    reboot(LINUX_REBOOT_CMD_POWER_OFF);
    /* if that returns, spin */
    for (;;) pause();
    return 0;
}
