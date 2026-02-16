# Track 04 / Lesson 05 — WebSocket Protocol

> Every developer has used WebSocket through a library. Few have read the bytes on the wire. The WebSocket protocol is elegant: an HTTP upgrade handshake promotes a regular TCP connection into a full-duplex message channel, then frames carry text, binary, ping, pong, and close messages with a compact encoding. This lesson implements the entire protocol from scratch using `node:http` and `node:crypto` — no `ws` package, no shortcuts.

## Learning Objectives

- Implement the HTTP upgrade handshake on a `node:http` server, computing `Sec-WebSocket-Accept` from the client's `Sec-WebSocket-Key` using SHA-1 and the WebSocket magic GUID
- Parse WebSocket frames from raw bytes, handling the FIN bit, opcode (text, binary, close, ping, pong), masking, and all three payload length encodings (7-bit, 16-bit extended, 64-bit extended)
- Build a minimal WebSocket server that accepts connections, sends and receives text and binary messages, and handles concurrent clients
- Implement ping/pong heartbeat to detect dead connections and the close handshake with status codes for graceful shutdown
- Handle fragmented messages where a single logical message is split across multiple frames with the FIN bit controlling reassembly

---

## The HTTP Upgrade Handshake

WebSocket begins life as an HTTP request. The client sends an `Upgrade: websocket` header, and the server responds with `101 Switching Protocols` to promote the connection from HTTP to WebSocket.

### Client Request

```
GET /chat HTTP/1.1
Host: example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

### Server Response

```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

The `Sec-WebSocket-Accept` header proves the server understood the WebSocket request. It is computed as:

```
Base64(SHA-1(Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-5AB5DC11E5B3"))
```

The magic string `258EAFA5-E914-47DA-95CA-5AB5DC11E5B3` is defined in RFC 6455 and never changes.

```javascript
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-5AB5DC11E5B3';

function computeAcceptKey(clientKey) {
  return crypto
    .createHash('sha1')
    .update(clientKey + WS_MAGIC_GUID)
    .digest('base64');
}

// Verify with the RFC 6455 test vector
const testKey = 'dGhlIHNhbXBsZSBub25jZQ==';
const expected = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';
const result = computeAcceptKey(testKey);
console.log('Accept key:', result);
console.log('Matches RFC:', result === expected); // true
```

### Implementing the Upgrade on `node:http`

```javascript
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-5AB5DC11E5B3';

const server = http.createServer((req, res) => {
  // Regular HTTP requests (not upgrades)
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('This server also speaks WebSocket. Connect with ws://\n');
});

server.on('upgrade', (req, socket, head) => {
  // Validate the upgrade request
  const upgrade = req.headers['upgrade'];
  if (!upgrade || upgrade.toLowerCase() !== 'websocket') {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }

  const version = req.headers['sec-websocket-version'];
  if (version !== '13') {
    socket.write(
      'HTTP/1.1 426 Upgrade Required\r\n' +
      'Sec-WebSocket-Version: 13\r\n\r\n'
    );
    socket.destroy();
    return;
  }

  const clientKey = req.headers['sec-websocket-key'];
  if (!clientKey) {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }

  // Compute the accept key
  const acceptKey = crypto
    .createHash('sha1')
    .update(clientKey + WS_MAGIC_GUID)
    .digest('base64');

  // Send the 101 Switching Protocols response
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${acceptKey}\r\n` +
    '\r\n'
  );

  console.log('[ws] handshake complete for', req.url);

  // From this point, `socket` is a raw TCP socket speaking WebSocket frames.
  // The `head` buffer may contain the first WebSocket frame bytes that arrived
  // in the same TCP segment as the upgrade request.

  handleWebSocket(socket, head);
});

server.listen(8080, () => {
  console.log('WebSocket server on ws://127.0.0.1:8080');
});
```

The `head` parameter in the `'upgrade'` callback is crucial. It contains any bytes the client sent after the HTTP headers but in the same TCP packet. You must process these bytes before waiting for `'data'` events; otherwise, the first frame may be silently lost.

---

## WebSocket Frame Format

After the handshake, all communication uses WebSocket frames. The frame format is compact but has several variable-length fields.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |           (16/64)             |
|N|V|V|V|       |S|             |   (if payload len==126/127)   |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
|     Extended payload length continued, if payload len == 127  |
+ - - - - - - - - - - - - - - - +-------------------------------+
|                               |Masking-key, if MASK set to 1  |
+-------------------------------+-------------------------------+
| Masking-key (continued)       |          Payload Data         |
+-------------------------------- - - - - - - - - - - - - - - - +
:                     Payload Data continued ...                :
+---------------------------------------------------------------+
```

