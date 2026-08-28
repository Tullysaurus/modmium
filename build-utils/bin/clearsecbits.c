/*
 * Build with an explicit baseline, NOT -march=native:
 *
 *   gcc -O2 -static -march=x86-64 -mtune=generic -o clearsecbits-x86-64 clearsecbits.c
 *
 * A native build on a modern machine produces a binary that requires
 * x86-64-v3 (AVX2/BMI) and kernel 6.1. Plenty of supported Chromebooks meet
 * neither: Goldmont Plus (Gemini Lake, e.g. octopus) has no AVX at all, and
 * ChromeOS ships 4.x/5.x kernels. Such a binary dies with SIGILL, and since
 * runscript() wraps every menu action in it, that leaves the device with no
 * working menu items at all - including the root shell and the updater, so
 * there is no way to fix it from MOSH.
 *
 * Verify a build before shipping it:
 *   readelf -n clearsecbits-x86-64 | grep -E 'ISA needed|ABI:'
 * Expect "x86 ISA needed: x86-64-baseline" and an ABI of 3.2.0.
 */
#define _GNU_SOURCE
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/capability.h>
#include <stdio.h>

static int do_capget(struct __user_cap_header_struct *hdr, struct __user_cap_data_struct *data) {
  return syscall(SYS_capget, hdr, data);
}
static int do_capset(struct __user_cap_header_struct *hdr, const struct __user_cap_data_struct *data) {
  return syscall(SYS_capset, hdr, data);
}

int main(int argc, char **argv) {
  prctl(PR_SET_SECUREBITS, 0);

  struct __user_cap_header_struct hdr = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct data[2];

  if (do_capget(&hdr, data) != 0) { perror("capget"); return 1; }

  data[0].effective   &= ~(1u << CAP_KILL);
  data[0].permitted   &= ~(1u << CAP_KILL);
  data[0].inheritable &= ~(1u << CAP_KILL);

  if (do_capset(&hdr, data) != 0) { perror("capset"); return 1; }

  prctl(PR_CAPBSET_DROP, CAP_KILL);

  if (argc < 2) { fprintf(stderr, "usage: %s <cmd> [args...]\n", argv[0]); return 1; }
  execvp(argv[1], &argv[1]);
  perror("execvp");
  return 127;
}
