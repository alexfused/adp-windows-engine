// SPDX-License-Identifier: MIT
// Rosetta guard for the Intel engine build (env.sh: rosetta_guard_start/stop).
//
//   rosetta-watch <path-prefix> <root-pid>
//
// Reads the kernel's process table 100 times a second until SIGINT/SIGTERM. A process the kernel
// marks P_TRANSLATED (running under Rosetta) is reported as
//   TRANSLATED <pid> <ppid> <path>        if its executable is under <path-prefix> or <root-pid> is
//                                         one of its ancestors (our build started it): it is killed
//   OTHER-TRANSLATED <pid> <ppid> <path>  anything else on the Mac (e.g. an Intel app someone runs)
// and oahd-helper (Rosetta's ahead-of-time translator) as HELPER. Processes already translated
// when the watch starts are listed once as PRE-EXISTING. The last line is a summary.
// A fork that execs an x86_64 binary keeps its pid, so every pid is checked on every pass.
// Build (native arm64): clang -O2 -arch arm64 rosetta-watch.c -o rosetta-watch
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define MAXSEEN 4096
static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static struct kinfo_proc *procs; static size_t nprocs;

static int snapshot(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0) return -1;
    len += 64 * sizeof(struct kinfo_proc);
    static size_t cap; if (len > cap) { free(procs); procs = malloc(len); cap = len; if (!procs) return -1; }
    if (sysctl(mib, 3, procs, &len, NULL, 0) != 0) return -1;
    nprocs = len / sizeof(struct kinfo_proc);
    return 0;
}

static pid_t parent_of(pid_t pid) {
    for (size_t i = 0; i < nprocs; i++) if (procs[i].kp_proc.p_pid == pid) return procs[i].kp_eproc.e_ppid;
    return 0;
}

static int descends_from(pid_t pid, pid_t root) {
    for (int depth = 0; depth < 64 && pid > 1; depth++) { if (pid == root) return 1; pid = parent_of(pid); }
    return 0;
}

// (pid, start time) pairs already reported, so a reused pid is reported again.
static struct { pid_t pid; long sec, usec; } seen[MAXSEEN]; static int nseen;
static int was_seen(const struct kinfo_proc *p) {
    for (int i = 0; i < nseen; i++)
        if (seen[i].pid == p->kp_proc.p_pid && seen[i].sec == p->kp_proc.p_starttime.tv_sec && seen[i].usec == p->kp_proc.p_starttime.tv_usec) return 1;
    return 0;
}
static void mark(const struct kinfo_proc *p) {
    if (nseen < MAXSEEN) { seen[nseen].pid = p->kp_proc.p_pid; seen[nseen].sec = p->kp_proc.p_starttime.tv_sec; seen[nseen].usec = p->kp_proc.p_starttime.tv_usec; nseen++; }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: rosetta-watch <path-prefix> <root-pid>\n"); return 2; }
    const char *prefix = argv[1];
    pid_t root = (pid_t)atoi(argv[2]);
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);
    long rounds = 0, ours = 0, others = 0, helpers = 0;
    for (int first = 1; !stop; first = 0) {
        if (snapshot() == 0) {
            for (size_t i = 0; i < nprocs; i++) {
                const struct kinfo_proc *p = &procs[i];
                int translated = (p->kp_proc.p_flag & P_TRANSLATED) != 0;
                int helper = strncmp(p->kp_proc.p_comm, "oahd-helper", sizeof p->kp_proc.p_comm) == 0;
                if ((!translated && !helper) || was_seen(p)) continue;
                mark(p);
                pid_t pid = p->kp_proc.p_pid, ppid = p->kp_eproc.e_ppid;
                char path[PROC_PIDPATHINFO_MAXSIZE] = "?";
                proc_pidpath(pid, path, sizeof path);
                if (first) { printf("PRE-EXISTING %d %d %s\n", pid, ppid, path); continue; }
                if (!translated) { printf("HELPER %d %d %s\n", pid, ppid, path); helpers++; continue; }
                if (strncmp(path, prefix, strlen(prefix)) == 0 || descends_from(pid, root)) {
                    kill(pid, SIGKILL);
                    printf("TRANSLATED %d %d %s (killed)\n", pid, ppid, path); ours++;
                } else {
                    printf("OTHER-TRANSLATED %d %d %s\n", pid, ppid, path); others++;
                }
            }
        }
        rounds++;
        struct timespec ts = { 0, 10 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    printf("watched %ld rounds: %ld translated from this build, %ld other translated, %ld oahd-helper\n",
           rounds, ours, others, helpers);
    return 0;
}
