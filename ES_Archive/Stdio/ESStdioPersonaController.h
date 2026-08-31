//
//  ESStdioPersonaController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Slim persona management for the UDS/stdio host.
//
//  The HTTP Server target manages personas through the full two-pane split
//  (ESAuthorConfigController + ESPortConfigController): create, rename, merge,
//  delete, and per-port bindings. None of that applies over the socket: a
//  stdio session declares its persona per connection (--author), there are no
//  listening ports to bind and no reason to pre-create an empty persona. What
//  remains useful is housekeeping over the personas that already exist in the
//  archive — so this surface offers exactly two operations:
//
//    • Delete  — remove a persona together with every record it authored.
//    • Merge   — re-stamp one persona's records onto another, retiring it.
//
//  Both operate directly on the host's Core Data stack (this window is only
//  ever raised by the elected host, which owns the engine — relays stay
//  headless), the same assumption the Settings / Archive Scope / Backup menu
//  items already make.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESStdioPersonaController : NSViewController

/// Present the persona window (creating it once), activating the app first —
/// accessory hosts open panels behind the frontmost app otherwise.
+ (void)showPersonas;

@end

NS_ASSUME_NONNULL_END
