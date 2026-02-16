# E02: Binary Protocol Parser

> Parse a custom binary protocol from raw bytes. This exercise teaches you to read fixed-width headers, variable-length payloads, and checksums — the foundation of every network protocol, file format, and IPC mechanism.

## Objective

Design and implement a parser for a custom binary protocol called "NodeMsg." You will construct binary messages by hand, then write a parser that validates magic bytes, reads multi-byte integers from the header, extracts the payload, and verifies a CRC32 checksum. This is exactly how real protocols like TCP, HTTP/2 frames, and PNG chunks work under the hood.

## Prerequisites

- Module 03, Lesson 01 (Binary Number Systems)
- Module 03, Lesson 02 (Hexadecimal and Octal)
- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 03, Lesson 06 (Buffer Slicing and Copying)

## Instructions

1. **Define the NodeMsg protocol.** The message format is:

   | Field          | Offset | Size    | Type     | Description                   |
   |----------------|--------|---------|----------|-------------------------------|
   | Magic bytes    | 0      | 2 bytes | Fixed    | `0x4E 0x4D` ("NM")           |
   | Version        | 2      | 1 byte  | UInt8    | Protocol version (1)          |
   | Message type   | 3      | 1 byte  | UInt8    | 0=ping, 1=text, 2=binary     |
   | Payload length | 4      | 4 bytes | UInt32BE | Length of payload in bytes    |
   | Payload        | 8      | N bytes | Raw      | The message payload           |
   | CRC32          | 8+N    | 4 bytes | UInt32BE | CRC32 of bytes 0 through 7+N |

2. **Create `protocol.js`** with `'use strict';` and require `node:buffer` and `node:zlib`.

3. **Implement `crc32(buf)`.** Use the standard CRC32 lookup table approach. Initialize with `0xFFFFFFFF`, XOR each byte through the table, then final XOR with `0xFFFFFFFF`. Return as unsigned 32-bit integer. Alternatively, use `node:zlib`'s `zlib.crc32(buf)` if available (Node.js 22.12+), or build the table yourself.

4. **Implement `encodeMessage(type, payload)`.** Allocate a Buffer of `8 + payload.length + 4` bytes. Write the magic bytes, version, type, and payload length into the header. Copy the payload after the header. Compute CRC32 over everything except the last 4 bytes, then write the checksum at the end.

5. **Implement `decodeMessage(buf)`.** Parse in this order:
   - Validate magic bytes (`0x4E4D`). Throw if wrong.
   - Read version. Throw if not `1`.
   - Read message type. Throw if not 0, 1, or 2.
   - Read payload length as UInt32BE.
   - Validate that `buf.length === 8 + payloadLength + 4`. Throw if sizes mismatch.
   - Extract the payload slice.
   - Read the stored CRC32 from the last 4 bytes.
   - Compute CRC32 over `buf.subarray(0, buf.length - 4)`.
   - Compare computed vs stored. Throw if mismatch.
   - Return `{ version, type, payload }`.

6. **Write a test harness.** Create 3 messages (one ping, one text, one binary), encode each, decode each, and verify the round-trip.

7. **Test with corrupted data.** Flip a single bit in the payload of an encoded message and verify that `decodeMessage` throws a CRC mismatch error.

8. **Handle multiple messages in a stream buffer.** Write a `parseStream(buf)` function that extracts all complete messages from a Buffer that may contain multiple concatenated messages. Return an array of decoded messages and the remaining bytes (incomplete message prefix).

Here is the CRC32 table generation to get you started:

```javascript
function buildCRC32Table() {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 1) ? (0xEDB88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
    table[i] = crc;
  }
  return table;
}

const CRC_TABLE = buildCRC32Table();

function crc32(buf) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) {
    crc = CRC_TABLE[(crc ^ buf[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0; // unsigned
}
```

And the message type constants:

```javascript
const MSG_TYPES = { PING: 0, TEXT: 1, BINARY: 2 };
const MSG_TYPE_NAMES = { 0: 'ping', 1: 'text', 2: 'binary' };
const MAGIC = Buffer.from([0x4E, 0x4D]);
const VERSION = 1;
const HEADER_SIZE = 8; // magic(2) + version(1) + type(1) + length(4)
const CRC_SIZE = 4;
```

## Break-Then-Harden Challenge

### Scenario 1 — Endianness Mismatch
Change `writeUInt32BE` to `writeUInt32LE` in the encoder but keep `readUInt32BE` in the decoder. Observe the wildly wrong payload length. Fix by ensuring both sides agree on byte order, and add a constant `BYTE_ORDER = 'BE'` to make the choice explicit.

### Scenario 2 — Buffer Overread
Craft a malicious message where the payload length field claims 1,000,000 bytes but the actual buffer is only 20 bytes. Pass it to `decodeMessage`. Observe the crash or garbage data. Fix by validating `buf.length >= 8 + payloadLength + 4` before reading the payload.

### Scenario 3 — Shared Memory Slice Bug
Use `buf.slice()` (which shares memory) for the payload extraction. Modify the original buffer after decoding. Observe the decoded payload changes too. Fix by using `Buffer.from(buf.subarray(start, end))` to create an independent copy.

## Expected Output

```
$ node protocol.js
Encoding ping message...
  Encoded: <Buffer 4e 4d 01 00 00 00 00 00 a3 b2 c1 d0>

Encoding text message: "Hello, NodeMsg!"
  Encoded: <Buffer 4e 4d 01 01 00 00 00 0f 48 65 6c 6c 6f 2c 20 4e 6f 64 65 4d 73 67 21 xx xx xx xx>

Decoding text message...
  Version: 1
  Type: 1 (text)
  Payload: Hello, NodeMsg!

Corruption test...
  Flipped bit in byte 10
  Error: CRC32 mismatch: expected 0xaabbccdd, got 0x11223344

Stream parsing test...
  Found 3 complete messages, 0 remaining bytes
```

## Bonus

1. **Add a timestamp field.** Extend the header with an 8-byte `BigUInt64BE` timestamp (milliseconds since epoch) between the payload length and the payload. Update both encoder and decoder.

2. **Implement message fragmentation.** Add a "fragment" message type (type=3) with a sequence number (UInt16BE) and total fragments count. Write `fragmentMessage(type, payload, maxChunkSize)` and `reassembleFragments(fragments)`.

3. **Add protocol negotiation.** Implement a handshake message (type=255) where client and server exchange supported versions and capabilities. The response includes a bitmask of features (compression, encryption, etc.).

## Why This Matters

Every network protocol you use daily follows this exact pattern:

- **HTTP/2 frames:** 9-byte header (length UInt24, type UInt8, flags UInt8, stream ID UInt31) + payload
- **WebSocket frames:** 2-byte header (FIN bit, opcode, mask bit, payload length) + optional extended length + optional mask + payload
- **TCP segments:** 20+ byte header with source/dest ports, sequence numbers, flags, checksum
- **PNG chunks:** 4-byte length + 4-byte type + data + 4-byte CRC32

By building your own protocol parser, you gain the skills to debug any of these at the byte level.

## Hints

1. `Buffer.from([0x4E, 0x4D])` creates the magic bytes. Compare with `buf[0] === 0x4E && buf[1] === 0x4D`.

2. The CRC32 lookup table has 256 entries. Each entry is computed by shifting and XORing with the polynomial `0xEDB88320`.

3. `buf.subarray(start, end)` returns a view (shared memory). `Buffer.from(buf.subarray(start, end))` returns an independent copy.

4. For `parseStream`, read the payload length at offset 4 to compute the total message size (`8 + payloadLength + 4`), then check if the buffer has enough bytes. If yes, slice it out and recurse. If no, return the remainder.

5. Always validate the buffer has enough bytes before calling any `readUInt*` method. A `RangeError` from reading past the end is a security vulnerability in protocol parsers.
