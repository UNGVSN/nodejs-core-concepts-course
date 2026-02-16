# Module 06 / Lesson 07 — Building TCP Servers & Clients

> Knowing the `net` API is not the same as knowing how to build reliable TCP applications. TCP is a byte stream, not a message stream — the data you `write()` on one end does not arrive in the same chunks on the other end. This lesson teaches you how to frame messages, track connections, broadcast to multiple clients, and shut down gracefully. These are the patterns that separate a toy socket example from a production-ready network service.

## Learning Objectives

- Build a TCP echo server that correctly handles multiple concurrent connections
- Implement message framing using both length-prefix and newline-delimiter strategies
- Buffer partial reads and reassemble complete messages from fragmented TCP data
- Track connected clients with a `Set` and broadcast messages to all of them
- Implement graceful server shutdown that drains existing connections before exiting

---

## A Simple Echo Server

The echo server is the "Hello, World" of TCP programming. It sends back whatever the client sends.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  console.log(`[${addr}] connected`);

  socket.on('data', (chunk) => {
    console.log(`[${addr}] received ${chunk.length} bytes`);
    socket.write(chunk); // Echo the data back
  });

  socket.on('end', () => {
    console.log(`[${addr}] disconnected`);
  });

  socket.on('error', (err) => {
    console.error(`[${addr}] error: ${err.message}`);
  });
});

server.listen(4000, () => {
  console.log('Echo server listening on port 4000');
});
```

Test this with `nc` (netcat) or `telnet`:

```bash
# Terminal 1 — start the server
node echo-server.js

# Terminal 2 — connect as a client
nc 127.0.0.1 4000
Hello        # type this, press Enter
Hello        # server echoes it back
```

This works for a quick demo, but it has a fundamental problem: it treats every `'data'` event as a complete message. In reality, TCP makes no such guarantee.

---

## Why TCP Is Not a Message Protocol

TCP is a **byte stream**. When you call `socket.write('Hello')` followed by `socket.write('World')`, the remote end might receive:

- `'HelloWorld'` — both writes in a single `'data'` event (coalescing)
- `'Hello'` then `'World'` — each write as a separate event
- `'Hel'` then `'loWorld'` — split in the middle (fragmentation)
- `'Hell'` then `'oWor'` then `'ld'` — three events from two writes

The OS TCP stack, Nagle's algorithm, network MTU, and kernel buffer sizes all influence how data is chunked. You cannot rely on a one-to-one mapping between `write()` calls and `'data'` events.

```
Sender:   write("Hello")   write("World")
           ↓                 ↓
TCP:      [H][e][l][l][o][W][o][r][l][d]   ← continuous byte stream
           ↓
Receiver: 'data' events are arbitrary chunks:
          [H][e][l]        → first event
          [l][o][W][o]     → second event
          [r][l][d]        → third event
```

To send discrete messages over TCP, you need a **framing protocol**.

---

## Framing Strategy 1: Newline-Delimited (NDJSON)

The simplest framing strategy: separate messages with a delimiter character. Newline (`\n`) is the most common choice because it works with line-based tools like `nc` and `telnet`.

### The Buffering Problem

You cannot assume each `'data'` event contains exactly one complete line. You must buffer incoming data and split on the delimiter.

```javascript
'use strict';

const net = require('node:net');

/**
 * Wraps a socket with newline-delimited message framing.
 * Emits 'message' events with complete lines.
 */
function createLineParser(socket) {
  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString();

    // Process all complete lines in the buffer
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex);
      buffer = buffer.slice(newlineIndex + 1);

      if (line.length > 0) {
        socket.emit('message', line);
      }
    }
  });

  // When the connection ends, process any remaining data
  socket.on('end', () => {
    if (buffer.length > 0) {
      socket.emit('message', buffer);
      buffer = '';
    }
  });
}

const server = net.createServer((socket) => {
  createLineParser(socket);

  socket.on('message', (message) => {
    console.log('Complete message:', message);
    socket.write(`ACK: ${message}\n`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000, () => {
  console.log('Line-delimited server on port 4000');
});
```

### NDJSON (Newline-Delimited JSON)

NDJSON sends one JSON object per line. It is widely used in logging, streaming APIs, and inter-process communication.

```javascript
'use strict';

const net = require('node:net');

function createNDJSONParser(socket) {
  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString();

    let newlineIndex;
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);

      if (line.length === 0) continue;

      try {
        const obj = JSON.parse(line);
        socket.emit('message', obj);
      } catch (err) {
        socket.emit('parseError', line, err);
      }
    }
  });
}

