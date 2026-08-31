//
//  NSViewController+ESUIHelpers.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Three helpers that every code-built settings pane had its own identical copy
/// of. Prefixed, as category methods on a framework class should be, so they can
/// never collide with something AppKit adds later.
@interface NSViewController (ESUIHelpers)

/// A wrapping label. AppKit's +[NSTextField labelWithString:] does not wrap,
/// which matters for the explanatory blurbs on the settings panes.
- (NSTextField *)es_labelWithString:(NSString *)string;

/// A warning alert, as a sheet on this controller's window when it has one and
/// modally when it does not (a pane can raise one before it is on screen).
- (void)es_presentWarningTitle:(NSString *)title message:(NSString *)message;

/// Relaunch the app: open a second instance, then terminate this one once it is
/// up. Settings that only take effect at launch — activation mode, port
/// bindings, persona re-stamping — offer this after applying.
- (void)es_relaunchApplication;

@end

NS_ASSUME_NONNULL_END
