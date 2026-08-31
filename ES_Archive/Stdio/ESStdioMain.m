//
//  ESStdioMain.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Entry point for the stdio MCP host. Claude Desktop / Claude Code spawn
//  this app once per session and speak newline-delimited JSON-RPC over the
//  inherited stdin/stdout pipes; [NSApp run] idles between calls, so Core
//  Data and the embedder load once and stay warm for the session.
//
//  Bypasses NSApplicationMain so no storyboard is loaded — this is a headless MCP
//  host that builds its menu and windows entirely in code (see the delegate). The
//  delegate is held in a static to survive ARC scope exit.
//

#import <Cocoa/Cocoa.h>
#import "ESStdioAppDelegate.h"
#import "MCPStdioServer.h"
#import "ESEngine.h"
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/resource.h>

static ESStdioAppDelegate *gAppDelegate = nil;

// An AI host (Claude Desktop, LM Studio) spawns us with stdio *pipes*; a user
// double-click gets /dev/null (a char device) on the std fds. That's the tell.
// fd 0 is untouched by the fd-1 RPC dup below, so this is safe to read anytime.
static BOOL ESLaunchedByAIHost(void) {
    struct stat st;
    return (fstat(STDIN_FILENO, &st) == 0 && (S_ISFIFO(st.st_mode) || S_ISSOCK(st.st_mode)));
}

int main(int argc, const char *argv[]) {
    // Stdout hygiene, before anything else runs: this process hosts an
    // engine, an embedder, and AppKit — one stray printf on fd 1 would
    // corrupt a JSON-RPC frame. Keep a private dup of fd 1 for the RPC
    // channel and point fd 1 at stderr so strays land harmlessly.
    int rpc_fd = dup(STDOUT_FILENO);
    if (rpc_fd >= 0) {
        dup2(STDERR_FILENO, STDOUT_FILENO);
    } else {
        rpc_fd = STDOUT_FILENO; // dup failed — degrade to raw stdout
    }

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);   // diagnostics — never buffer
    signal(SIGPIPE, SIG_IGN);           // client may close its end mid-write
    signal(SIGTERM, SIG_IGN);           // the dispatch source in MCPStdioServer owns SIGTERM

    // When this session wins the socket election it hosts peers; raise the fd
    // soft limit so a burst of peer connections can't exhaust it (default 256).
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rl.rlim_cur = (rl.rlim_max == RLIM_INFINITY) ? 8192 : rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    fprintf(stderr, "[es-memory-mcp] main() pid=%d\n", getpid());

    // The pipe tells us only whether there is an MCP client on stdin to serve.
    // It does NOT decide the UI: that follows the socket election — the instance
    // that ends up running the engine in-process raises the GUI (see the delegate).
    BOOL launchedByAI = ESLaunchedByAIHost();
    fprintf(stderr, "[es-memory-mcp] launch context: %s — UI role is decided by the socket election\n",
            launchedByAI ? "MCP client on the pipe" : "user launch");

    // Persona for this session: --author <name>. Set on the engine before it
    // starts; nil (no flag) keeps the target's ESDefaultAuthor. Also declared to
    // a shared host so our relayed requests are scoped to this persona.
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--author") == 0) {
            NSString *author = [NSString stringWithUTF8String:argv[i + 1]];
            if (author.length) {
                [ESEngine shared].authorOverride = author;
                fprintf(stderr, "[es-memory-mcp] persona: %s\n", argv[i + 1]);
            }
            break;
        }
    }

    @autoreleasepool {
        [MCPStdioServer setRPCFileDescriptor:rpc_fd];

        NSApplication *app = [NSApplication sharedApplication];
        // Start every instance quiet — menu-bar-capable, no dock. The delegate
        // promotes to a full app presence only if this instance ends up running
        // the engine in-process (host or standalone); a relay stays headless.
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        gAppDelegate = [[ESStdioAppDelegate alloc] init];
        gAppDelegate.launchedByAI = launchedByAI;
        app.delegate = gAppDelegate;

        [app run];
    }
    return 0;
}
