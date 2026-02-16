# Module 06 / Lesson 06 — The net Module

> Every TCP connection in Node.js passes through `node:net`. Whether you are building an HTTP server, a database driver, or a custom binary protocol, the `net` module is the foundation. Understanding it means understanding the lowest level of network programming that Node.js exposes — and that understanding pays dividends every time you debug a connection timeout, a half-open socket, or an `EADDRINUSE` error at 2 AM.

## Learning Objectives

- Create TCP servers with `net.createServer()` and configure `allowHalfOpen` and `pauseOnConnect`
- Work with the `net.Server` lifecycle: `.listen()`, `.close()`, `.address()`, `.getConnections()`
- Connect to remote servers using `net.createConnection()` and handle the resulting `net.Socket`
- Read and write data over `net.Socket` as a Duplex Stream, using the correct event listeners
- Diagnose common networking errors (`EADDRINUSE`, `ECONNREFUSED`, `ECONNRESET`, `ETIMEDOUT`) and apply appropriate recovery strategies

---

## What Is the `net` Module?

The `node:net` module provides an asynchronous API for creating TCP servers and TCP clients. It also supports IPC (inter-process communication) through Unix domain sockets on Linux/macOS and named pipes on Windows.

Everything above TCP in Node.js — `node:http`, `node:https`, `node:tls` — is built on top of `node:net`. When you call `http.createServer()`, Node.js internally creates a `net.Server`. When an HTTP client connects, the underlying transport is a `net.Socket`.

```
┌─────────────────────────────────────────────┐
│              Your Application               │
├──────────┬──────────┬───────────────────────┤
│  node:http  │ node:https │   node:tls         │
├──────────┴──────────┴───────────────────────┤
│                 node:net                     │
├─────────────────────────────────────────────┤
│             libuv / OS TCP stack             │
└─────────────────────────────────────────────┘
```

---

## Creating a TCP Server

The simplest TCP server accepts connections and reads data from them.