### Key Fields

- **FIN** (1 bit): 1 = final frame of a message, 0 = more fragments follow
- **Opcode** (4 bits): 0x0 = continuation, 0x1 = text, 0x2 = binary, 0x8 = close, 0x9 = ping, 0xA = pong
- **MASK** (1 bit): 1 = payload is masked (required for client-to-server)
- **Payload length** (7 bits): 0-125 = actual length, 126 = next 2 bytes are the length, 127 = next 8 bytes are the length
- **Masking key** (4 bytes, if MASK=1): XOR key for payload

---

## Frame Parser

```javascript
'use strict';

// Opcodes
const OPCODE = {
  CONTINUATION: 0x0,
  TEXT:         0x1,
  BINARY:       0x2,
  CLOSE:        0x8,
  PING:         0x9,
  PONG:         0xA,
};

function parseFrame(buffer, offset = 0) {
  if (buffer.length - offset < 2) return null; // Not enough data

  const byte1 = buffer[offset];
  const byte2 = buffer[offset + 1];

  const fin    = (byte1 & 0x80) !== 0;  // Bit 0
  const rsv1   = (byte1 & 0x40) !== 0;  // Bit 1 (reserved)
  const rsv2   = (byte1 & 0x20) !== 0;  // Bit 2 (reserved)
  const rsv3   = (byte1 & 0x10) !== 0;  // Bit 3 (reserved)
  const opcode = byte1 & 0x0F;          // Bits 4-7

  const masked       = (byte2 & 0x80) !== 0;  // Bit 8
  let payloadLength  = byte2 & 0x7F;          // Bits 9-15

  let headerSize = 2;

  // Extended payload length
  if (payloadLength === 126) {
    if (buffer.length - offset < 4) return null;
    payloadLength = buffer.readUInt16BE(offset + 2);
    headerSize = 4;
  } else if (payloadLength === 127) {
    if (buffer.length - offset < 10) return null;
    // 64-bit length — but JS numbers lose precision above 2^53
    const high = buffer.readUInt32BE(offset + 2);
    const low = buffer.readUInt32BE(offset + 6);
    if (high > 0) {
      throw new Error('Payload too large — exceeds Number.MAX_SAFE_INTEGER');
    }
    payloadLength = low;
    headerSize = 10;
  }

  // Masking key
  let maskingKey = null;
  if (masked) {
    if (buffer.length - offset < headerSize + 4) return null;
    maskingKey = buffer.subarray(offset + headerSize, offset + headerSize + 4);
    headerSize += 4;
  }

  // Check if full payload is available
  const totalFrameSize = headerSize + payloadLength;
  if (buffer.length - offset < totalFrameSize) return null;

  // Extract payload
  let payload = buffer.subarray(offset + headerSize, offset + totalFrameSize);

  // Unmask if needed
  if (masked && maskingKey) {
    payload = unmask(payload, maskingKey);
  }

  return {
    fin,
    opcode,
    masked,
    payloadLength,
    payload,
    totalFrameSize,
    rsv1, rsv2, rsv3,
  };
}

function unmask(payload, maskingKey) {
  // The masking algorithm: payload[i] ^= maskingKey[i % 4]
  const unmasked = Buffer.allocUnsafe(payload.length);
  for (let i = 0; i < payload.length; i++) {
    unmasked[i] = payload[i] ^ maskingKey[i & 3]; // i & 3 === i % 4 (faster)
  }
  return unmasked;
}
```

---

## Frame Encoder

The server sends frames without masking (RFC 6455 requires masking only for client-to-server frames).

