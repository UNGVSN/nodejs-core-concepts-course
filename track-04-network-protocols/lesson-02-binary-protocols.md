# Track 04 / Lesson 02 — Binary Protocol Implementation

> Text protocols are easy to debug with `curl` and `nc`. Binary protocols are what you build when you need to move millions of messages per second and every wasted byte matters. This lesson builds a complete binary protocol from scratch — magic bytes, length headers, TLV payloads, CRC checksums — using nothing but `Buffer` operations and raw TCP sockets.

## Learning Objectives

- Implement length-prefixed message framing with a 4-byte UInt32BE header and a configurable maximum payload size
- Build a Type-Length-Value (TLV) encoder and decoder that handles nested fields, integers, and variable-length strings
- Add magic bytes to the protocol header for stream identification and corruption detection at connection time
- Compute and verify CRC32 checksums to detect data corruption on the wire
- Handle partial reads with a buffering strategy that correctly reassembles fragmented TCP data into complete protocol frames

---

## Protocol Wire Format

Before writing code, define the wire format. Every message on the wire follows this structure:

```
+--------+--------+--------+--------+---------+-----------+
| Magic  | Flags  | Length (UInt32) | Payload | CRC32     |
| 2 bytes| 1 byte | 4 bytes        | N bytes | 4 bytes   |
+--------+--------+--------+--------+---------+-----------+
  0xCA FE   0x00    N (big-endian)   TLV data  checksum
```

- **Magic bytes** (2): `0xCA 0xFE` — identifies this as our protocol
- **Flags** (1): bit field for compression, encryption, etc.
- **Length** (4): payload size in bytes (UInt32BE), max 16 MB
- **Payload** (N): TLV-encoded fields
- **CRC32** (4): checksum of flags + length + payload

Total overhead per message: 11 bytes (header + trailer).

---

## CRC32 Checksum Implementation

CRC32 detects accidental corruption. We implement it from scratch — no npm packages.

```javascript
'use strict';

// CRC32 lookup table (IEEE 802.3 polynomial: 0xEDB88320)
const CRC32_TABLE = new Uint32Array(256);

(function buildTable() {
  for (let i = 0; i < 256; i++) {
    let crc = i;
    for (let j = 0; j < 8; j++) {
      if (crc & 1) {
        crc = (crc >>> 1) ^ 0xEDB88320;
      } else {
        crc = crc >>> 1;
      }
    }
    CRC32_TABLE[i] = crc >>> 0; // Force unsigned
  }
})();

function crc32(buf) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) {
    const index = (crc ^ buf[i]) & 0xFF;
    crc = (crc >>> 8) ^ CRC32_TABLE[index];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0; // Final XOR, force unsigned
}

// Verify
const testBuf = Buffer.from('123456789', 'ascii');
const result = crc32(testBuf);
console.log(`CRC32("123456789") = 0x${result.toString(16).toUpperCase()}`);
// Expected: 0xCBF43926 (standard CRC32 test vector)
```

The lookup table makes CRC32 fast — O(n) with a single table lookup per byte instead of 8 shifts per byte.

---

## The Encoder Class

The encoder takes a message object, encodes it as TLV fields, wraps it in the protocol frame, and appends a CRC32 checksum.

