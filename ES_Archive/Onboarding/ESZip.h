//
//  ESZip.h
//  ES Archive
//
//  Minimal STORE-method (uncompressed) PKZIP writer — dependency-free, sandbox-safe,
//  pure NSData byte assembly. Purpose-built for tiny payloads like an .mcpb
//  (manifest.json [+ icon.png] at the archive root). No compression, no zlib, no
//  AppleArchive (which only emits .aar) — a real PKZIP zip Claude Desktop can read.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESZip : NSObject

/// Build an uncompressed PKZIP archive from ordered, root-level entries.
/// @param entries ordered array of @{ @"name": NSString*, @"data": NSData* }.
+ (NSData *)archiveWithEntries:(NSArray<NSDictionary *> *)entries;

@end

NS_ASSUME_NONNULL_END
