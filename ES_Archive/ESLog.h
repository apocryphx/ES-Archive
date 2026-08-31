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
//  through os_log with subsystem "com.elarity.es-memory-mcp" so it can
//  be filtered cleanly:
//
//      log show --predicate 'subsystem == "com.elarity.es-memory-mcp"' \
//               --last 5m --info --debug
//      log stream --predicate 'subsystem == "com.elarity.es-memory-mcp"'
//
//  Keep plain `NSLog(...)` for genuine error conditions if you want them
//  in Console.app's default view as well.
//

#ifndef ESLog_h
#define ESLog_h

#import <Foundation/Foundation.h>
#import <os/log.h>

#ifdef DEBUG
  #define ESLog(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
  #define ESLog(fmt, ...) ((void)0)
#endif

/// Lazily-initialized os_log handle. Subsystem matches the app bundle id
/// so `log show --predicate 'subsystem == "com.elarity.es-memory-mcp"'`
/// shows our diagnostic stream cleanly.
static inline os_log_t ESLogAlwaysHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.elarity.es-memory-mcp", "diagnostic");
    });
    return handle;
}

/// Release-safe diagnostic log. Formats via NSString first so all the usual
/// `%@`, `%lu`, etc. specifiers work the same as `NSLog`, then emits via
/// os_log at default level so it survives notarized builds.
#define ESLogAlways(fmt, ...) do { \
    NSString *_es_msg_ = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    os_log(ESLogAlwaysHandle(), "%{public}@", _es_msg_); \
} while (0)

#endif /* ESLog_h */