```javascript
'use strict';

const MAGIC = Buffer.from([0xCA, 0xFE]);
const HEADER_SIZE = 7; // 2 magic + 1 flags + 4 length
const CRC_SIZE = 4;
const MAX_PAYLOAD = 16 * 1024 * 1024; // 16 MB

// Flag bits
const FLAG_NONE       = 0x00;
const FLAG_COMPRESSED = 0x01;
const FLAG_ENCRYPTED  = 0x02;
const FLAG_URGENT     = 0x04;

// TLV type constants
const TLV = {
  MESSAGE_TYPE:    0x0001,
  CORRELATION_ID:  0x0002,
  TIMESTAMP:       0x0003,
  BODY:            0x0004,
  ERROR_CODE:      0x0005,
  HEADERS:         0x0006,
};

// TLV encoding helpers
function encodeTLV(type, value) {
  const valueBuf = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');

  if (valueBuf.length > 0xFFFF) {
    throw new Error(`TLV value too large: ${valueBuf.length} bytes (max 65535)`);
  }

  const buf = Buffer.alloc(4 + valueBuf.length);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(valueBuf.length, 2);
  valueBuf.copy(buf, 4);
  return buf;
}

function encodeTLVUInt8(type, value) {
  const buf = Buffer.alloc(4 + 1);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(1, 2);
  buf.writeUInt8(value, 4);
  return buf;
}

function encodeTLVUInt16(type, value) {
  const buf = Buffer.alloc(4 + 2);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(2, 2);
  buf.writeUInt16BE(value, 4);
  return buf;
}

function encodeTLVUInt64(type, value) {
  const buf = Buffer.alloc(4 + 8);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(8, 2);
  buf.writeBigUInt64BE(BigInt(value), 4);
  return buf;
}

class ProtocolEncoder {
  constructor(flags = FLAG_NONE) {
    this.flags = flags;
  }

  encode(message) {
    // Build the TLV payload
    const parts = [];

    if (message.type !== undefined) {
      parts.push(encodeTLVUInt8(TLV.MESSAGE_TYPE, message.type));
    }

    if (message.correlationId) {
      parts.push(encodeTLV(TLV.CORRELATION_ID, message.correlationId));
    }

    if (message.timestamp !== undefined) {
      parts.push(encodeTLVUInt64(TLV.TIMESTAMP, message.timestamp));
    }

    if (message.body !== undefined) {
      const bodyBuf = typeof message.body === 'string'
        ? Buffer.from(message.body, 'utf8')
        : Buffer.from(JSON.stringify(message.body), 'utf8');
      parts.push(encodeTLV(TLV.BODY, bodyBuf));
    }

    if (message.errorCode !== undefined) {
      parts.push(encodeTLVUInt16(TLV.ERROR_CODE, message.errorCode));
    }

    if (message.headers) {
      const headerJson = Buffer.from(JSON.stringify(message.headers), 'utf8');
      parts.push(encodeTLV(TLV.HEADERS, headerJson));
    }

    const payload = Buffer.concat(parts);

    if (payload.length > MAX_PAYLOAD) {
      throw new Error(`Payload exceeds maximum size: ${payload.length} > ${MAX_PAYLOAD}`);
    }

    // Build the frame: magic + flags + length + payload + crc
    const header = Buffer.alloc(HEADER_SIZE);
    MAGIC.copy(header, 0);
    header.writeUInt8(this.flags, 2);
    header.writeUInt32BE(payload.length, 3);

    // CRC covers flags + length + payload (not magic bytes)
    const crcInput = Buffer.concat([header.subarray(2), payload]);
    const checksum = crc32(crcInput);

    const crcBuf = Buffer.alloc(CRC_SIZE);
    crcBuf.writeUInt32BE(checksum, 0);

    return Buffer.concat([header, payload, crcBuf]);
  }
}

// Import crc32 from above (in a real project, this would be a shared module)
// For this example, the crc32 function is defined in the same file.

// CRC32 lookup table
const CRC32_TABLE = new Uint32Array(256);
(function buildTable() {
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) {
      c = (c & 1) ? ((c >>> 1) ^ 0xEDB88320) : (c >>> 1);
    }
    CRC32_TABLE[i] = c >>> 0;
  }
})();

function crc32(buf) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) {
    crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ buf[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

// Demo
const encoder = new ProtocolEncoder();
const frame = encoder.encode({
  type: 0x01,           // REQUEST
  correlationId: 'req-001',
  timestamp: Date.now(),
  body: { action: 'getUser', userId: 42 },
  headers: { 'content-type': 'application/json' },
});

console.log('Frame size:', frame.length, 'bytes');
console.log('Frame (hex):', frame.toString('hex'));
```

---

## The Decoder Class

The decoder handles the inverse operation: reading the frame header, validating magic bytes and CRC, and parsing TLV fields from the payload.

