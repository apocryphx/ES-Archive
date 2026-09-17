//
//  ESLog.h
//  ES Archive MCP
//
//  Two logging macros.
//
//  `ESLog(...)` — Debug-only chatter (startup traces, per-request logs,
//  FRC fires, vector-queue progress, etc.). DEBUG is defined automatically
//  by Xcode in Debug configurations via the project's
//  GCC_PREPROCESSOR_DEFINITIONS. In Release builds, ESLog expands to a
//  no-op that the compiler strips entirely — no format-string evaluation,
//  no argument marshalling, zero runtime cost.
//
//  `ESLogAlways(...)` — survives Release builds. Use for diagnostics that
//  must remain visible in notarized / App Store builds: anything you
//  might need to read out of `log show` on a customer machine. Goes
//  through os_log with subsystem "com.elarity.es-archive-mcp" so it can
//  be filtered cleanly:
//
//      log show --predicate 'subsystem == "com.elarity.es-archive-mcp"' \
//               --last 5m --info --debug
//      log stream --predicate 'subsystem == "com.elarity.es-archive-mcp"'
//
//  Keep plain `NSLog(...)` for genuine error conditions if you want them
//  in Console.app's default view as well.
//

#ifndef ESLog_h
#define ESLog_h

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <pthread.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>

#ifdef DEBUG
  #define ESLog(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
  #define ESLog(fmt, ...) ((void)0)
#endif

/// Lazily-initialized os_log handle. Subsystem matches the app bundle id
/// so `log show --predicate 'subsystem == "com.elarity.es-archive-mcp"'`
/// shows our diagnostic stream cleanly.
static inline os_log_t ESLogAlwaysHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.elarity.es-archive-mcp", "diagnostic");
    });
    return handle;
}

/// Release-safe diagnostic log. Formats via NSString first so all the usual
/// `%@`, `%lu`, etc. specifiers work the same as `NSLog`, then emits via
/// os_log at default level so it survives notarized builds.
/// Election / socket trace, for reconstructing exactly what N processes did to
/// each other. Off unless the environment has ES_ARCHIVE_TRACE=1 (checked once),
/// so it costs a load and a branch in Release. Writes one line to stderr —
/// which Claude Desktop captures into mcp-server-ES Archive.log, and which the
/// drills in Testing/ record per process — stamped with seconds since this
/// process first traced, pid, and thread, so lines from several processes can be
/// merged. See Testing/stdio-reelection/run.sh (TRACE=…).
/// Process-wide state lives in ESLog.m — one flag, one clock, shared by every
/// translation unit that traces.
BOOL   ESTraceEnabled(void);
double ESTraceClock(void);

#define ESTrace(fmt, ...) do { \
    if (ESTraceEnabled()) { \
        NSString *_es_t_ = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        uint64_t _es_tid_ = 0; pthread_threadid_np(NULL, &_es_tid_); \
        fprintf(stderr, "[es-trace] +%.4f pid=%d tid=%llu %s\n", \
                ESTraceClock(), getpid(), (unsigned long long)_es_tid_, _es_t_.UTF8String); \
    } \
} while (0)

#define ESLogAlways(fmt, ...) do { \
    NSString *_es_msg_ = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    os_log(ESLogAlwaysHandle(), "%{public}@", _es_msg_); \
} while (0)

#endif /* ESLog_h */