```javascript
'use strict';

function encodeFrame(opcode, payload, fin = true) {
  const payloadBuf = Buffer.isBuffer(payload)
    ? payload
    : Buffer.from(payload || '', 'utf8');

  let headerSize;
  let extendedLength;

  if (payloadBuf.length < 126) {
    headerSize = 2;
    extendedLength = null;
  } else if (payloadBuf.length < 65536) {
    headerSize = 4;
    extendedLength = 16;
  } else {
    headerSize = 10;
    extendedLength = 64;
  }

  const frame = Buffer.alloc(headerSize + payloadBuf.length);

  // Byte 1: FIN + opcode
  frame[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0F);

  // Byte 2: MASK=0 (server does not mask) + payload length
  if (extendedLength === null) {
    frame[1] = payloadBuf.length;
  } else if (extendedLength === 16) {
    frame[1] = 126;
    frame.writeUInt16BE(payloadBuf.length, 2);
  } else {
    frame[1] = 127;
    frame.writeUInt32BE(0, 2);       // High 32 bits (always 0 for reasonable sizes)
    frame.writeUInt32BE(payloadBuf.length, 6); // Low 32 bits
  }

  // Copy payload
  payloadBuf.copy(frame, headerSize);

  return frame;
}

// Helper functions for common frame types
function encodeTextFrame(text) {
  return encodeFrame(OPCODE.TEXT, text);
}

function encodeBinaryFrame(data) {
  return encodeFrame(OPCODE.BINARY, data);
}

function encodePingFrame(data) {
  return encodeFrame(OPCODE.PING, data || Buffer.alloc(0));
}

function encodePongFrame(data) {
  return encodeFrame(OPCODE.PONG, data || Buffer.alloc(0));
}

function encodeCloseFrame(statusCode, reason) {
  let payload;
  if (statusCode) {
    const reasonBuf = reason ? Buffer.from(reason, 'utf8') : Buffer.alloc(0);
    payload = Buffer.alloc(2 + reasonBuf.length);
    payload.writeUInt16BE(statusCode, 0);
    reasonBuf.copy(payload, 2);
  } else {
    payload = Buffer.alloc(0);
  }
  return encodeFrame(OPCODE.CLOSE, payload);
}
```

---

## Payload Length Encoding

The WebSocket protocol uses three different encodings for payload length depending on the size:

```javascript
'use strict';

// Demonstrate the three payload length encodings

// 1. 7-bit: payload 0-125 bytes — length fits in the second byte
const small = encodeFrame(OPCODE.TEXT, 'Hello');
console.log('Small frame (5 bytes payload):');
console.log('  Frame size:', small.length, 'bytes (2 header + 5 payload)');
console.log('  Byte 2:', small[1], '(direct length)');

// 2. 16-bit: payload 126-65535 bytes — second byte is 126, next 2 bytes are length
const medium = encodeFrame(OPCODE.TEXT, 'x'.repeat(1000));
console.log('\nMedium frame (1000 bytes payload):');
console.log('  Frame size:', medium.length, 'bytes (4 header + 1000 payload)');
console.log('  Byte 2:', medium[1], '(126 = use next 2 bytes)');
console.log('  Length bytes:', medium.readUInt16BE(2));

// 3. 64-bit: payload 65536+ bytes — second byte is 127, next 8 bytes are length
const large = encodeFrame(OPCODE.BINARY, Buffer.alloc(70000, 0x42));
console.log('\nLarge frame (70000 bytes payload):');
console.log('  Frame size:', large.length, 'bytes (10 header + 70000 payload)');
console.log('  Byte 2:', large[1], '(127 = use next 8 bytes)');
console.log('  Length (low 32):', large.readUInt32BE(6));
```

---

## Building a Minimal WebSocket Server

Combining the handshake, frame parser, and frame encoder into a complete WebSocket server.

```javascript
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-5AB5DC11E5B3';

// (OPCODE, parseFrame, encodeFrame, encodeTextFrame, encodePingFrame,
//  encodePongFrame, encodeCloseFrame defined above)

class WebSocketServer {
  constructor() {
    this.clients = new Set();

    this.httpServer = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('WebSocket server. Connect with ws://\n');
    });

    this.httpServer.on('upgrade', (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });
  }

  handleUpgrade(req, socket, head) {
    const upgrade = (req.headers['upgrade'] || '').toLowerCase();
    if (upgrade !== 'websocket') {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }

    const clientKey = req.headers['sec-websocket-key'];
    if (!clientKey) {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }

    const acceptKey = crypto
      .createHash('sha1')
      .update(clientKey + WS_MAGIC_GUID)
      .digest('base64');

    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${acceptKey}\r\n` +
      '\r\n'
    );

    const client = new WebSocketClient(socket, this);
    this.clients.add(client);

    console.log(`[ws] client connected (${this.clients.size} total)`);

    // Process any data that arrived with the upgrade request
    if (head && head.length > 0) {
      client.handleData(head);
    }
  }

  broadcast(message, sender) {
    for (const client of this.clients) {
      if (client !== sender && client.open) {
        client.send(message);
      }
    }
  }

  removeClient(client) {
    this.clients.delete(client);
    console.log(`[ws] client disconnected (${this.clients.size} total)`);
  }

  listen(port, callback) {
    this.httpServer.listen(port, callback);
  }

  close(callback) {
    for (const client of this.clients) {
      client.close(1001, 'Server shutting down');
    }
    this.httpServer.close(callback);
  }
}