const server = net.createServer((socket) => {
  createNDJSONParser(socket);

  socket.on('message', (obj) => {
    console.log('Parsed message:', obj);

    // Respond with NDJSON
    const response = JSON.stringify({ status: 'ok', echo: obj });
    socket.write(response + '\n');
  });

  socket.on('parseError', (line, err) => {
    console.error('Invalid JSON:', line);
    const errResponse = JSON.stringify({ status: 'error', message: err.message });
    socket.write(errResponse + '\n');
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000, () => {
  console.log('NDJSON server on port 4000');
});
```

### Trade-offs of Delimiter Framing

| Advantage | Disadvantage |
|-----------|-------------|
| Simple to implement | The delimiter cannot appear in the message body |
| Human-readable (works with `nc`, `telnet`) | No built-in integrity checks |
| Streaming-friendly | Binary data requires encoding (e.g., Base64) |
| Compatible with standard line-processing tools | Must scan every byte for the delimiter |

---

## Framing Strategy 2: Length-Prefix

Length-prefix framing prepends a fixed-size header containing the message length. The receiver reads the header first, then reads exactly that many bytes for the payload. This is the standard approach for binary protocols.

### 4-Byte Length-Prefix Protocol

```
┌──────────────┬─────────────────────────────────┐
│ 4 bytes      │ N bytes                         │
│ UInt32BE     │ Payload                         │
│ (msg length) │ (the actual message)            │
└──────────────┴─────────────────────────────────┘
```

### Implementation: Encoder

```javascript
'use strict';

/**
 * Encodes a message with a 4-byte length prefix (UInt32BE).
 * @param {string|Buffer} message
 * @returns {Buffer}
 */
function encodeMessage(message) {
  const payload = Buffer.isBuffer(message) ? message : Buffer.from(message);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, payload]);
}

// Example
const encoded = encodeMessage('Hello, TCP!');
console.log('Encoded:', encoded);
console.log('Header (length):', encoded.readUInt32BE(0));   // 11
console.log('Payload:', encoded.subarray(4).toString());     // Hello, TCP!
```

### Implementation: Decoder

The decoder is more complex because data arrives in arbitrary chunks. A single `'data'` event might contain half a header, three complete messages, or anything in between.

```javascript
'use strict';

const { EventEmitter } = require('node:events');

const HEADER_SIZE = 4; // 4 bytes for UInt32BE length prefix

class LengthPrefixDecoder extends EventEmitter {
  #buffer = Buffer.alloc(0);
  #expectedLength = 0;
  #readingHeader = true;

  /**
   * Feed raw bytes from a 'data' event into the decoder.
   * Complete messages are emitted as 'message' events.
   */
  write(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    this.#parse();
  }

  #parse() {
    while (true) {
      if (this.#readingHeader) {
        // Do we have enough bytes for the header?
        if (this.#buffer.length < HEADER_SIZE) return;

        this.#expectedLength = this.#buffer.readUInt32BE(0);
        this.#buffer = this.#buffer.subarray(HEADER_SIZE);
        this.#readingHeader = false;
      }

      // Do we have enough bytes for the payload?
      if (this.#buffer.length < this.#expectedLength) return;

      // Extract the complete message
      const message = this.#buffer.subarray(0, this.#expectedLength);
      this.#buffer = this.#buffer.subarray(this.#expectedLength);
      this.#readingHeader = true;

      this.emit('message', message);
    }
  }
}

module.exports = { encodeMessage, LengthPrefixDecoder };
```

### Using the Encoder and Decoder

On the server, create a `LengthPrefixDecoder` for each socket and feed `'data'` chunks into it. On the client, use `encodeMessage()` to wrap outbound data. Even if three `encodeMessage()` calls coalesce into a single TCP segment, the decoder correctly extracts all three messages thanks to its state machine.

### Trade-offs of Length-Prefix Framing

| Advantage | Disadvantage |
|-----------|-------------|
| Handles binary data natively | Not human-readable over `nc`/`telnet` |
| No scanning — you know exactly how many bytes to read | Requires careful buffer management |
| Fast and efficient | A corrupt header can desync the stream |
| The message body can contain any byte | Fixed header overhead (4 bytes per message) |

---

## Connection Tracking

Any real server needs to know which clients are connected. Use a `Set` to track active sockets.

```javascript
'use strict';

const net = require('node:net');

const clients = new Set();

const server = net.createServer((socket) => {
  clients.add(socket);
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  console.log(`[+] ${addr} connected (${clients.size} total)`);

  socket.on('close', () => {
    clients.delete(socket);
    console.log(`[-] ${addr} disconnected (${clients.size} total)`);
  });

  socket.on('error', (err) => {
    console.error(`[!] ${addr} error: ${err.message}`);
    // The 'close' event fires after 'error', so the Set cleanup happens there
  });
});

server.listen(4000, () => {
  console.log('Server listening on port 4000');
});
```

---

## Broadcasting to All Clients

Sending a message to every connected client is a common pattern for chat servers, real-time feeds, and pub/sub systems.

```javascript
'use strict';

const net = require('node:net');

const clients = new Set();

/**
 * Broadcast a message to all connected clients except the sender.
 */
function broadcast(sender, message) {
  for (const client of clients) {
    if (client !== sender && !client.destroyed) {
      client.write(message);
    }
  }
}

const server = net.createServer((socket) => {
  clients.add(socket);

  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  broadcast(socket, `[Server] ${addr} joined the chat\n`);
  socket.write(`[Server] Welcome! ${clients.size} users online.\n`);

  socket.on('data', (chunk) => {
    const message = chunk.toString().trim();
    if (message.length > 0) {
      broadcast(socket, `[${addr}] ${message}\n`);
    }
  });

  socket.on('close', () => {
    clients.delete(socket);
    broadcast(socket, `[Server] ${addr} left the chat\n`);
  });

  socket.on('error', (err) => {
    console.error(`[${addr}] Error: ${err.message}`);
  });
});

server.listen(4000, () => {
  console.log('Chat server on port 4000');
  console.log('Connect with: nc 127.0.0.1 4000');
});
```

Note: In production, check the return value of `client.write()` to detect slow consumers. If it returns `false`, the client's buffer is full — you may need to drop messages or disconnect the client. See Lesson 08 for backpressure debugging.

---

## A Complete Multi-Client Chat Server

This example combines connection tracking, NDJSON framing, usernames, and server commands.

```javascript
'use strict';

const net = require('node:net');

const clients = new Map(); // socket → { username, buffer }

function broadcast(sender, obj) {
  const line = JSON.stringify(obj) + '\n';
  for (const [socket] of clients) {
    if (socket !== sender && !socket.destroyed) {
      socket.write(line);
    }
  }
}

function parseLines(socket, handler) {
  const state = clients.get(socket);

  return (chunk) => {
    state.buffer += chunk.toString();

    let idx;
    while ((idx = state.buffer.indexOf('\n')) !== -1) {
      const line = state.buffer.slice(0, idx).trim();
      state.buffer = state.buffer.slice(idx + 1);
      if (line.length > 0) handler(line);
    }
  };
}

const server = net.createServer((socket) => {
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  clients.set(socket, { username: addr, buffer: '' });

  socket.write(JSON.stringify({
    type: 'system',
    message: 'Welcome! Send {"type":"setName","name":"YourName"} to set your username.'
  }) + '\n');

  socket.on('data', parseLines(socket, (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      socket.write(JSON.stringify({ type: 'error', message: 'Invalid JSON' }) + '\n');
      return;
    }

    const state = clients.get(socket);

    if (msg.type === 'setName' && typeof msg.name === 'string') {
      const oldName = state.username;
      state.username = msg.name.slice(0, 20); // Limit length
      broadcast(socket, {
        type: 'system',
        message: `${oldName} is now known as ${state.username}`
      });
      return;
    }

    if (msg.type === 'chat' && typeof msg.text === 'string') {
      broadcast(socket, {
        type: 'chat',
        from: state.username,
        text: msg.text.slice(0, 500), // Limit message length
        timestamp: Date.now()
      });
      return;
    }

    socket.write(JSON.stringify({ type: 'error', message: `Unknown type: ${msg.type}` }) + '\n');
  }));

  socket.on('close', () => {
    const state = clients.get(socket);
    clients.delete(socket);
    broadcast(socket, {
      type: 'system',
      message: `${state.username} has left (${clients.size} online)`
    });
  });

  socket.on('error', (err) => {
    console.error(`[${addr}] Error: ${err.message}`);
  });
});

server.listen(4000, () => {
  console.log('Chat server on port 4000');
});
```

---

## Client Implementation With Reconnection

A robust client should handle disconnections and reconnect automatically.

```javascript
'use strict';

const net = require('node:net');

const HOST = '127.0.0.1';
const PORT = 4000;
const MAX_RETRIES = 10;
const BASE_DELAY_MS = 1000;

let retries = 0;
let client = null;

function connect() {
  client = net.createConnection({ port: PORT, host: HOST }, () => {
    console.log('Connected to server');
    retries = 0; // Reset on successful connection

    // Send a greeting
    client.write('Hello from reconnecting client\n');
  });

  client.on('data', (chunk) => {
    process.stdout.write(`Server: ${chunk}`);
  });

  client.on('end', () => {
    console.log('Server closed the connection');
  });

  client.on('close', () => {
    if (retries >= MAX_RETRIES) {
      console.error(`Failed to connect after ${MAX_RETRIES} attempts. Giving up.`);
      process.exit(1);
    }

    // Exponential backoff with jitter
    const delay = Math.min(BASE_DELAY_MS * Math.pow(2, retries), 30_000);
    const jitter = Math.random() * delay * 0.2; // 20% jitter
    const totalDelay = Math.floor(delay + jitter);

    retries++;
    console.log(`Reconnecting in ${totalDelay}ms (attempt ${retries}/${MAX_RETRIES})...`);

    setTimeout(connect, totalDelay);
  });

  client.on('error', (err) => {
    console.error(`Connection error: ${err.message}`);
    // The 'close' event fires after 'error', triggering reconnection
  });
}

connect();
```

The exponential backoff (`2^retries`) increases delay from 1s to 2s to 4s to 8s, capped at 30s. Jitter (random variation) prevents the "thundering herd" problem where all clients reconnect at the exact same time after a server restart.

---

## Graceful Shutdown

A server that abruptly closes leaves clients in limbo. Graceful shutdown follows a specific sequence:

1. Stop accepting new connections (`server.close()`)
2. Notify connected clients that the server is shutting down
3. Wait for clients to finish or enforce a timeout
4. Exit the process

```javascript
'use strict';

const net = require('node:net');

const clients = new Set();
const SHUTDOWN_TIMEOUT_MS = 5000;

const server = net.createServer((socket) => {
  clients.add(socket);

  socket.on('data', (chunk) => {
    socket.write(`Echo: ${chunk}`);
  });

  socket.on('close', () => {
    clients.delete(socket);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

function gracefulShutdown(signal) {
  console.log(`\n[${signal}] Shutting down gracefully...`);

  // Step 1: Stop accepting new connections
  server.close(() => {
    console.log('Server closed — no more new connections');
    process.exit(0);
  });

  // Step 2: Notify all connected clients
  for (const socket of clients) {
    socket.write('[Server] Shutting down. Goodbye.\n');
    socket.end(); // Send FIN — graceful close
  }

  // Step 3: Force shutdown after timeout if clients do not disconnect
  setTimeout(() => {
    console.warn('Forcing shutdown — destroying remaining connections');
    for (const socket of clients) {
      socket.destroy();
    }
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS);
}

process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));

server.listen(4000, () => {
  console.log('Server listening on port 4000');
  console.log('Press Ctrl+C to trigger graceful shutdown');
});
```

---

## Connection Limits

The `server.maxConnections` property caps the number of simultaneous connections. Excess connections trigger the `'drop'` event.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  server.getConnections((err, count) => {
    if (err) {
      socket.destroy();
      return;
    }
    socket.write(`Welcome. ${count} connections active.\n`);
  });

  socket.on('data', (chunk) => {
    socket.write(`Echo: ${chunk}`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.maxConnections = 5;

server.on('drop', (data) => {
  console.warn(
    `Connection dropped from ${data.remoteAddress}:${data.remotePort}` +
    ` — max ${server.maxConnections} reached`
  );
});

server.listen(4000, () => {
  console.log(`Server on port 4000 (max ${server.maxConnections} connections)`);
});
```

---

## Choosing a Framing Strategy

| Criterion | Newline-Delimited | Length-Prefix |
|-----------|-------------------|---------------|
| Data type | Text / JSON | Text or binary |
| Debuggability | Easy — use `nc`, `curl`, logs | Hard — binary headers |
| Implementation | Simple string split | State machine with buffers |
| Performance | Must scan every byte for `\n` | Read fixed header, then payload |
| Max message size | Practical limit ~1 MB | Up to 4 GB (UInt32) |
| Corruption recovery | Skip to next `\n` | Difficult — stream desync |
| Use cases | APIs, logging, config | File transfer, multiplexing, custom protocols |

For most application-level protocols (chat, RPC, command-and-control), NDJSON is the pragmatic choice. For binary protocols or high-throughput scenarios, length-prefix framing is superior.

---

## Key Takeaways

- TCP is a byte stream with no message boundaries — every TCP application must implement its own framing protocol to know where one message ends and the next begins.
- Newline-delimited framing is simple and human-readable but cannot handle binary payloads or messages containing the delimiter; length-prefix framing handles arbitrary data but requires careful buffer state management.
- Track connected sockets in a `Set` or `Map` so you can broadcast, count connections, and clean up on disconnect; always remove sockets in the `'close'` handler, not the `'end'` handler.
- Reconnecting clients should use exponential backoff with jitter to avoid thundering herd problems when a server restarts under load.
- Graceful shutdown requires three steps in order: stop accepting new connections, notify and drain existing clients, then enforce a hard timeout before calling `process.exit()`.

---

## Next

Continue to [Lesson 08 — Network Debugging](lesson-08-network-debugging.md) to learn how to diagnose connection leaks, half-open sockets, and performance issues in your TCP applications.
