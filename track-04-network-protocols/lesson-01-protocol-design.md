# Track 04 / Lesson 01 — Protocol Design Principles

> Every time two programs communicate, they follow a protocol — even if the developer never formalized one. The difference between a protocol that survives five years of evolution and one that crumbles at the first schema change comes down to decisions made before the first byte is written. This lesson teaches you how to make those decisions deliberately.

## Learning Objectives

- Choose between length-prefix, delimiter, and fixed-size framing strategies based on data shape, debuggability, and performance requirements
- Design versioning schemes that allow protocol evolution without breaking existing clients
- Implement Type-Length-Value (TLV) encoding for extensible optional fields that both old and new implementations can handle
- Define error signaling strategies with structured error codes, error frames, and clear failure semantics
- Build a protocol state machine that enforces valid message ordering and connection lifecycle

---

## Why Protocol Design Matters

Most developers never design a wire protocol. They reach for HTTP + JSON and move on. That works until it does not. Custom protocols become necessary when:

- **Latency matters** — HTTP headers add overhead; a 4-byte length prefix does not
- **Bidirectional streaming** — HTTP request-response does not natively support server-initiated messages
- **Binary payloads** — JSON encoding of binary data wastes 33% bandwidth (Base64)
- **Multiplexing** — sending interleaved messages on a single connection requires framing the protocol cannot provide by default

Even if you never build a custom protocol from scratch, understanding these principles makes you better at using HTTP/2, gRPC, WebSocket, MQTT, and Redis RESP — because they all made the same design decisions you are about to learn.

---

## Framing: Where Does One Message End and the Next Begin?

TCP is a byte stream. It delivers data in arbitrary chunks with no inherent message boundaries. The first decision in any protocol is how the receiver knows when a complete message has arrived.

### Strategy 1: Delimiter-Based Framing

Use a special byte sequence (often `\n` or `\r\n`) to separate messages.

```javascript
'use strict';

const net = require('node:net');

// Delimiter-based framing: newline-delimited JSON (NDJSON)
function createDelimiterParser(socket, delimiter, onMessage) {
  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString('utf8');

    let idx;
    while ((idx = buffer.indexOf(delimiter)) !== -1) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + delimiter.length);

      if (line.length > 0) {
        onMessage(line);
      }
    }

    // Guard against memory exhaustion from a client that never sends a delimiter
    if (buffer.length > 1024 * 1024) {
      socket.destroy(new Error('Message too large — no delimiter found in 1 MB'));
    }
  });
}

const server = net.createServer((socket) => {
  createDelimiterParser(socket, '\n', (line) => {
    console.log('Received message:', line);
    socket.write(`ACK: ${line}\n`);
  });
});

server.listen(4000, () => console.log('Delimiter-framed server on :4000'));
```

**Pros:** Human-readable, easy to test with `nc` or `curl`.
**Cons:** Cannot embed the delimiter in payload data, scanning every byte for the delimiter is O(n), no support for binary payloads.

### Strategy 2: Length-Prefix Framing

Prepend every message with a fixed-size header containing the payload length.

```javascript
'use strict';

const net = require('node:net');

// Length-prefix framing: 4-byte UInt32BE header + payload
function createLengthPrefixParser(socket, onMessage) {
  let buffer = Buffer.alloc(0);
  const HEADER_SIZE = 4;

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= HEADER_SIZE) {
      const payloadLength = buffer.readUInt32BE(0);

      // Sanity check — reject absurdly large messages
      if (payloadLength > 16 * 1024 * 1024) {
        socket.destroy(new Error(`Payload too large: ${payloadLength} bytes`));
        return;
      }

      const totalLength = HEADER_SIZE + payloadLength;
      if (buffer.length < totalLength) {
        break; // Wait for more data
      }

      const payload = buffer.subarray(HEADER_SIZE, totalLength);
      buffer = buffer.subarray(totalLength);

      onMessage(payload);
    }
  });
}

const server = net.createServer((socket) => {
  createLengthPrefixParser(socket, (payload) => {
    console.log('Received:', payload.toString('utf8'));
  });
});

server.listen(4001, () => console.log('Length-prefix server on :4001'));
```

**Pros:** O(1) to determine message boundary (read one integer), supports binary data, no reserved characters.
**Cons:** Not human-readable, requires the sender to know the payload size before writing.

### Strategy 3: Fixed-Size Messages

Every message is exactly N bytes. Shorter messages are padded.