class WebSocketClient {
  constructor(socket, server) {
    this.socket = socket;
    this.server = server;
    this.open = true;
    this.buffer = Buffer.alloc(0);
    this.fragments = [];        // For fragmented messages
    this.fragmentOpcode = null; // Opcode of the fragmented message

    // Ping/pong heartbeat
    this.pingTimer = setInterval(() => {
      if (this.open) {
        this.socket.write(encodePingFrame(Buffer.from(Date.now().toString())));
      }
    }, 30_000);
    this.pingTimer.unref();

    socket.on('data', (chunk) => this.handleData(chunk));
    socket.on('close', () => this.handleClose());
    socket.on('error', (err) => this.handleError(err));
  }

  handleData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    while (this.buffer.length > 0) {
      const frame = parseFrame(this.buffer);
      if (!frame) break; // Not enough data for a complete frame

      this.buffer = this.buffer.subarray(frame.totalFrameSize);
      this.processFrame(frame);
    }
  }

  processFrame(frame) {
    // Control frames (close, ping, pong) can be interleaved with data fragments
    if (frame.opcode === OPCODE.CLOSE) {
      this.handleCloseFrame(frame);
      return;
    }

    if (frame.opcode === OPCODE.PING) {
      // Respond with PONG echoing the same payload
      this.socket.write(encodePongFrame(frame.payload));
      return;
    }

    if (frame.opcode === OPCODE.PONG) {
      // Heartbeat received — connection is alive
      const sent = parseInt(frame.payload.toString('utf8'), 10);
      if (!isNaN(sent)) {
        const latency = Date.now() - sent;
        console.log(`[ws] pong latency: ${latency}ms`);
      }
      return;
    }

    // Data frames — handle fragmentation
    if (frame.opcode === OPCODE.CONTINUATION) {
      // Continuation of a fragmented message
      if (this.fragments.length === 0) {
        console.error('[ws] received continuation frame without initial fragment');
        this.close(1002, 'Protocol error');
        return;
      }

      this.fragments.push(frame.payload);

      if (frame.fin) {
        // Final fragment — reassemble the message
        const fullPayload = Buffer.concat(this.fragments);
        this.fragments = [];
        this.onMessage(this.fragmentOpcode, fullPayload);
        this.fragmentOpcode = null;
      }
      return;
    }

    // New data frame (TEXT or BINARY)
    if (frame.fin) {
      // Unfragmented message — process immediately
      this.onMessage(frame.opcode, frame.payload);
    } else {
      // First fragment of a multi-frame message
      this.fragmentOpcode = frame.opcode;
      this.fragments = [frame.payload];
    }
  }

  onMessage(opcode, payload) {
    if (opcode === OPCODE.TEXT) {
      const text = payload.toString('utf8');
      console.log(`[ws] text message: ${text}`);

      // Echo back and broadcast
      this.send(`Echo: ${text}`);
      this.server.broadcast(`[${this.socket.remoteAddress}]: ${text}`, this);

    } else if (opcode === OPCODE.BINARY) {
      console.log(`[ws] binary message: ${payload.length} bytes`);
      // Echo binary data back
      this.sendBinary(payload);
    }
  }

  send(text) {
    if (!this.open) return;
    this.socket.write(encodeTextFrame(text));
  }

  sendBinary(data) {
    if (!this.open) return;
    this.socket.write(encodeBinaryFrame(data));
  }

  close(statusCode = 1000, reason = '') {
    if (!this.open) return;
    this.open = false;
    this.socket.write(encodeCloseFrame(statusCode, reason));
    // Give the client a moment to receive the close frame, then destroy
    setTimeout(() => {
      if (!this.socket.destroyed) {
        this.socket.destroy();
      }
    }, 3000);
  }

  handleCloseFrame(frame) {
    let statusCode = null;
    let reason = '';

    if (frame.payload.length >= 2) {
      statusCode = frame.payload.readUInt16BE(0);
      reason = frame.payload.subarray(2).toString('utf8');
    }

    console.log(`[ws] close frame received: code=${statusCode}, reason="${reason}"`);

    // Respond with a close frame (the close handshake)
    if (this.open) {
      this.open = false;
      this.socket.write(encodeCloseFrame(statusCode || 1000, ''));
      this.socket.end();
    }
  }

  handleClose() {
    this.open = false;
    clearInterval(this.pingTimer);
    this.server.removeClient(this);
  }

  handleError(err) {
    console.error(`[ws] socket error: ${err.message}`);
    this.open = false;
    clearInterval(this.pingTimer);
    this.server.removeClient(this);
  }
}

