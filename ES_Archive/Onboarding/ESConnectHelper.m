//
//  ESConnectHelper.m
//  ES Archive
//

#import "ESConnectHelper.h"
#import "ESZip.h"

@interface ESConnectHelper ()
+ (NSString *)serverExecutablePath;
+ (NSData *)connectorMCPBData;
+ (void)presentAlert:(NSString *)message
                info:(NSString *)info
              window:(NSWindow *)window
           revealURL:(NSURL *)revealURL;
@end

@implementation ESConnectHelper

+ (NSString *)serverExecutablePath {
    // The running binary IS the stdio server (chameleon: same Mach-O, serves
    // stdio when spawned with pipes). executablePath is nil only pathologically.
    NSString *path = NSBundle.mainBundle.executablePath;
    return path ?: @"/Applications/ES Archive MCP.app/Contents/MacOS/ES Archive MCP";
}

#pragma mark - Connector generation

+ (NSData *)connectorMCPBData {
    // A thin connector .mcpb pointing Claude Desktop at THIS running binary.
    // command = our own executablePath → install-location-proof (no hardcoded
    // /Applications; works for the Dev-ID build too). --author Claude because a
    // Claude Desktop connector is, by definition, Claude. (The flag is a harmless
    // no-op on today's engine, which already defaults to "Claude"; it becomes
    // load-bearing once the engine parses --author and the default becomes "anonymous".)
    NSString *exe = [self serverExecutablePath];
    NSDictionary *manifest = @{
        @"manifest_version": @"0.3",
        @"name": @"es-archive-bridge",
        @"display_name": @"ES Archive",
        @"version": @"3.1.0",
        @"description": @"Connector for the installed ES Archive app — Claude Desktop talks "
                        @"to the memory engine over stdio. All data stays on this machine "
                        @"or syncs via your private iCloud.",
        @"author": @{ @"name": @"Kolja Wawrowsky" },   // required by the manifest schema
        @"server": @{
            @"type": @"binary",
            @"entry_point": exe,                        // required for type:binary
            @"mcp_config": @{
                @"command": exe,
                @"args": @[ @"--author", @"Claude" ]
            }
        },
        @"tools_generated": @YES,
        @"compatibility": @{ @"platforms": @[ @"darwin" ] }
        // icon.png intentionally omitted for now — add as a second ESZip entry later.
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest
                    options:NSJSONWritingPrettyPrinted error:NULL];
    return [ESZip archiveWithEntries:@[ @{ @"name": @"manifest.json", @"data": json } ]];
}

#pragma mark - Claude Desktop

// Resolve Claude Desktop by bundle identifier — NEVER by file-type handler.
// Launch Services hands the .skill (and potentially .mcpb) default to
// whichever app registered it last; ChatGPT also claims .skill, so the
// "registered handler" lookup can hijack the handoff. The install target is
// Claude Desktop by definition, so ask for it by name.
+ (nullable NSURL *)claudeDesktopURL {
    return [NSWorkspace.sharedWorkspace
            URLForApplicationWithBundleIdentifier:@"com.anthropic.claudefordesktop"];
}

+ (void)connectToClaudeDesktopFromWindow:(NSWindow *)window {
    // Generate the connector in-process (ESZip) against our own path, write it to
    // a stable app-owned folder, and hand it to Claude Desktop's file handler.
    NSData *mcpb = [self connectorMCPBData];
    if (mcpb.length == 0) {
        [self presentAlert:@"Couldn’t build the connector" info:@"" window:window revealURL:nil];
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil create:YES error:NULL];
    NSURL *folder = [appSupport URLByAppendingPathComponent:@"ES Archive" isDirectory:YES];
    [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *handoff = [folder URLByAppendingPathComponent:@"ES-Archive-MCP-connector.mcpb"];

    NSError *writeErr = nil;
    if (![mcpb writeToURL:handoff options:NSDataWritingAtomic error:&writeErr]) {
        [self presentAlert:@"Couldn’t prepare the connector"
                      info:writeErr.localizedDescription window:window revealURL:nil];
        return;
    }

    NSURL *claude = [self claudeDesktopURL];
    if (!claude) {                   // Claude Desktop not installed → Finder reveal
        [self presentAlert:@"Couldn’t reach Claude Desktop"
                      info:@"Make sure Claude Desktop is installed, then double-click "
                           @"the connector we’ve revealed in Finder."
                    window:window revealURL:handoff];
        return;
    }

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;             // bring Claude Desktop forward for its prompt
    cfg.addsToRecentItems = NO;

    [NSWorkspace.sharedWorkspace openURLs:@[ handoff ] withApplicationAtURL:claude
                            configuration:cfg
                        completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) {                 // Claude Desktop refused → degrade to a Finder reveal
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentAlert:@"Couldn’t reach Claude Desktop"
                              info:@"Make sure Claude Desktop is installed, then double-click "
                                   @"the connector we’ve revealed in Finder."
                            window:window revealURL:handoff];
            });
        }
    }];
}

#pragma mark - LM Studio / generic stdio hosts

+ (NSString *)lmStudioConfigJSON {
    // No --author here: LM Studio may run any model. Omitted → stored as "anonymous"
    // once the engine ships --author; the user can add @[ @"--author", @"<model>" ].
    NSDictionary *config = @{
        @"mcpServers": @{
            @"es-archive": @{
                @"command": [self serverExecutablePath],
                @"args": @[]
            }
        }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                      error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (void)copyLMStudioConfigToPasteboard {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[self lmStudioConfigJSON] forType:NSPasteboardTypeString];
}

#pragma mark - Helpers

+ (void)presentAlert:(NSString *)message
                info:(NSString *)info
              window:(NSWindow *)window
           revealURL:(NSURL *)revealURL {
    if (revealURL) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[revealURL]];
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info ?: @"";
    [alert addButtonWithTitle:@"OK"];
    if (window) [alert beginSheetModalForWindow:window completionHandler:nil];
    else        [alert runModal];
}

@end
