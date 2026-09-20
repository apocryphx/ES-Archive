//
//  ESConnectHelper.m
//  ES Archive
//

#import "ESConnectHelper.h"
#import "ESZip.h"

@interface ESConnectHelper ()
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
    // Claude Desktop connector is, by definition, Claude — stated explicitly even
    // though the engine's default author is already "Claude", so the connector
    // reads the same as every other client's configuration.
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

+ (NSURL *)appSupportFolder {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil create:YES error:NULL];
    NSURL *folder = [appSupport URLByAppendingPathComponent:@"ES Archive" isDirectory:YES];
    [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    return folder;
}

+ (void)openInClaudeDesktop:(NSArray<NSURL *> *)files
                 fromWindow:(nullable NSWindow *)window
                    failure:(NSString *)failureMessage {
    NSURL *claude = [self claudeDesktopURL];
    NSString *info = [failureMessage stringByAppendingString:
        @" Make sure Claude Desktop is installed, then double-click the file we’ve revealed in Finder."];
    if (!claude) {                   // Claude Desktop not installed → Finder reveal
        [self presentAlert:@"Couldn’t reach Claude Desktop" info:info
                    window:window revealURL:files.firstObject];
        return;
    }

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;             // bring Claude Desktop forward for its prompt
    cfg.addsToRecentItems = NO;

    [NSWorkspace.sharedWorkspace openURLs:files withApplicationAtURL:claude
                            configuration:cfg
                        completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) {                 // Claude Desktop refused → degrade to a Finder reveal
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentAlert:@"Couldn’t reach Claude Desktop" info:info
                            window:window revealURL:files.firstObject];
            });
        }
    }];
}

+ (void)connectToClaudeDesktopFromWindow:(NSWindow *)window {
    // Generate the connector in-process (ESZip) against our own path, write it to
    // a stable app-owned folder, and hand it to Claude Desktop's file handler.
    NSData *mcpb = [self connectorMCPBData];
    if (mcpb.length == 0) {
        [self presentAlert:@"Couldn’t build the connector" info:@"" window:window revealURL:nil];
        return;
    }

    NSURL *handoff = [[self appSupportFolder]
        URLByAppendingPathComponent:@"ES-Archive-MCP-connector.mcpb"];
    NSError *writeErr = nil;
    if (![mcpb writeToURL:handoff options:NSDataWritingAtomic error:&writeErr]) {
        [self presentAlert:@"Couldn’t prepare the connector"
                      info:writeErr.localizedDescription window:window revealURL:nil];
        return;
    }
    [self openInClaudeDesktop:@[ handoff ] fromWindow:window
                      failure:@"The connector could not be handed to Claude Desktop."];
}

#pragma mark - LM Studio / generic stdio hosts

NSString * const ESLMStudioDefaultAuthor = @"LM Studio";

+ (NSString *)lmStudioConfigJSON {
    // --author is load-bearing: without it the engine stamps the target default
    // ("Claude"), and a local model's entries would land in Claude's persona.
    // LM Studio may run any model, so the persona is the client, not a model;
    // the user edits the value if they want a per-model name.
    NSDictionary *config = @{
        @"mcpServers": @{
            @"es-archive": @{
                @"command": [self serverExecutablePath],
                @"args": @[ @"--author", ESLMStudioDefaultAuthor ]
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

#pragma mark - ChatGPT desktop

NSString * const ESChatGPTDefaultAuthor = @"ChatGPT";

static NSString *ESShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'",
        [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"]];
}

+ (NSString *)chatGPTSetupCommand {
    // The current ChatGPT desktop app retains Codex's bundle identifier.
    // Resolve it through Launch Services so non-/Applications installs work.
    NSURL *app = [NSWorkspace.sharedWorkspace
        URLForApplicationWithBundleIdentifier:@"com.openai.codex"];
    NSString *bundledCLI = [[app URLByAppendingPathComponent:@"Contents/Resources/codex"] path];
    NSString *cli = bundledCLI && [NSFileManager.defaultManager isExecutableFileAtPath:bundledCLI]
        ? ESShellQuote(bundledCLI) : @"codex";
    return [NSString stringWithFormat:@"%@ mcp add es-archive -- %@ --author %@",
        cli, ESShellQuote([self serverExecutablePath]), ESShellQuote(ESChatGPTDefaultAuthor)];
}

+ (void)copyServerExecutablePathToPasteboard {
    // ChatGPT's "Connect to a custom MCP" dialog is a form, not a JSON file:
    // the command and each argument are separate fields. Only the path needs
    // copying; the two arguments are short enough to type.
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[self serverExecutablePath] forType:NSPasteboardTypeString];
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