```javascript
'use strict';

class ProtocolDecoder {
  constructor() {
    this.buffer = Buffer.alloc(0);
  }

  // Feed raw TCP data into the decoder. Returns an array of decoded messages.
  feed(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const messages = [];

    while (true) {
      const msg = this.tryDecode();
      if (msg === null) break;
      messages.push(msg);
    }

    return messages;
  }

  tryDecode() {
    // Need at least the header to proceed
    if (this.buffer.length < HEADER_SIZE) {
      return null;
    }

    // Validate magic bytes
    if (this.buffer[0] !== 0xCA || this.buffer[1] !== 0xFE) {
      // Attempt recovery: scan forward for the next magic sequence
      const magicIdx = this.findMagic(1);
      if (magicIdx === -1) {
        // No magic found — discard entire buffer
        console.error(`Discarding ${this.buffer.length} bytes — no magic found`);
        this.buffer = Buffer.alloc(0);
        return null;
      }
      console.error(`Skipping ${magicIdx} corrupt bytes to next magic`);
      this.buffer = this.buffer.subarray(magicIdx);
      return this.tryDecode(); // Retry from new position
    }

    const flags = this.buffer.readUInt8(2);
    const payloadLength = this.buffer.readUInt32BE(3);

    // Sanity check
    if (payloadLength > MAX_PAYLOAD) {
      throw new Error(`Payload length ${payloadLength} exceeds maximum ${MAX_PAYLOAD}`);
    }

    const totalFrameSize = HEADER_SIZE + payloadLength + CRC_SIZE;

    // Not enough data yet — wait for more
    if (this.buffer.length < totalFrameSize) {
      return null;
    }

    // Extract payload and CRC
    const payload = this.buffer.subarray(HEADER_SIZE, HEADER_SIZE + payloadLength);
    const receivedCRC = this.buffer.readUInt32BE(HEADER_SIZE + payloadLength);

    // Verify CRC (covers flags + length + payload)
    const crcInput = this.buffer.subarray(2, HEADER_SIZE + payloadLength);
    const computedCRC = crc32(crcInput);

    if (receivedCRC !== computedCRC) {
      throw new Error(
        `CRC mismatch: received=0x${receivedCRC.toString(16)}, ` +
        `computed=0x${computedCRC.toString(16)}`
      );
    }

    // Advance buffer past this frame
    this.buffer = this.buffer.subarray(totalFrameSize);

    // Parse TLV fields from payload
    const fields = this.parseTLVs(payload);

    return { flags, fields };
  }

  parseTLVs(buf) {
    const fields = {};
    let offset = 0;

    while (offset + 4 <= buf.length) {
      const type = buf.readUInt16BE(offset);
      const length = buf.readUInt16BE(offset + 2);

      if (offset + 4 + length > buf.length) {
        throw new Error(`TLV truncated at offset ${offset}`);
      }

      const value = buf.subarray(offset + 4, offset + 4 + length);

      // Decode known types
      switch (type) {
        case TLV.MESSAGE_TYPE:
          fields.type = value.readUInt8(0);
          break;
        case TLV.CORRELATION_ID:
          fields.correlationId = value.toString('utf8');
          break;
        case TLV.TIMESTAMP:
          fields.timestamp = Number(value.readBigUInt64BE(0));
          break;
        case TLV.BODY:
          fields.body = value.toString('utf8');
          break;
        case TLV.ERROR_CODE:
          fields.errorCode = value.readUInt16BE(0);
          break;
        case TLV.HEADERS:
          fields.headers = JSON.parse(value.toString('utf8'));
          break;
        default:
          // Forward compatibility: ignore unknown types
          if (!fields.unknownTypes) fields.unknownTypes = [];
          fields.unknownTypes.push({ type, length });
          break;
      }

      offset += 4 + length;
    }

    return fields;
  }

  findMagic(startOffset) {
    for (let i = startOffset; i < this.buffer.length - 1; i++) {
      if (this.buffer[i] === 0xCA && this.buffer[i + 1] === 0xFE) {
        return i;
      }
    }
    return -1;
  }
}
```

---

## Handling Partial Reads

TCP delivers data in arbitrary chunks. A single message may arrive in one `'data'` event or be split across five. The decoder must buffer incoming data and only emit complete, validated messages.

