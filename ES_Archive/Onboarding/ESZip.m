//
//  ESZip.m
//  ES Archive
//

#import "ESZip.h"

// Standard CRC-32 (ISO 3309 / used by ZIP, zlib, PNG): reflected poly 0xEDB88320,
// init 0xFFFFFFFF, final XOR 0xFFFFFFFF. Matches zlib's crc32() and binascii.crc32.
static uint32_t es_crc32(const uint8_t *bytes, NSUInteger len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (NSUInteger i = 0; i < len; i++) {
        crc ^= bytes[i];
        for (int k = 0; k < 8; k++) {
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

// Little-endian appenders — ZIP is little-endian on every field.
static void put16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff) };
    [d appendBytes:b length:2];
}
static void put32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff),
                     (uint8_t)((v >> 16) & 0xff), (uint8_t)((v >> 24) & 0xff) };
    [d appendBytes:b length:4];
}

@implementation ESZip

+ (NSData *)archiveWithEntries:(NSArray<NSDictionary *> *)entries {
    NSMutableData *out = [NSMutableData data];      // local headers + file data
    NSMutableData *central = [NSMutableData data];  // central directory, appended after
    uint16_t count = 0;

    for (NSDictionary *entry in entries) {
        NSString *name = entry[@"name"];
        NSData *data = entry[@"data"];
        if (name.length == 0 || data == nil) continue;

        NSData *fn = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = es_crc32((const uint8_t *)data.bytes, data.length);
        uint32_t sz  = (uint32_t)data.length;
        uint16_t fnlen = (uint16_t)fn.length;
        uint32_t localOffset = (uint32_t)out.length;

        // --- Local file header (0x04034b50) ---
        put32(out, 0x04034b50);
        put16(out, 20);        // version needed to extract (2.0)
        put16(out, 0);         // general purpose flags
        put16(out, 0);         // compression method: 0 = STORE
        put16(out, 0);         // last mod time
        put16(out, 0x21);      // last mod date = 1980-01-01
        put32(out, crc);
        put32(out, sz);        // compressed size (== uncompressed for STORE)
        put32(out, sz);        // uncompressed size
        put16(out, fnlen);
        put16(out, 0);         // extra field length
        [out appendData:fn];
        [out appendData:data];

        // --- Central directory header (0x02014b50) ---
        put32(central, 0x02014b50);
        put16(central, 20);    // version made by
        put16(central, 20);    // version needed
        put16(central, 0);     // flags
        put16(central, 0);     // method: STORE
        put16(central, 0);     // mod time
        put16(central, 0x21);  // mod date
        put32(central, crc);
        put32(central, sz);
        put32(central, sz);
        put16(central, fnlen);
        put16(central, 0);     // extra len
        put16(central, 0);     // comment len
        put16(central, 0);     // disk number start
        put16(central, 0);     // internal attributes
        put32(central, 0);     // external attributes
        put32(central, localOffset);
        [central appendData:fn];

        count++;
    }

    uint32_t cdOffset = (uint32_t)out.length;
    [out appendData:central];

    // --- End of central directory (0x06054b50) ---
    put32(out, 0x06054b50);
    put16(out, 0);                       // this disk number
    put16(out, 0);                       // disk with central directory
    put16(out, count);                   // central directory records on this disk
    put16(out, count);                   // total central directory records
    put32(out, (uint32_t)central.length);// size of central directory
    put32(out, cdOffset);                // offset of central directory
    put16(out, 0);                       // .zip comment length

    return out;
}

@end