// --- Start the server ---
const wss = new WebSocketServer();
wss.listen(8080, () => {
  console.log('WebSocket server listening on ws://127.0.0.1:8080');
});
```

---

## WebSocket Close Status Codes

RFC 6455 defines standard close status codes:

```javascript
'use strict';

const CLOSE_CODES = {
  1000: 'Normal Closure',
  1001: 'Going Away',          // Server shutting down, browser navigating away
  1002: 'Protocol Error',      // Invalid frame, unexpected opcode
  1003: 'Unsupported Data',    // Received text when only binary expected
  1005: 'No Status Received',  // Must not be sent in a close frame
  1006: 'Abnormal Closure',    // Connection lost without close handshake
  1007: 'Invalid Payload',     // Text frame with invalid UTF-8
  1008: 'Policy Violation',    // Generic "you broke the rules"
  1009: 'Message Too Big',     // Payload exceeds server limit
  1010: 'Mandatory Extension', // Client expected extension server did not negotiate
  1011: 'Internal Error',      // Server hit unexpected condition
  1012: 'Service Restart',     // Server restarting
  1013: 'Try Again Later',     // Server temporarily unavailable
  1015: 'TLS Handshake Fail',  // Must not be sent in a close frame
};

// Application-specific codes use range 4000-4999
const APP_CODES = {
  4000: 'Authentication Required',
  4001: 'Authentication Failed',
  4002: 'Rate Limited',
  4003: 'Forbidden Resource',
};

function describeCloseCode(code) {
  return CLOSE_CODES[code] || APP_CODES[code] || `Unknown (${code})`;
}

console.log(describeCloseCode(1000)); // "Normal Closure"
console.log(describeCloseCode(1006)); // "Abnormal Closure"
console.log(describeCloseCode(4002)); // "Rate Limited"
```

---

## The Close Handshake

The WebSocket close handshake is a two-way exchange, similar to TCP FIN:

1. One side sends a Close frame (with optional status code + reason)
2. The other side responds with a Close frame (echoing the status code)
3. The TCP connection is then closed

```javascript
'use strict';

// Close handshake state machine
const CloseState = {
  OPEN:       'OPEN',
  CLOSING:    'CLOSING',    // We sent a close frame, waiting for the response
  CLOSED:     'CLOSED',     // Close handshake complete
};

class CloseHandshake {
  constructor(socket) {
    this.socket = socket;
    this.state = CloseState.OPEN;
    this.closeTimer = null;
  }

  // Initiate close from our side
  initiateClose(statusCode, reason) {
    if (this.state !== CloseState.OPEN) return;

    this.state = CloseState.CLOSING;
    this.socket.write(encodeCloseFrame(statusCode, reason));

    // If the peer does not respond within 5 seconds, force close
    this.closeTimer = setTimeout(() => {
      console.warn('[ws] close handshake timed out — forcing connection close');
      this.state = CloseState.CLOSED;
      this.socket.destroy();
    }, 5000);
    this.closeTimer.unref();
  }

  // Handle receiving a close frame from the peer
  receiveClose(statusCode, reason) {
    if (this.state === CloseState.OPEN) {
      // Peer initiated close — echo back the close frame
      this.state = CloseState.CLOSED;
      this.socket.write(encodeCloseFrame(statusCode || 1000, ''));
      this.socket.end();
    } else if (this.state === CloseState.CLOSING) {
      // We initiated, peer responded — handshake complete
      clearTimeout(this.closeTimer);
      this.state = CloseState.CLOSED;
      this.socket.end();
    }

    console.log(`[ws] close handshake complete: ${statusCode} "${reason}"`);
  }
}
```

---

## Handling Fragmented Messages

Large messages can be split across multiple frames. The first frame has the actual opcode (TEXT or BINARY) with FIN=0. Subsequent frames use opcode 0x0 (CONTINUATION). The last frame has FIN=1.

```javascript
'use strict';