### `net.createServer([options], [connectionListener])`

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  console.log('Client connected from', socket.remoteAddress, socket.remotePort);

  socket.on('data', (chunk) => {
    console.log('Received:', chunk.toString());
  });

  socket.on('end', () => {
    console.log('Client disconnected');
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000, '127.0.0.1', () => {
  const addr = server.address();
  console.log(`TCP server listening on ${addr.address}:${addr.port}`);
});
```

The `connectionListener` callback receives a `net.Socket` instance for each new connection. That socket is a Duplex Stream — it is both readable and writable.

### Server Options

`net.createServer()` accepts an options object:

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `allowHalfOpen` | `boolean` | `false` | If `true`, the socket will not automatically send a FIN when the other end sends a FIN. You must call `socket.end()` manually. |
| `pauseOnConnect` | `boolean` | `false` | If `true`, the socket is paused when connected. You must call `socket.resume()` to start receiving data. Useful for passing sockets between processes. |
| `noDelay` | `boolean` | `false` | If `true`, disables the Nagle algorithm on every new connection immediately. |
| `keepAlive` | `boolean` | `false` | If `true`, enables TCP keep-alive on every new connection. |
| `keepAliveInitialDelay` | `number` | `0` | Milliseconds of idle time before the first keep-alive probe is sent. |

```javascript
'use strict';

const net = require('node:net');

// Half-open connections: the server keeps writing even after the client
// signals it is done sending. Useful for protocols where the server
// needs to finish a response after the client closes its write side.
const server = net.createServer({ allowHalfOpen: true }, (socket) => {
  socket.on('data', (chunk) => {
    console.log('Received:', chunk.toString());
  });

  socket.on('end', () => {
    // Client sent FIN — it is done sending, but we can still write
    console.log('Client finished sending. Sending final response...');
    socket.write('Thank you for all the data.\n');
    socket.end(); // Now we send our FIN
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

---

## The `net.Server` Class

Once you create a server, you interact with the `net.Server` instance to control its lifecycle.

### `.listen()`

The server starts accepting connections when you call `.listen()`. There are several signatures:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.end('Hello\n');
});

// Signature 1: port and optional host
server.listen(4000, '0.0.0.0', () => {
  console.log('Listening on port 4000');
});

// Signature 2: options object
// server.listen({ port: 4000, host: '127.0.0.1', backlog: 128 }, () => {
//   console.log('Listening on port 4000');
// });

// Signature 3: Unix domain socket / named pipe
// server.listen('/tmp/my-app.sock', () => {
//   console.log('Listening on Unix socket');
// });
```

The `backlog` option controls the maximum number of pending connections the OS will queue before refusing new ones. The default is OS-specific (typically 511 on Linux).

### `.address()`

Returns the bound address, port, and family after the server is listening.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.end('Hello\n');
});

server.listen(0, () => {
  // Port 0 means "let the OS assign a free port"
  const addr = server.address();
  console.log(`Bound to ${addr.address}:${addr.port} (${addr.family})`);
  // e.g., Bound to ::1:54321 (IPv6)
});
```

Using port `0` is extremely useful for tests — you never collide with another process.

### `.getConnections(callback)`

Returns the number of concurrent connections asynchronously:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  server.getConnections((err, count) => {
    if (err) {
      console.error('Error getting connections:', err.message);
      return;
    }
    console.log(`Active connections: ${count}`);
    socket.write(`You are connection #${count}\n`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

### `.maxConnections`

Set this property to reject connections when the limit is reached. Connections beyond this limit receive a `'drop'` event on the server.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.write('Welcome!\n');
  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.maxConnections = 10;

server.on('drop', (data) => {
  console.warn('Connection dropped — server at capacity');
  // data contains { localAddress, localPort, localFamily,
  //                 remoteAddress, remotePort, remoteFamily }
});

server.listen(4000);
```

### `.close([callback])`

Stops the server from accepting new connections. Existing connections remain open until they close naturally.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.end('Hello\n');
});

server.listen(4000, () => {
  console.log('Server started');

  // Stop accepting new connections after 5 seconds
  setTimeout(() => {
    server.close((err) => {
      if (err) {
        console.error('Error closing server:', err.message);
        return;
      }
      console.log('Server closed — no new connections accepted');
    });
  }, 5000);
});
```

---

## Server Events

The `net.Server` emits several events during its lifecycle:

| Event | Emitted When |
|-------|-------------|
| `'listening'` | The server has been bound and is ready to accept connections |
| `'connection'` | A new connection is established (receives the `net.Socket`) |
| `'close'` | The server has closed (all connections have ended) |
| `'error'` | An error occurs (e.g., `EADDRINUSE`) |
| `'drop'` | A connection is dropped because `maxConnections` was exceeded |

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer();

server.on('listening', () => {
  console.log('Server is listening:', server.address());
});

server.on('connection', (socket) => {
  console.log(`New connection from ${socket.remoteAddress}:${socket.remotePort}`);
  socket.write('Connected.\n');
  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.on('close', () => {
  console.log('Server has fully closed');
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
});

server.listen(4000);
```

---

## Connecting as a Client

The `net.createConnection()` function (alias: `net.connect()`) creates a `net.Socket` and initiates a connection to a remote server.

```javascript
'use strict';

const net = require('node:net');

const client = net.createConnection({ port: 4000, host: '127.0.0.1' }, () => {
  console.log('Connected to server');
  client.write('Hello from the client!\n');
});

client.on('data', (chunk) => {
  console.log('Server says:', chunk.toString());
});

client.on('end', () => {
  console.log('Disconnected from server');
});

client.on('error', (err) => {
  console.error('Connection error:', err.message);
});
```

You can also connect to a Unix domain socket:

```javascript
'use strict';

const net = require('node:net');

const client = net.createConnection({ path: '/tmp/my-app.sock' }, () => {
  console.log('Connected to Unix socket');
  client.write('Hello via IPC\n');
});

client.on('data', (chunk) => {
  console.log('Response:', chunk.toString());
});

client.on('error', (err) => {
  console.error('IPC error:', err.message);
});
```

---

## The `net.Socket` Class

A `net.Socket` is a Duplex Stream. It implements both `stream.Readable` and `stream.Writable`, which means everything you learned about streams in Module 05 applies directly.

### Writing Data

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Write a string (encoded as UTF-8 by default)
  socket.write('Welcome!\n');

  // Write a Buffer
  socket.write(Buffer.from([0x48, 0x65, 0x6c, 0x6c, 0x6f])); // "Hello"

  // Write with an encoding
  socket.write('Goodbye\n', 'utf8');

  // End the connection (optionally with final data)
  socket.end('Connection closed by server.\n');
});

server.listen(4000);
```

`socket.write()` returns `true` if the data was flushed to the kernel buffer, or `false` if it was queued in user-space. When it returns `false`, wait for the `'drain'` event before writing more data — just like any other Writable Stream.

### Socket Properties

| Property | Type | Description |
|----------|------|-------------|
| `socket.remoteAddress` | `string` | IP address of the remote end |
| `socket.remotePort` | `number` | Port number of the remote end |
| `socket.remoteFamily` | `string` | `'IPv4'` or `'IPv6'` |
| `socket.localAddress` | `string` | Local IP address |
| `socket.localPort` | `number` | Local port number |
| `socket.bytesRead` | `number` | Total bytes received on this socket |
| `socket.bytesWritten` | `number` | Total bytes sent on this socket |
| `socket.readyState` | `string` | `'opening'`, `'open'`, `'readOnly'`, `'writeOnly'`, or `'closed'` |
| `socket.pending` | `boolean` | `true` if `socket.connect()` has not yet been called |

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  console.log('Remote:', socket.remoteAddress, socket.remotePort);
  console.log('Local:', socket.localAddress, socket.localPort);
  console.log('Ready state:', socket.readyState);

  socket.on('data', () => {
    console.log('Bytes read so far:', socket.bytesRead);
  });

  socket.on('end', () => {
    console.log('Total bytes read:', socket.bytesRead);
    console.log('Total bytes written:', socket.bytesWritten);
  });

  socket.write('Hello\n');
  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

---

## Socket Events

The `net.Socket` emits a rich set of events:

| Event | Payload | Description |
|-------|---------|-------------|
| `'connect'` | — | Connection established (client-side) |
| `'data'` | `Buffer` | Data received |
| `'end'` | — | The other end sent a FIN (done sending) |
| `'close'` | `hadError: boolean` | Socket fully closed |
| `'error'` | `Error` | An error occurred |
| `'drain'` | — | Write buffer drained; safe to write again |
| `'timeout'` | — | Idle timeout expired (does NOT close the socket) |
| `'lookup'` | `err, address, family, host` | DNS lookup completed (client-side, before connect) |
| `'ready'` | — | Socket is ready to be used (emitted right after `'connect'`) |

A critical detail about `'timeout'`: it does **not** close the socket. It is purely informational. You must decide what to do — typically `socket.end()` or `socket.destroy()`.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Set a 10-second idle timeout
  socket.setTimeout(10_000);

  socket.on('timeout', () => {
    console.log('Socket idle for 10 seconds — closing');
    socket.end('Idle timeout. Goodbye.\n');
  });

  socket.on('data', (chunk) => {
    // Each data event resets the timeout timer
    socket.write(`Echo: ${chunk}`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

---

## Socket Configuration Methods

### `socket.setKeepAlive([enable], [initialDelay])`

Enables or disables TCP keep-alive probes. Keep-alive detects dead connections (e.g., a client whose network cable was unplugged) by sending periodic probes.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Enable keep-alive with 30-second initial delay
  socket.setKeepAlive(true, 30_000);

  socket.on('data', (chunk) => {
    socket.write(`Echo: ${chunk}`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

Without keep-alive, a connection to a dead peer can remain open indefinitely, leaking resources.

### `socket.setNoDelay([noDelay])`

Disables the Nagle algorithm. By default, TCP buffers small writes and sends them together (Nagle's algorithm) to reduce the number of packets. For low-latency protocols, disable it:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Disable Nagle — send data immediately, do not buffer small writes
  socket.setNoDelay(true);

  socket.on('data', (chunk) => {
    // Response goes out immediately, not batched with the next write
    socket.write(`ACK: ${chunk.length} bytes\n`);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

### `socket.setTimeout(timeout, [callback])`

Sets the idle timeout in milliseconds. A timeout of `0` disables the timeout. The optional callback is a one-time listener for the `'timeout'` event.

---

## Utility Functions

The `net` module provides three simple validation functions:

```javascript
'use strict';

const net = require('node:net');

// net.isIP(input) — returns 0, 4, or 6
console.log(net.isIP('127.0.0.1'));         // 4
console.log(net.isIP('::1'));               // 6
console.log(net.isIP('not-an-ip'));         // 0

// net.isIPv4(input) — returns boolean
console.log(net.isIPv4('192.168.1.1'));     // true
console.log(net.isIPv4('::1'));             // false

// net.isIPv6(input) — returns boolean
console.log(net.isIPv6('::1'));             // true
console.log(net.isIPv6('192.168.1.1'));     // false
console.log(net.isIPv6('fe80::1%eth0'));    // true
```

These are useful for validating user input, logging, and routing logic.

---

## Unix Domain Sockets and Named Pipes

TCP uses IP addresses and ports. Unix domain sockets (UDS) use file paths. They bypass the network stack entirely, making them faster for local IPC.

```javascript
'use strict';

const net = require('node:net');
const fs = require('node:fs');

const SOCKET_PATH = '/tmp/my-node-app.sock';

// Clean up any leftover socket file from a previous run
if (fs.existsSync(SOCKET_PATH)) {
  fs.unlinkSync(SOCKET_PATH);
}

const server = net.createServer((socket) => {
  socket.on('data', (chunk) => {
    console.log(`IPC received: "${chunk.toString().trim()}"`);
    socket.write(`ACK: ${chunk}`);
  });
  socket.on('error', (err) => console.error('Socket error:', err.message));
});

server.listen(SOCKET_PATH, () => {
  console.log(`IPC server listening on ${SOCKET_PATH}`);
});

// Clean up the socket file when the server closes
server.on('close', () => {
  if (fs.existsSync(SOCKET_PATH)) fs.unlinkSync(SOCKET_PATH);
});
```

Connect with `net.createConnection({ path: '/tmp/my-node-app.sock' })`. On Windows, use named pipes with the path format `\\\\.\\pipe\\my-app`.

---

## Error Handling

Network errors are not optional edge cases — they are guaranteed to happen. Every `net.Socket` and `net.Server` must have an `'error'` event handler. An unhandled `'error'` event crashes the process.

### Common Error Codes

| Error Code | Meaning | Typical Cause |
|------------|---------|---------------|
| `EADDRINUSE` | Address already in use | Another process is listening on the same port |
| `ECONNREFUSED` | Connection refused | No server listening on the target port |
| `ECONNRESET` | Connection reset by peer | The remote end abruptly closed the connection |
| `ETIMEDOUT` | Connection timed out | The remote end did not respond within the timeout |
| `EPIPE` | Broken pipe | Writing to a socket that has been closed |
| `ENOTFOUND` | DNS lookup failed | The hostname could not be resolved |

### Handling `EADDRINUSE`

```javascript
'use strict';

const net = require('node:net');

const PORT = 4000;

const server = net.createServer((socket) => {
  socket.end('Hello\n');
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use.`);
    console.error('Kill the other process or use a different port.');
    process.exit(1);
  }
  // Re-throw unexpected errors
  throw err;
});

server.listen(PORT, () => {
  console.log(`Listening on port ${PORT}`);
});
```

### Handling Socket Errors

```javascript
'use strict';

const net = require('node:net');

const client = net.createConnection({ port: 9999, host: '127.0.0.1' });

client.on('error', (err) => {
  switch (err.code) {
    case 'ECONNREFUSED':
      console.error('Server is not running on port 9999');
      break;
    case 'ECONNRESET':
      console.error('Server abruptly closed the connection');
      break;
    case 'ETIMEDOUT':
      console.error('Connection timed out — server unreachable');
      break;
    default:
      console.error(`Unexpected error: ${err.code} — ${err.message}`);
  }
});
```

### The `socket.destroy()` vs `socket.end()` Distinction

- `socket.end([data])` — Sends a FIN packet. The socket enters the half-closed state. The remote end can still send data. This is a graceful shutdown.
- `socket.destroy([error])` — Immediately destroys the socket. No more I/O. If an error is passed, it is emitted as an `'error'` event followed by `'close'`. Use this for unrecoverable errors.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.on('data', (chunk) => {
    const message = chunk.toString().trim();

    if (message === 'quit') {
      // Graceful: send final data, then FIN
      socket.end('Goodbye.\n');
    } else if (message === 'crash') {
      // Forceful: destroy immediately
      socket.destroy(new Error('Client requested crash'));
    } else {
      socket.write(`Echo: ${message}\n`);
    }
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

---

## Key Takeaways

- The `node:net` module is the foundation of all TCP and IPC networking in Node.js — `http`, `https`, and `tls` are all built on top of it.
- A `net.Socket` is a Duplex Stream, so all stream patterns (piping, backpressure, `'drain'` events) apply directly to network I/O.
- The `'timeout'` event on a socket does **not** close the connection — it is a notification that requires you to decide whether to `socket.end()` or `socket.destroy()`.
- Every `net.Socket` and `net.Server` must have an `'error'` event handler; an unhandled socket error crashes the entire Node.js process.
- Unix domain sockets bypass the network stack entirely, making them the fastest option for local inter-process communication — use them whenever server and client live on the same machine.

---

## Next

Continue to [Lesson 07 — Building TCP Servers & Clients](lesson-07-tcp-servers-clients.md) to put these primitives into practice, building complete servers and clients with message framing, connection tracking, and graceful shutdown.