```javascript
'use strict';

const net = require('node:net');

// Simulating the full protocol stack (encoder, decoder, crc32, TLV constants
// would be imported from a shared module in production)

const server = net.createServer((socket) => {
  const decoder = new ProtocolDecoder();
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;

  console.log(`[${addr}] connected`);

  socket.on('data', (chunk) => {
    console.log(`[${addr}] received ${chunk.length} bytes`);

    try {
      const messages = decoder.feed(chunk);

      for (const msg of messages) {
        console.log(`[${addr}] decoded message:`, JSON.stringify(msg.fields));

        // Echo back a response
        const encoder = new ProtocolEncoder();
        const response = encoder.encode({
          type: 0x02, // RESPONSE
          correlationId: msg.fields.correlationId,
          timestamp: Date.now(),
          body: `ACK: ${msg.fields.body || ''}`,
        });
        socket.write(response);
      }
    } catch (err) {
      console.error(`[${addr}] protocol error: ${err.message}`);
      socket.destroy();
    }
  });

  socket.on('close', () => {
    console.log(`[${addr}] disconnected`);
  });

  socket.on('error', (err) => {
    console.error(`[${addr}] socket error: ${err.message}`);
  });
});

server.listen(5000, () => {
  console.log('Binary protocol server on :5000');
});
```

The critical point: the decoder's `feed()` method accumulates bytes across multiple `'data'` events. It returns zero messages when it does not have enough data, one message when exactly one frame is complete, or multiple messages when a single chunk contains several frames.

---

## Endianness Considerations

The protocol uses **big-endian** (network byte order) for all multi-byte integers. This is the standard convention for network protocols and the reason Node.js provides separate `readUInt32BE` and `readUInt32LE` methods.

```javascript
'use strict';

// Why endianness matters: the same 4 bytes represent different numbers
const buf = Buffer.from([0x00, 0x00, 0x01, 0x00]);

console.log('Big-endian (BE):   ', buf.readUInt32BE(0));  // 256
console.log('Little-endian (LE):', buf.readUInt32LE(0));   // 16777216 (0x00010000)

// Intel/AMD CPUs are little-endian natively.
// Network protocols use big-endian by convention (RFC 1700).
// Always use BE methods for wire data, LE for native CPU operations.

// A common mistake: using the wrong endianness silently produces wrong values
// without throwing an error. Always verify with known test vectors.
const testValue = 0x12345678;
const beBuf = Buffer.alloc(4);
const leBuf = Buffer.alloc(4);

beBuf.writeUInt32BE(testValue, 0);
leBuf.writeUInt32LE(testValue, 0);

console.log('BE bytes:', beBuf.toString('hex')); // 12345678
console.log('LE bytes:', leBuf.toString('hex')); // 78563412

// Cross-verify: read with matching endianness
console.log('BE read:', beBuf.readUInt32BE(0) === testValue); // true
console.log('LE read:', leBuf.readUInt32LE(0) === testValue); // true

// Mismatch: read LE data as BE
console.log('Mismatch:', leBuf.readUInt32BE(0).toString(16)); // 78563412 — wrong!
```

---

## Testing With Buffer Construction

You can test protocol implementations without a running server by constructing buffers manually.