```javascript
'use strict';

const net = require('node:net');

// Fixed-size framing: every message is exactly 64 bytes
const MESSAGE_SIZE = 64;

function createFixedSizeParser(socket, onMessage) {
  let buffer = Buffer.alloc(0);

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= MESSAGE_SIZE) {
      const message = buffer.subarray(0, MESSAGE_SIZE);
      buffer = buffer.subarray(MESSAGE_SIZE);
      onMessage(message);
    }
  });
}

// Pad or truncate a string to exactly MESSAGE_SIZE bytes
function frameMessage(text) {
  const buf = Buffer.alloc(MESSAGE_SIZE, 0x00); // Zero-padded
  buf.write(text, 'utf8');
  return buf;
}

const server = net.createServer((socket) => {
  createFixedSizeParser(socket, (msg) => {
    // Find the first null byte to get the actual string
    const end = msg.indexOf(0x00);
    const text = msg.subarray(0, end === -1 ? MESSAGE_SIZE : end).toString('utf8');
    console.log(`Received [${text}] (${MESSAGE_SIZE} bytes on wire)`);
  });
});

server.listen(4002, () => console.log('Fixed-size server on :4002'));
```

**Pros:** Simplest parser (just count bytes), no header overhead.
**Cons:** Wastes bandwidth on padding, maximum message size baked in, not suitable for variable-length data.

### Choosing a Framing Strategy

| Criterion         | Delimiter     | Length-Prefix   | Fixed-Size     |
|-------------------|---------------|-----------------|----------------|
| Data type         | Text only     | Text or binary  | Text or binary |
| Debuggability     | High          | Low             | Low            |
| Implementation    | Simple        | Moderate        | Simplest       |
| Bandwidth         | Good          | Optimal         | Poor (padding) |
| Max message size  | Unlimited*    | 4 GB (UInt32)   | Fixed          |
| Binary safe       | No            | Yes             | Yes            |

*Unlimited in theory, but you must enforce a practical limit to prevent memory exhaustion.

---

## Versioning: How Does a Protocol Evolve?

Protocols change. Fields get added, message types get introduced, encoding formats shift. Without a versioning strategy, any change breaks all existing clients.

### Major.Minor Versioning in the Header

Encode the protocol version in the first bytes of every connection or message.

```javascript
'use strict';

// Protocol header layout (8 bytes):
//   Bytes 0-1: Magic bytes (0xCA, 0xFE)
//   Byte 2:    Major version
//   Byte 3:    Minor version
//   Bytes 4-7: Payload length (UInt32BE)

const MAGIC = Buffer.from([0xCA, 0xFE]);
const VERSION_MAJOR = 1;
const VERSION_MINOR = 2;
const HEADER_SIZE = 8;

function encodeMessage(payload) {
  const payloadBuf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  const header = Buffer.alloc(HEADER_SIZE);

  header[0] = MAGIC[0];        // Magic byte 1
  header[1] = MAGIC[1];        // Magic byte 2
  header[2] = VERSION_MAJOR;   // Major version
  header[3] = VERSION_MINOR;   // Minor version
  header.writeUInt32BE(payloadBuf.length, 4); // Payload length

  return Buffer.concat([header, payloadBuf]);
}

function decodeHeader(buf) {
  if (buf.length < HEADER_SIZE) {
    return null; // Not enough data
  }

  // Validate magic bytes
  if (buf[0] !== MAGIC[0] || buf[1] !== MAGIC[1]) {
    throw new Error(`Invalid magic bytes: 0x${buf[0].toString(16)} 0x${buf[1].toString(16)}`);
  }

  return {
    major: buf[2],
    minor: buf[3],
    payloadLength: buf.readUInt32BE(4),
  };
}

// Version compatibility check
function isCompatible(remoteMajor, remoteMinor) {
  // Same major version = compatible (minor versions are additive)
  // Different major version = breaking change
  if (remoteMajor !== VERSION_MAJOR) {
    return { compatible: false, reason: `Major version mismatch: local=${VERSION_MAJOR}, remote=${remoteMajor}` };
  }

  if (remoteMinor > VERSION_MINOR) {
    // Remote has newer minor — we can still communicate, but may not understand new fields
    return { compatible: true, reason: `Remote has newer minor version (${remoteMinor} > ${VERSION_MINOR}). Unknown fields will be ignored.` };
  }

  return { compatible: true, reason: 'Fully compatible' };
}

// Demo
const msg = encodeMessage('{"type":"hello","name":"client-1"}');
console.log('Encoded:', msg.toString('hex'));

const header = decodeHeader(msg);
console.log('Decoded header:', header);
console.log('Compatibility:', isCompatible(header.major, header.minor));
```

