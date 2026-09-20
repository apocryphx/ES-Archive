//
//  ESOnboardingWindowController.h
//  ES Archive — standalone UI
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The Connect window's shared shell: title, blurb and the "Show at next
/// startup" footer — everything true of both apps.
///
/// ABSTRACT in practice. Each app opens its own subclass, and which one it opens
/// is settled by target membership rather than a runtime check:
/// ESStdioConnectController (MCP app) offers the Claude Desktop connector and an
/// stdio mcp.json; ESHTTPConnectController (Server app) offers an HTTP mcp.json
/// with a persona picker. The split exists because the two apps are reached in
/// fundamentally different ways — the MCP binary IS the stdio server, while the
/// Server binary excludes the Stdio sources and is reached over localhost HTTP.
/// Handing either app the other's configuration produces a client that connects
/// to nothing, which is what the Server app did before this split.
///
/// Subclasses add their sections through -addSectionsToStack:, building controls
/// with the factories below.
@interface ESOnboardingWindowController : NSWindowController

/// Show the window unconditionally. Send to a SUBCLASS — the instance is cached
/// per class, so each app gets and reuses its own.
+ (void)show;

/// Show it at launch only if the user hasn't turned off "Show at next startup"
/// (default on). Call from applicationDidFinishLaunching in user (full-UI) mode.
+ (void)showAtStartupIfEnabled;

#pragma mark - Subclass hook

/// The app's connection sections, in order. The base adds nothing — it owns
/// only the chrome around them.
- (void)addSectionsToStack:(NSStackView *)stack;

#pragma mark - Shared view factories

/// Spacing + divider that opens a new section. Call before a section header.
- (void)beginSectionInStack:(NSStackView *)stack;

- (NSTextField *)sectionHeader:(NSString *)string;
- (NSTextField *)bodyLabel:(NSString *)string;
- (NSBox *)separator;

/// A visually distinct onboarding card. The eyebrow is a short orienting label
/// such as "STEP 1" or "OPTIONAL"; the supplied views become the card body.
- (NSView *)cardWithEyebrow:(NSString *)eyebrow
                      title:(NSString *)title
                 symbolName:(NSString *)symbolName
                accentColor:(NSColor *)accentColor
               contentViews:(NSArray<NSView *> *)contentViews;

/// The "Install Claude Skills" card, shared by both apps: a short pitch and a
/// button that opens ESSkillInstallController. Subclasses add it where it
/// reads best in their section order.
- (NSView *)skillsCard;

/// A read-only monospaced box for a configuration snippet. The text view is
/// held in -jsonTextView so a subclass can re-render it (the HTTP pane rewrites
/// its JSON when the persona changes).
- (NSScrollView *)jsonBoxWithString:(NSString *)json;
@property (weak, nullable) NSTextView *jsonTextView;

/// Momentarily swap a button's title (e.g. "Copied ✓") and restore it — the
/// acknowledgment gesture shared by every action in this window.
- (void)flashButton:(NSButton *)button title:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