// Sending a fragmented message (server-side)
function sendFragmented(socket, opcode, data, fragmentSize) {
  const totalLength = data.length;
  let offset = 0;
  let isFirst = true;

  while (offset < totalLength) {
    const end = Math.min(offset + fragmentSize, totalLength);
    const chunk = data.subarray(offset, end);
    const isLast = (end === totalLength);

    const frameOpcode = isFirst ? opcode : OPCODE.CONTINUATION;
    const frame = encodeFrame(frameOpcode, chunk, isLast); // fin=true only on last

    socket.write(frame);

    console.log(
      `[fragment] sent ${isFirst ? 'first' : isLast ? 'final' : 'middle'} ` +
      `frame: ${chunk.length} bytes, fin=${isLast}`
    );

    isFirst = false;
    offset = end;
  }
}

// Example: send a 5000-byte message in 1500-byte fragments
// sendFragmented(socket, OPCODE.TEXT, Buffer.from('x'.repeat(5000)), 1500);
// Produces: frame 1 (1500, fin=0), frame 2 (1500, fin=0), frame 3 (1500, fin=0), frame 4 (500, fin=1)

// Receiving fragmented messages (already handled in WebSocketClient.processFrame above)
// The key rules from RFC 6455:
// 1. Control frames (ping, pong, close) CAN be interleaved between data fragments
// 2. Data fragments MUST arrive in order
// 3. A new data message CANNOT begin until the current one is fully received
// 4. The opcode is only in the first fragment; continuations use opcode 0x0
```

---

## Testing With a WebSocket Client

You can test the server using Node.js as a client by manually performing the HTTP upgrade.

```javascript
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

function connectWebSocket(url) {
  const parsed = new URL(url);
  const key = crypto.randomBytes(16).toString('base64');

  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: parsed.hostname,
      port: parsed.port || 80,
      path: parsed.pathname,
      method: 'GET',
      headers: {
        'Upgrade': 'websocket',
        'Connection': 'Upgrade',
        'Sec-WebSocket-Key': key,
        'Sec-WebSocket-Version': '13',
      },
    });

    req.on('upgrade', (res, socket, head) => {
      // Verify the accept key
      const expectedAccept = crypto
        .createHash('sha1')
        .update(key + '258EAFA5-E914-47DA-95CA-5AB5DC11E5B3')
        .digest('base64');

      const actualAccept = res.headers['sec-websocket-accept'];
      if (actualAccept !== expectedAccept) {
        socket.destroy();
        reject(new Error('Invalid Sec-WebSocket-Accept'));
        return;
      }

      console.log('[client] WebSocket handshake verified');
      resolve({ socket, head });
    });

    req.on('error', reject);
    req.end();
  });
}

// Client must mask frames (RFC 6455 Section 5.3)
function encodeMaskedFrame(opcode, payload, fin = true) {
  const payloadBuf = Buffer.isBuffer(payload)
    ? payload
    : Buffer.from(payload || '', 'utf8');

  const maskingKey = crypto.randomBytes(4);

  let headerSize;
  if (payloadBuf.length < 126) {
    headerSize = 2;
  } else if (payloadBuf.length < 65536) {
    headerSize = 4;
  } else {
    headerSize = 10;
  }

  const frame = Buffer.alloc(headerSize + 4 + payloadBuf.length); // +4 for masking key

  // Byte 1: FIN + opcode
  frame[0] = (fin ? 0x80 : 0x00) | (opcode & 0x0F);

  // Byte 2: MASK=1 + payload length
  if (payloadBuf.length < 126) {
    frame[1] = 0x80 | payloadBuf.length;
  } else if (payloadBuf.length < 65536) {
    frame[1] = 0x80 | 126;
    frame.writeUInt16BE(payloadBuf.length, 2);
  } else {
    frame[1] = 0x80 | 127;
    frame.writeUInt32BE(0, 2);
    frame.writeUInt32BE(payloadBuf.length, 6);
  }

  // Masking key
  maskingKey.copy(frame, headerSize);

  // Masked payload
  for (let i = 0; i < payloadBuf.length; i++) {
    frame[headerSize + 4 + i] = payloadBuf[i] ^ maskingKey[i & 3];
  }

  return frame;
}

