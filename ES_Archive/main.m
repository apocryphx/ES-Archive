//
//  main.m
//  ES Archive
//
//  Created by Kolja Wawrowsky on 3/2/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import <signal.h>
#import <sys/resource.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // This app hosts the engine socket (MCPUnixSocketServer). Two hardening
        // steps a socket server needs, at the earliest possible point:
        //  * Ignore SIGPIPE, or a client that drops mid-write kills us with
        //    "signal 13". (MCPUnixSocketServer also does this in -init and sets
        //    SO_NOSIGPIPE per connection; belt-and-suspenders.)
        //  * Raise the fd soft limit — a burst of client connections easily
        //    exhausts the default 256, after which accept() silently stops.
        signal(SIGPIPE, SIG_IGN);
        struct rlimit rl;
        if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
            rl.rlim_cur = (rl.rlim_max == RLIM_INFINITY) ? 8192 : rl.rlim_max;
            setrlimit(RLIMIT_NOFILE, &rl);
        }

        // Main.storyboard is gone: the delegate it used to instantiate is created
        // here, and the delegate builds the menu (-installMainMenu) and every
        // window in code. With no NSMainStoryboardFile / NSMainNibFile left to
        // load, NSApplicationMain is just sharedApplication + run — the same
        // code bootstrap the MCP host does explicitly in ESStdioMain.m, minus
        // the stdio plumbing that host needs.
        // The delegate must outlive main, hence the static.
        static AppDelegate *delegate;
        delegate = [AppDelegate new];
        NSApplication.sharedApplication.delegate = delegate;
    }
    return NSApplicationMain(argc, argv);
}