**Rules of version numbering:**

- **Major version change** = breaking. The message format is incompatible. Both sides must agree on the same major version.
- **Minor version change** = additive. New optional fields or message types. Old implementations ignore what they do not recognize.

### Version Negotiation at Connection Time

Rather than embedding the version in every message, negotiate once when the connection opens.

```javascript
'use strict';

const net = require('node:net');

// Client sends a HELLO frame with its supported versions.
// Server responds with the chosen version.

function sendVersionHello(socket, supportedVersions) {
  const frame = Buffer.alloc(2 + supportedVersions.length * 2);
  frame.writeUInt8(0x01, 0);  // Frame type: VERSION_HELLO
  frame.writeUInt8(supportedVersions.length, 1); // Count

  supportedVersions.forEach((ver, i) => {
    frame.writeUInt8(ver.major, 2 + i * 2);
    frame.writeUInt8(ver.minor, 3 + i * 2);
  });

  socket.write(frame);
}

function negotiateVersion(clientVersions, serverVersions) {
  // Find the highest mutually supported major version
  for (let i = clientVersions.length - 1; i >= 0; i--) {
    const cv = clientVersions[i];
    const match = serverVersions.find((sv) => sv.major === cv.major);
    if (match) {
      return { major: cv.major, minor: Math.min(cv.minor, match.minor) };
    }
  }
  return null; // No compatible version
}

// Example negotiation
const clientVersions = [{ major: 1, minor: 0 }, { major: 2, minor: 1 }];
const serverVersions = [{ major: 1, minor: 3 }, { major: 2, minor: 0 }];

const chosen = negotiateVersion(clientVersions, serverVersions);
console.log('Negotiated version:', chosen);
// { major: 2, minor: 0 } — highest shared major, minimum minor
```

---

## Extensibility With Type-Length-Value (TLV)

TLV encoding allows a protocol to carry optional fields that old implementations can skip over without understanding.

```javascript
'use strict';

// TLV structure:
//   Type:   2 bytes (UInt16BE) — identifies the field
//   Length: 2 bytes (UInt16BE) — payload size in bytes
//   Value:  `Length` bytes     — the actual data

const TLV_HEADER_SIZE = 4;

// Known types
const TLV_TYPES = {
  USERNAME:       0x0001,
  TIMESTAMP:      0x0002,
  CORRELATION_ID: 0x0003,
  METADATA:       0x0004,
  // Types >= 0x8000 reserved for vendor extensions
};

function encodeTLV(type, value) {
  const valueBuf = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
  const buf = Buffer.alloc(TLV_HEADER_SIZE + valueBuf.length);
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(valueBuf.length, 2);
  valueBuf.copy(buf, TLV_HEADER_SIZE);
  return buf;
}

function decodeTLVs(buf) {
  const fields = [];
  let offset = 0;

  while (offset + TLV_HEADER_SIZE <= buf.length) {
    const type = buf.readUInt16BE(offset);
    const length = buf.readUInt16BE(offset + 2);

    if (offset + TLV_HEADER_SIZE + length > buf.length) {
      throw new Error(`TLV truncated at offset ${offset}: declared length=${length}, available=${buf.length - offset - TLV_HEADER_SIZE}`);
    }

    const value = buf.subarray(offset + TLV_HEADER_SIZE, offset + TLV_HEADER_SIZE + length);
    fields.push({ type, length, value });

    offset += TLV_HEADER_SIZE + length;
  }

  return fields;
}

// Encode a message with multiple TLV fields
const message = Buffer.concat([
  encodeTLV(TLV_TYPES.USERNAME, 'alice'),
  encodeTLV(TLV_TYPES.TIMESTAMP, Buffer.from(BigInt(Date.now()).toString())),
  encodeTLV(TLV_TYPES.CORRELATION_ID, 'req-42'),
  encodeTLV(0x9999, 'vendor-specific-data'), // Unknown to older implementations
]);

console.log('Encoded TLV message:', message.toString('hex'));
console.log('Total size:', message.length, 'bytes');

// Decode — an old implementation simply skips types it does not recognize
const fields = decodeTLVs(message);
for (const field of fields) {
  const name = Object.entries(TLV_TYPES).find(([, v]) => v === field.type)?.[0] || `UNKNOWN(0x${field.type.toString(16)})`;
  console.log(`  ${name}: ${field.value.toString('utf8')} (${field.length} bytes)`);
}
```

