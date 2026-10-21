// SPDX-License-Identifier: MIT
// Prove which processes are native arm64: for every process whose executable path contains the
// given text (or every process, with no argument), print
//   pid  ppid  cputype  translated  rss_kb  path  name
// cputype comes from proc_pidinfo(PROC_PIDARCHINFO) ("arm64" or "x86_64"); translated is the
// kernel's P_TRANSLATED flag (1 = running under Rosetta), the same bit sysctl.proc_translated
// reports for the calling process. Exit status 3 if any listed process is translated or not arm64.
// Build: clang -O2 -arch arm64 procarch.c -o procarch
#include <libproc.h>
#include <mach/machine.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>

int main(int argc, char **argv) {
    const char *needle = argc > 1 ? argv[1] : "";
    int n = proc_listallpids(NULL, 0);
    pid_t *pids = calloc((size_t)n + 64, sizeof(pid_t));
    n = proc_listallpids(pids, (int)((n + 64) * sizeof(pid_t)));
    int bad = 0, shown = 0;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = "";
        if (proc_pidpath(pids[i], path, sizeof path) <= 0) continue;
        if (*needle && !strstr(path, needle)) continue;
        struct kinfo_proc kp; size_t len = sizeof kp;
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pids[i] };
        if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) continue;
        int translated = (kp.kp_proc.p_flag & P_TRANSLATED) != 0;
        struct proc_archinfo ai = {0};
        const char *cpu = "?";
        if (proc_pidinfo(pids[i], PROC_PIDARCHINFO, 0, &ai, sizeof ai) == sizeof ai)
            cpu = ai.p_cputype == CPU_TYPE_ARM64 ? "arm64" : ai.p_cputype == CPU_TYPE_X86_64 ? "x86_64" : "other";
        struct proc_taskinfo ti = {0};
        long rss = proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof ti) == sizeof ti ? (long)(ti.pti_resident_size / 1024) : -1;
        char name[2 * MAXCOMLEN + 1] = "";
        proc_name(pids[i], name, sizeof name);
        printf("%d\t%d\t%s\t%d\t%ld\t%s\t%s\n", pids[i], kp.kp_eproc.e_ppid, cpu, translated, rss, path, name);
        shown++;
        if (translated || strcmp(cpu, "arm64") != 0) bad = 1;
    }
    fprintf(stderr, "procarch: %d process(es)%s\n", shown, bad ? ", NOT ALL NATIVE ARM64" : ", all native arm64, none translated");
    return bad ? 3 : 0;
}
