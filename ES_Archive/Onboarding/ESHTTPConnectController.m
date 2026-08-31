//
//  ESHTTPConnectController.m
//  ES Archive Server
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESHTTPConnectController.h"
#import "ESServerConfig.h"

@interface ESHTTPConnectController ()
/// Bound ports, ascending. Index-aligned with the persona popup's items.
@property (strong) NSArray<NSNumber *> *ports;
@property (weak) NSPopUpButton *personaPopup;
@property (weak) NSTextField *jwtCaption;
@property (weak) NSButton *configCopyButton;   // not "copyButton": ARC reads a leading "copy" as the copy method family
@end

@implementation ESHTTPConnectController

- (void)addSectionsToStack:(NSStackView *)stack {
    NSTextField *manualCopy = [self bodyLabel:
        @"Choose the persona this client writes as, then copy its local HTTP configuration. "
        @"Manage personas and ports in Settings ▸ Ports."];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.target = self;
    popup.action = @selector(personaChanged:);
    self.personaPopup = popup;
    [self reloadPersonaChoices];
    NSScrollView *json = [self jsonBoxWithString:[self configJSONForSelectedPort]];

    // Only shown when the chosen port is gated — the config alone will not
    // connect in that case, and the failure is otherwise silent.
    NSTextField *caption = [self bodyLabel:@""];
    caption.textColor = NSColor.systemOrangeColor;
    self.jwtCaption = caption;
    NSButton *copy = [NSButton buttonWithTitle:@"Copy MCP Configuration"
                                        target:self action:@selector(copyConfiguration:)];
    copy.bezelStyle = NSBezelStyleRounded;
    self.configCopyButton = copy;
    NSView *manualCard = [self cardWithEyebrow:@"LOCAL HTTP"
                                        title:@"Connect an MCP client"
                                   symbolName:@"network"
                                  accentColor:NSColor.systemTealColor
                                 contentViews:@[manualCopy, popup, json, caption, copy]];
    [stack addArrangedSubview:manualCard];

    [self refreshForSelectedPort];
}

/// Ports can be added, rebound or removed in Settings while this window sits
/// closed, so rebuild the list every time it opens rather than only at init.
- (void)showWindow:(id)sender {
    [self reloadPersonaChoices];
    [self refreshForSelectedPort];
    [super showWindow:sender];
}

#pragma mark - Persona ▸ port

- (void)reloadPersonaChoices {
    // portAuthorMap injects the Claude bridge entry on read while the bridge is
    // enabled, so this is the whole set of live bindings — no separate case.
    NSDictionary<NSNumber *, NSString *> *map = [ESServerConfig portAuthorMap];
    NSArray<NSNumber *> *ports = [map.allKeys sortedArrayUsingSelector:@selector(compare:)];
    self.ports = ports;

    NSString *previous = self.personaPopup.titleOfSelectedItem;
    [self.personaPopup removeAllItems];
    for (NSNumber *port in ports) {
        NSString *author = map[port];
        [self.personaPopup addItemWithTitle:
            [NSString stringWithFormat:@"%@ — port %u", author, port.unsignedIntValue]];
    }
    if (ports.count == 0) {
        // No bound ports at all: the server has nothing to hand a client.
        [self.personaPopup addItemWithTitle:@"No ports bound — see Settings ▸ Ports"];
        self.personaPopup.enabled = NO;
    } else {
        self.personaPopup.enabled = YES;
        if (previous) [self.personaPopup selectItemWithTitle:previous];   // no-op if it's gone
    }
}

- (UInt16)selectedPort {
    NSInteger index = self.personaPopup.indexOfSelectedItem;
    if (index < 0 || (NSUInteger)index >= self.ports.count) return 0;
    return (UInt16)self.ports[index].unsignedIntValue;
}

- (void)personaChanged:(id)sender {
    [self refreshForSelectedPort];
}

- (void)refreshForSelectedPort {
    self.jsonTextView.string = [self configJSONForSelectedPort];

    UInt16 port = [self selectedPort];
    BOOL gated = (port != 0) && [ESServerConfig requiresJWTForPort:port];
    self.jwtCaption.stringValue = gated
        ? [NSString stringWithFormat:
           @"Port %u requires a Cf-Access-Jwt-Assertion header. This configuration alone will "
           @"not connect — the client has to send that header too.", (unsigned)port]
        : @"";
    self.configCopyButton.enabled = (port != 0);
}

#pragma mark - Configuration

/// The persona's name becomes the server key, so configurations for two personas
/// can be pasted into the same mcp.json without one overwriting the other.
- (NSString *)serverKeyForAuthor:(NSString *)author {
    NSMutableString *slug = [NSMutableString string];
    for (NSString *component in [author.lowercaseString
                                 componentsSeparatedByCharactersInSet:
                                 NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
        if (component.length == 0) continue;
        [slug appendFormat:@"%@%@", (slug.length ? @"-" : @""), component];
    }
    return slug.length ? [NSString stringWithFormat:@"es-archive-%@", slug] : @"es-archive";
}

- (NSString *)configJSONForSelectedPort {
    UInt16 port = [self selectedPort];
    if (port == 0) {
        return @"No ports are bound yet.\n"
               @"Add one in Settings ▸ Ports, then reopen this window.";
    }
    NSString *author = [ESServerConfig authorForPort:port] ?: @"";
    NSDictionary *config = @{
        @"mcpServers": @{
            [self serverKeyForAuthor:author]: @{
                @"url": [NSString stringWithFormat:@"http://localhost:%u/mcp", (unsigned)port]
            }
        }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                      error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)copyConfiguration:(NSButton *)sender {
    if ([self selectedPort] == 0) return;
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[self configJSONForSelectedPort] forType:NSPasteboardTypeString];
    [self flashButton:sender title:@"Copied ✓"];
}

@end