The beauty of TLV is **forward compatibility**: an implementation that does not know about type `0x9999` simply skips `TLV_HEADER_SIZE + length` bytes and continues parsing the next field.

---

## Error Signaling

Every protocol needs a way to communicate errors. The design choices are:

1. **Error codes** — numeric, compact, machine-readable
2. **Error messages** — human-readable text alongside the code
3. **Error frames** — a dedicated frame type for errors (separate from data frames)

```javascript
'use strict';

// Error code registry — group by category using ranges
const ErrorCode = {
  // 1xxx — Protocol errors
  UNKNOWN_VERSION:       1001,
  INVALID_FRAME:         1002,
  FRAME_TOO_LARGE:       1003,
  CHECKSUM_MISMATCH:     1004,

  // 2xxx — Authentication errors
  AUTH_REQUIRED:         2001,
  AUTH_INVALID:          2002,
  AUTH_EXPIRED:          2003,

  // 3xxx — Application errors
  RESOURCE_NOT_FOUND:    3001,
  RATE_LIMITED:          3002,
  INTERNAL_ERROR:        3003,

  // 4xxx — Connection errors
  GOING_AWAY:            4001,
  IDLE_TIMEOUT:          4002,
};

const FRAME_TYPE_ERROR = 0xFF;

function encodeErrorFrame(errorCode, message) {
  const msgBuf = Buffer.from(message, 'utf8');
  // Error frame: [1 byte type][2 bytes error code][2 bytes msg length][N bytes message]
  const frame = Buffer.alloc(1 + 2 + 2 + msgBuf.length);
  frame.writeUInt8(FRAME_TYPE_ERROR, 0);
  frame.writeUInt16BE(errorCode, 1);
  frame.writeUInt16BE(msgBuf.length, 3);
  msgBuf.copy(frame, 5);
  return frame;
}

function decodeErrorFrame(buf) {
  if (buf[0] !== FRAME_TYPE_ERROR) {
    throw new Error('Not an error frame');
  }

  const code = buf.readUInt16BE(1);
  const msgLen = buf.readUInt16BE(3);
  const message = buf.subarray(5, 5 + msgLen).toString('utf8');

  // Reverse lookup for code name
  const name = Object.entries(ErrorCode).find(([, v]) => v === code)?.[0] || 'UNKNOWN';

  return { code, name, message };
}

// Demo
const errFrame = encodeErrorFrame(ErrorCode.RATE_LIMITED, 'Too many requests — retry after 5 seconds');
console.log('Error frame:', errFrame.toString('hex'));
console.log('Decoded:', decodeErrorFrame(errFrame));
```

**Design principle:** Error codes should be categorized by range (1xxx for protocol, 2xxx for auth, 3xxx for application). This lets implementations handle entire categories without knowing every specific code.

---

## Idempotency Keys

When a client sends a request and the connection drops before the response arrives, the client does not know if the server processed the request. Idempotency keys solve this by letting the client safely retry.

```javascript
'use strict';

const crypto = require('node:crypto');

// The client generates a unique key for each logical operation
function generateIdempotencyKey() {
  return crypto.randomUUID();
}

// The server tracks processed keys to avoid double-processing
class IdempotencyStore {
  constructor(ttlMs = 300_000) { // 5-minute TTL
    this.store = new Map();
    this.ttlMs = ttlMs;

    // Periodic cleanup of expired keys
    this.cleanupTimer = setInterval(() => this.cleanup(), 60_000);
    this.cleanupTimer.unref(); // Do not block process exit
  }

  has(key) {
    const entry = this.store.get(key);
    if (!entry) return false;
    if (Date.now() - entry.timestamp > this.ttlMs) {
      this.store.delete(key);
      return false;
    }
    return true;
  }

  getResponse(key) {
    const entry = this.store.get(key);
    return entry ? entry.response : null;
  }

  record(key, response) {
    this.store.set(key, { response, timestamp: Date.now() });
  }

  cleanup() {
    const now = Date.now();
    for (const [key, entry] of this.store) {
      if (now - entry.timestamp > this.ttlMs) {
        this.store.delete(key);
      }
    }
  }

  destroy() {
    clearInterval(this.cleanupTimer);
    this.store.clear();
  }
}

// Usage in a request handler
const store = new IdempotencyStore();

function handleRequest(request) {
  const { idempotencyKey, action, data } = request;

  // Check if we already processed this request
  if (store.has(idempotencyKey)) {
    console.log(`Duplicate request ${idempotencyKey} — returning cached response`);
    return store.getResponse(idempotencyKey);
  }

  // Process the request
  const response = { status: 'ok', action, result: `Processed: ${JSON.stringify(data)}` };

  // Cache the response keyed by the idempotency key
  store.record(idempotencyKey, response);

  return response;
}

// Demo — same key sent twice
const key = generateIdempotencyKey();
console.log('First call:', handleRequest({ idempotencyKey: key, action: 'transfer', data: { amount: 100 } }));
console.log('Retry call:', handleRequest({ idempotencyKey: key, action: 'transfer', data: { amount: 100 } }));

store.destroy();
```

