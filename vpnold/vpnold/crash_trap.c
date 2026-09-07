/*
 * crash_trap.c — writes a backtrace to a file when the process dies on a signal.
 *
 * There is no Xcode attached to this device and /var/mobile/Library/Logs is
 * awkward to reach, so the app records its own crash. A signal handler may only
 * call async-signal-safe functions — hence raw write() and backtrace_symbols_fd,
 * no stdio, no Foundation, no malloc on the crash path.
 *
 * Swift runtime traps (force-unwrap of nil, array bounds, fatalError) arrive as
 * SIGILL/SIGTRAP, so they are caught here too.
 */

#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <execinfo.h>
#include <mach-o/dyld.h>

static int g_fd = -1;

static void wr(const char *s)
{
    if (g_fd >= 0 && s) {
        ssize_t n = write(g_fd, s, strlen(s));
        (void)n;
    }
}

static const char *signame(int sig)
{
    switch (sig) {
    case SIGSEGV: return "SIGSEGV (bad memory access)";
    case SIGBUS:  return "SIGBUS (bad address / alignment)";
    case SIGILL:  return "SIGILL (illegal instruction - often a Swift runtime trap)";
    case SIGTRAP: return "SIGTRAP (trap - often a Swift runtime trap)";
    case SIGFPE:  return "SIGFPE (arithmetic fault)";
    case SIGABRT: return "SIGABRT (abort - usually an uncaught exception)";
    default:      return "unknown signal";
    }
}

static void crash_handler(int sig)
{
    wr("\n=== CRASH: ");
    wr(signame(sig));
    wr(" ===\n");

    void *frames[64];
    int n = backtrace(frames, 64);
    if (g_fd >= 0)
        backtrace_symbols_fd(frames, n, g_fd);
    wr("=== end of backtrace ===\n");

    /* Die for real, so the OS records its own report as well. */
    signal(sig, SIG_DFL);
    raise(sig);
}

/* Open the log (appending) and install the handlers. Returns 0, or -1 if the
 * file could not be opened. */
int crash_trap_install(const char *path)
{
    g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_fd < 0)
        return -1;

    /* The slide is what makes the addresses above resolvable off-device
     * (atos -o vpnold -l <slide>). */
    char buf[128];
    snprintf(buf, sizeof buf, "image slide = 0x%lx\n",
             (unsigned long)_dyld_get_image_vmaddr_slide(0));
    wr(buf);

    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT };
    for (unsigned i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
        signal(sigs[i], crash_handler);
    return 0;
}

/* Append one breadcrumb line. write() is unbuffered, so whatever got here is
 * already in the file when the process dies. */
void crash_trap_note(const char *line)
{
    wr(line);
    wr("\n");
}