// Usage
async function clientDemo() {
  const { socket, head } = await connectWebSocket('ws://127.0.0.1:8080/chat');

  const decoder = { buffer: Buffer.alloc(0) };

  // Process any data from the upgrade response
  if (head && head.length > 0) {
    decoder.buffer = head;
  }

  socket.on('data', (chunk) => {
    decoder.buffer = Buffer.concat([decoder.buffer, chunk]);

    while (decoder.buffer.length > 0) {
      const frame = parseFrame(decoder.buffer);
      if (!frame) break;
      decoder.buffer = decoder.buffer.subarray(frame.totalFrameSize);

      if (frame.opcode === OPCODE.TEXT) {
        console.log('[client] received:', frame.payload.toString('utf8'));
      } else if (frame.opcode === OPCODE.PING) {
        socket.write(encodeMaskedFrame(OPCODE.PONG, frame.payload));
      } else if (frame.opcode === OPCODE.CLOSE) {
        console.log('[client] server closed connection');
        socket.write(encodeMaskedFrame(OPCODE.CLOSE, frame.payload));
        socket.end();
      }
    }
  });

  // Send a text message (masked, as required by the client role)
  socket.write(encodeMaskedFrame(OPCODE.TEXT, 'Hello from Node.js client!'));

  // Send another after 1 second
  setTimeout(() => {
    socket.write(encodeMaskedFrame(OPCODE.TEXT, 'Second message'));
  }, 1000);

  // Close after 3 seconds
  setTimeout(() => {
    socket.write(encodeMaskedFrame(OPCODE.CLOSE, Buffer.from([0x03, 0xE8]))); // 1000 = normal
  }, 3000);
}

// clientDemo().catch(console.error);
```

---

## Why Masking Exists

Client-to-server frames must be masked. This is not for encryption — the masking key is in the frame itself and trivially reversible. Masking exists to prevent cache poisoning attacks: without masking, a malicious WebSocket client could craft frames that look like valid HTTP responses to an intermediary proxy, potentially poisoning its cache with attacker-controlled content. The XOR masking makes the bytes on the wire unpredictable to intermediary infrastructure.

```javascript
'use strict';

// Masking is a simple XOR operation — reversible with the same key
const payload = Buffer.from('Hello', 'utf8');
const key = Buffer.from([0x37, 0xFA, 0x21, 0x3D]);

// Mask
const masked = Buffer.allocUnsafe(payload.length);
for (let i = 0; i < payload.length; i++) {
  masked[i] = payload[i] ^ key[i & 3];
}
console.log('Masked:  ', masked.toString('hex'));

// Unmask (same operation)
const unmasked = Buffer.allocUnsafe(masked.length);
for (let i = 0; i < masked.length; i++) {
  unmasked[i] = masked[i] ^ key[i & 3];
}
console.log('Unmasked:', unmasked.toString('utf8')); // "Hello"

// Key takeaway: masking defeats proxy cache poisoning, NOT eavesdropping.
// For confidentiality, use WSS (WebSocket over TLS).
```

---

## Key Takeaways

- The WebSocket handshake is a standard HTTP upgrade: the client sends `Sec-WebSocket-Key`, the server hashes it with SHA-1 and the magic GUID `258EAFA5-E914-47DA-95CA-5AB5DC11E5B3`, and responds with `101 Switching Protocols` — after that, the TCP socket carries WebSocket frames, not HTTP.
- WebSocket frames encode the payload length in three tiers: 7-bit (0-125 bytes, most common), 16-bit extended (126-65535 bytes), and 64-bit extended (65536+ bytes) — the variable encoding keeps small messages compact while supporting large payloads.
- Client-to-server frames must be masked with a 4-byte XOR key to prevent proxy cache poisoning attacks; server-to-client frames are never masked — this asymmetry is a security requirement of the protocol, not an encryption mechanism.
- Ping/pong frames provide a heartbeat mechanism: either side can send a Ping, and the other must respond with a Pong echoing the same payload — this detects dead connections faster than TCP keepalive probes.
- The close handshake is a two-way exchange (Close frame followed by Close response) with a status code and optional reason text — applications should always attempt a clean close rather than destroying the socket, and enforce a timeout in case the peer never responds.

---

## Next

This is the final lesson in Track 04. Return to the [Track 04 README](README.md) to review what you have learned, or explore one of the other specialized tracks.