---

## Protocol State Machines

A protocol is a conversation with rules. Not every message is valid at every time. A state machine enforces these rules.

```javascript
'use strict';

// Connection lifecycle states
const State = {
  CONNECTING:     'CONNECTING',
  VERSION_SENT:   'VERSION_SENT',
  AUTHENTICATED:  'AUTHENTICATED',
  READY:          'READY',
  CLOSING:        'CLOSING',
  CLOSED:         'CLOSED',
};

// Valid transitions: [currentState] => { frameType => nextState }
const TRANSITIONS = {
  [State.CONNECTING]: {
    VERSION_HELLO: State.VERSION_SENT,
  },
  [State.VERSION_SENT]: {
    VERSION_OK:    State.AUTHENTICATED,
    VERSION_FAIL:  State.CLOSED,
  },
  [State.AUTHENTICATED]: {
    AUTH_OK:       State.READY,
    AUTH_FAIL:     State.CLOSED,
  },
  [State.READY]: {
    DATA:          State.READY,       // Stay in READY
    PING:          State.READY,
    PONG:          State.READY,
    ERROR:         State.READY,       // Errors do not close the connection
    CLOSE:         State.CLOSING,
  },
  [State.CLOSING]: {
    CLOSE_ACK:     State.CLOSED,
  },
};

class ProtocolStateMachine {
  constructor() {
    this.state = State.CONNECTING;
    this.history = [{ state: this.state, timestamp: Date.now() }];
  }

  transition(frameType) {
    const allowed = TRANSITIONS[this.state];
    if (!allowed) {
      throw new Error(`No transitions defined for state ${this.state}`);
    }

    const nextState = allowed[frameType];
    if (!nextState) {
      const validFrames = Object.keys(allowed).join(', ');
      throw new Error(
        `Invalid frame "${frameType}" in state ${this.state}. ` +
        `Valid frames: [${validFrames}]`
      );
    }

    const prev = this.state;
    this.state = nextState;
    this.history.push({ state: this.state, frameType, timestamp: Date.now() });

    return { from: prev, to: this.state, frameType };
  }

  isTerminal() {
    return this.state === State.CLOSED;
  }
}

// Demo — a successful connection lifecycle
const sm = new ProtocolStateMachine();
console.log('Initial:', sm.state);

console.log(sm.transition('VERSION_HELLO'));
console.log(sm.transition('VERSION_OK'));
console.log(sm.transition('AUTH_OK'));
console.log(sm.transition('DATA'));
console.log(sm.transition('PING'));
console.log(sm.transition('DATA'));
console.log(sm.transition('CLOSE'));
console.log(sm.transition('CLOSE_ACK'));
console.log('Terminal?', sm.isTerminal());

// Attempt an invalid transition
const sm2 = new ProtocolStateMachine();
try {
  sm2.transition('DATA'); // Cannot send DATA in CONNECTING state
} catch (err) {
  console.log('Expected error:', err.message);
}
```

The state machine prevents a client from sending data before completing the version handshake and authentication sequence. It also ensures the close handshake follows the correct order.

---

## Backward and Forward Compatibility

Two rules make protocol evolution painless:

1. **Ignore unknown fields** (forward compatibility) — when you receive a TLV type you do not recognize, skip it. Do not error.
2. **Required vs. optional** (backward compatibility) — new fields must always be optional. Required fields can never be added after version 1.0.