```javascript
'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

// Assume ProtocolEncoder, ProtocolDecoder, and crc32 are imported

describe('Binary Protocol', () => {
  it('should round-trip a simple message', () => {
    const encoder = new ProtocolEncoder();
    const decoder = new ProtocolDecoder();

    const original = {
      type: 0x01,
      correlationId: 'test-123',
      timestamp: 1700000000000,
      body: 'Hello, protocol!',
    };

    const frame = encoder.encode(original);
    const messages = decoder.feed(frame);

    assert.equal(messages.length, 1);
    assert.equal(messages[0].fields.type, 0x01);
    assert.equal(messages[0].fields.correlationId, 'test-123');
    assert.equal(messages[0].fields.timestamp, 1700000000000);
    assert.equal(messages[0].fields.body, 'Hello, protocol!');
  });

  it('should handle multiple messages in a single chunk', () => {
    const encoder = new ProtocolEncoder();
    const decoder = new ProtocolDecoder();

    const frame1 = encoder.encode({ type: 0x01, body: 'first' });
    const frame2 = encoder.encode({ type: 0x01, body: 'second' });
    const frame3 = encoder.encode({ type: 0x01, body: 'third' });

    // Concatenate all frames as if TCP delivered them in one chunk
    const combined = Buffer.concat([frame1, frame2, frame3]);
    const messages = decoder.feed(combined);

    assert.equal(messages.length, 3);
    assert.equal(messages[0].fields.body, 'first');
    assert.equal(messages[1].fields.body, 'second');
    assert.equal(messages[2].fields.body, 'third');
  });

  it('should handle a message split across multiple chunks', () => {
    const encoder = new ProtocolEncoder();
    const decoder = new ProtocolDecoder();

    const frame = encoder.encode({
      type: 0x01,
      body: 'This message will be fragmented',
    });

    // Split the frame at an arbitrary point
    const splitPoint = Math.floor(frame.length / 3);
    const chunk1 = frame.subarray(0, splitPoint);
    const chunk2 = frame.subarray(splitPoint, splitPoint * 2);
    const chunk3 = frame.subarray(splitPoint * 2);

    // Feed chunks incrementally
    let messages = decoder.feed(chunk1);
    assert.equal(messages.length, 0, 'Should not decode from partial data');

    messages = decoder.feed(chunk2);
    assert.equal(messages.length, 0, 'Still incomplete');

    messages = decoder.feed(chunk3);
    assert.equal(messages.length, 1, 'Now the full frame is available');
    assert.equal(messages[0].fields.body, 'This message will be fragmented');
  });

  it('should detect CRC corruption', () => {
    const encoder = new ProtocolEncoder();
    const decoder = new ProtocolDecoder();

    const frame = encoder.encode({ type: 0x01, body: 'integrity test' });

    // Corrupt a byte in the payload
    frame[10] ^= 0xFF;

    assert.throws(
      () => decoder.feed(frame),
      /CRC mismatch/,
      'Should detect corrupted data'
    );
  });

  it('should reject frames exceeding max payload', () => {
    const encoder = new ProtocolEncoder();

    // Create a body larger than MAX_PAYLOAD
    const hugeBody = 'x'.repeat(17 * 1024 * 1024); // 17 MB

    assert.throws(
      () => encoder.encode({ type: 0x01, body: hugeBody }),
      /exceeds maximum/,
      'Should reject oversized payloads'
    );
  });

  it('should validate magic bytes', () => {
    const decoder = new ProtocolDecoder();

    // Feed garbage data with no magic bytes
    const garbage = Buffer.from('this is not a protocol frame');
    const messages = decoder.feed(garbage);

    assert.equal(messages.length, 0, 'Should not decode garbage');
  });
});
```

Run these tests with:

```bash
node --test protocol-test.js
```

---

## A Complete Client-Server Example

Putting encoder, decoder, CRC32, and TLV together into a working TCP client and server.

