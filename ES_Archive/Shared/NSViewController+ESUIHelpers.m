//
//  NSViewController+ESUIHelpers.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "NSViewController+ESUIHelpers.h"

@implementation NSViewController (ESUIHelpers)

- (NSTextField *)es_labelWithString:(NSString *)string {
    NSTextField *t = [NSTextField labelWithString:string];
    t.lineBreakMode = NSLineBreakByWordWrapping;
    return t;
}

- (void)es_presentWarningTitle:(NSString *)title message:(NSString *)message {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = title;
    a.informativeText = message;
    a.alertStyle      = NSAlertStyleWarning;
    [a addButtonWithTitle:@"OK"];
    if (self.view.window) {
        [a beginSheetModalForWindow:self.view.window completionHandler:nil];
    } else {
        [a runModal];
    }
}

- (void)es_relaunchApplication {
    // Each copy of this logged under its own prefix; the class name keeps that
    // context without needing a constant per pane.
    NSString *who = NSStringFromClass(self.class);
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:bundleURL
                                          configuration:cfg
                                      completionHandler:^(NSRunningApplication *app, NSError *err) {
        if (err) {
            NSLog(@"[%@] relaunch failed: %@", who, err);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
    }];
}

@end