```javascript
'use strict';

// A message parser that tolerates unknown fields
function parseMessage(tlvFields, knownTypes) {
  const parsed = {};
  const unknown = [];

  for (const field of tlvFields) {
    const name = Object.entries(knownTypes).find(([, v]) => v === field.type)?.[0];

    if (name) {
      parsed[name] = field.value.toString('utf8');
    } else {
      // Forward compatibility: log and skip, never error
      unknown.push({ type: field.type, length: field.length });
    }
  }

  if (unknown.length > 0) {
    console.log(`Skipped ${unknown.length} unknown TLV fields:`,
      unknown.map((u) => `0x${u.type.toString(16)} (${u.length} bytes)`)
    );
  }

  return parsed;
}

// Required field validation
const REQUIRED_FIELDS = ['USERNAME'];

function validateRequired(parsed) {
  const missing = REQUIRED_FIELDS.filter((f) => !(f in parsed));
  if (missing.length > 0) {
    throw new Error(`Missing required fields: ${missing.join(', ')}`);
  }
}

// Demo
const KNOWN_TYPES_V1 = { USERNAME: 0x0001, TIMESTAMP: 0x0002 };

// Simulated TLV fields from a v2 sender (includes CORRELATION_ID which v1 does not know)
const fields = [
  { type: 0x0001, length: 5, value: Buffer.from('alice') },
  { type: 0x0002, length: 13, value: Buffer.from('1707000000000') },
  { type: 0x0003, length: 6, value: Buffer.from('req-42') }, // Unknown to v1
];

const result = parseMessage(fields, KNOWN_TYPES_V1);
validateRequired(result);
console.log('Parsed:', result);
```

---

## Putting It Together: A Protocol Specification

A complete protocol specification documents all of these decisions in a structured format.

```
PROTOCOL: MyRPC v1.0

FRAMING:
  Length-prefix, 4-byte UInt32BE header, max payload 16 MB

HEADER (8 bytes):
  [0-1]  Magic: 0xCA 0xFE
  [2]    Major version: 1
  [3]    Minor version: 0
  [4-7]  Payload length (UInt32BE)

PAYLOAD:
  TLV-encoded fields (UInt16BE type, UInt16BE length, N bytes value)

REQUIRED FIELDS:
  0x0001 — MESSAGE_TYPE (UInt8: 0x01=REQUEST, 0x02=RESPONSE, 0x03=ERROR, 0x04=PING, 0x05=PONG)

OPTIONAL FIELDS:
  0x0002 — CORRELATION_ID (16 bytes UUID)
  0x0003 — TIMESTAMP (8 bytes Int64BE, ms since epoch)
  0x0004 — BODY (variable, application data)
  0x0005 — ERROR_CODE (2 bytes UInt16BE)
  0x0006 — IDEMPOTENCY_KEY (16 bytes UUID)

LIFECYCLE:
  CONNECTING → VERSION_HELLO → VERSION_OK → AUTH → READY ⇄ DATA/PING/PONG → CLOSE → CLOSED

ERROR CODES:
  1001 — UNKNOWN_VERSION
  1002 — INVALID_FRAME
  2001 — AUTH_REQUIRED
  3001 — NOT_FOUND
  3002 — RATE_LIMITED

COMPATIBILITY:
  - Minor version increments add optional TLV fields only
  - Major version increments may change framing, header layout, or required fields
  - Receivers MUST ignore unknown TLV types
  - Senders MUST NOT add new required fields in minor versions
```

This is not a formal RFC, but it gives every implementor the information they need to write a compatible client or server.

---

## Key Takeaways

- Every TCP protocol must define a framing strategy — length-prefix for binary data and performance, delimiter for text-based simplicity, or fixed-size for ultra-simple cases where all messages are the same length.
- Version numbers in the protocol header (major.minor) allow controlled evolution: major changes break compatibility, minor changes add optional features that old implementations can safely ignore.
- TLV (Type-Length-Value) encoding provides extensibility without schema negotiation — receivers skip unknown types by reading the length and advancing the offset, maintaining forward compatibility.
- A protocol state machine prevents invalid message sequences (such as sending data before authentication) and makes the connection lifecycle explicit, testable, and self-documenting.
- Idempotency keys let clients safely retry requests after network failures without risking duplicate processing on the server — essential for any protocol that mutates state.

---

## Next

Continue to [Lesson 02 — Binary Protocol Implementation](lesson-02-binary-protocols.md) to build a complete binary protocol from scratch — length-prefixed messages, TLV encoding, CRC32 checksums, and a full encoder/decoder class.