```javascript
'use strict';

const net = require('node:net');

// --- Protocol constants and utilities (same as above, consolidated) ---

const MAGIC = Buffer.from([0xCA, 0xFE]);
const HEADER_SIZE = 7;
const CRC_SIZE = 4;
const MAX_PAYLOAD = 16 * 1024 * 1024;

const TLV = {
  MESSAGE_TYPE:   0x0001,
  CORRELATION_ID: 0x0002,
  BODY:           0x0004,
};

const MSG_TYPE = { REQUEST: 0x01, RESPONSE: 0x02 };

// (crc32, encodeTLV, ProtocolEncoder, ProtocolDecoder defined above)

// --- Server ---

const server = net.createServer((socket) => {
  const decoder = new ProtocolDecoder();

  socket.on('data', (chunk) => {
    const messages = decoder.feed(chunk);

    for (const msg of messages) {
      console.log('[server] request:', msg.fields.correlationId, msg.fields.body);

      // Build response
      const encoder = new ProtocolEncoder();
      const response = encoder.encode({
        type: MSG_TYPE.RESPONSE,
        correlationId: msg.fields.correlationId,
        body: JSON.stringify({
          echo: msg.fields.body,
          processedAt: new Date().toISOString(),
        }),
      });

      socket.write(response);
    }
  });

  socket.on('error', (err) => console.error('[server] error:', err.message));
});

server.listen(5000, () => {
  console.log('[server] listening on :5000');

  // --- Client ---
  const client = net.createConnection({ port: 5000 }, () => {
    console.log('[client] connected');

    const encoder = new ProtocolEncoder();

    // Send 3 requests
    for (let i = 1; i <= 3; i++) {
      const frame = encoder.encode({
        type: MSG_TYPE.REQUEST,
        correlationId: `req-${i}`,
        body: `Hello #${i}`,
      });
      client.write(frame);
    }
  });

  const clientDecoder = new ProtocolDecoder();
  let responseCount = 0;

  client.on('data', (chunk) => {
    const messages = clientDecoder.feed(chunk);

    for (const msg of messages) {
      responseCount++;
      console.log(`[client] response ${responseCount}:`, msg.fields.correlationId, msg.fields.body);

      if (responseCount === 3) {
        client.end();
        server.close();
      }
    }
  });

  client.on('error', (err) => console.error('[client] error:', err.message));
});
```

---

## Performance Considerations

Binary protocols are faster than text protocols for three reasons:

1. **No parsing ambiguity** — a 4-byte integer is always 4 bytes. JSON's `"123456"` is 8 bytes and requires string-to-number conversion.
2. **No escaping** — JSON must escape special characters. Binary payloads are opaque byte sequences.
3. **O(1) framing** — reading a length header is a single `readUInt32BE` call. Scanning for `\n` in delimiter-based protocols is O(n).

```javascript
'use strict';

const { performance } = require('node:perf_hooks');

// Compare JSON framing vs binary framing for 100,000 messages
const iterations = 100_000;

// JSON framing
const jsonStart = performance.now();
for (let i = 0; i < iterations; i++) {
  const msg = JSON.stringify({ type: 1, id: `req-${i}`, body: 'test payload data' });
  const framed = msg + '\n';
  const buf = Buffer.from(framed, 'utf8');
  // Simulate finding the delimiter
  const idx = buf.indexOf(0x0A);
  const parsed = JSON.parse(buf.subarray(0, idx).toString('utf8'));
}
const jsonTime = performance.now() - jsonStart;

// Binary framing (simplified — just length prefix + raw bytes)
const binaryStart = performance.now();
for (let i = 0; i < iterations; i++) {
  const payload = Buffer.from('test payload data', 'utf8');
  const frame = Buffer.alloc(4 + payload.length);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  // Simulate reading the frame
  const len = frame.readUInt32BE(0);
  const data = frame.subarray(4, 4 + len);
}
const binaryTime = performance.now() - binaryStart;

console.log(`JSON framing:   ${jsonTime.toFixed(1)}ms for ${iterations} messages`);
console.log(`Binary framing: ${binaryTime.toFixed(1)}ms for ${iterations} messages`);
console.log(`Binary is ${(jsonTime / binaryTime).toFixed(1)}x faster`);
```

The binary approach is typically 3-10x faster depending on payload size and structure complexity. The bigger the payloads, the more JSON's escaping and parsing overhead compounds.

---

## Key Takeaways

- A binary protocol frame consists of a fixed header (magic bytes, flags, length), a variable-length payload (TLV-encoded fields), and a CRC32 checksum trailer — the header tells you how many bytes to read, the CRC tells you if those bytes arrived intact.
- The decoder must buffer incoming TCP data and only emit complete messages, because TCP guarantees byte order but not message boundaries — a single `'data'` event may contain zero, one, or many complete frames.
- CRC32 detects accidental corruption (bit flips, truncation) but does not protect against intentional tampering — for that you need cryptographic hashes or HMAC, which are covered in Module 10.
- Magic bytes at the start of every frame serve two purposes: identifying the protocol (so a stray HTTP connection to your binary port fails immediately) and providing a resynchronization point after corruption.
- Always use big-endian (network byte order) for multi-byte integers on the wire — it is the universal convention for network protocols, and mixing endianness silently produces wrong values without any error.

---

## Next

Continue to [Lesson 03 — Request-Response & Streaming Protocols](lesson-03-request-response-streaming.md) to build multiplexed request-response patterns, correlation IDs, pipelining, and bidirectional streaming on a single TCP connection.
