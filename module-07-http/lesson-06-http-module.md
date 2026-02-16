# Module 07 / Lesson 06 — The http Module

> The `node:http` module is what made Node.js famous. It provides a full HTTP/1.1 server and client in roughly 4,000 lines of JavaScript built on top of `node:net`. You do not need Express, Fastify, or any framework to handle HTTP — the standard library gives you everything. This lesson takes you through every class, method, and event in the module so you understand exactly what happens between a request arriving and a response leaving.

## Learning Objectives

- Create an HTTP server with `http.createServer()` and handle the full `'request'` event lifecycle
- Work with `http.IncomingMessage` as a Readable Stream to consume request bodies
- Construct responses with `http.ServerResponse`, understanding when headers are sent and when they are not
- Make outbound HTTP requests with `http.request()` and `http.get()`, configuring the `http.Agent` for connection pooling
- Handle edge cases: `'clientError'`, `'checkContinue'`, `'upgrade'`, chunked encoding, and `res.headersSent`

---

## `http.createServer()`

The entry point for every HTTP server in Node.js.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello, World!\n');
});

server.listen(3000, () => {
  console.log('Server running at http://127.0.0.1:3000/');
});
```

The callback is shorthand for listening on the `'request'` event. These are equivalent:

```javascript
'use strict';

const http = require('node:http');

// Approach 1: Callback
const server1 = http.createServer((req, res) => {
  res.end('Callback approach\n');
});

// Approach 2: Event listener
const server2 = http.createServer();
server2.on('request', (req, res) => {
  res.end('Event listener approach\n');
});
```

### Server Options

`http.createServer()` accepts an options object as the first argument:

| Option | Default | Purpose |
|--------|---------|---------|
| `maxHeaderSize` | `16384` | Max header size in bytes before rejecting the request |
| `requestTimeout` | `300000` | Timeout (ms) for receiving the entire request (0 = no timeout) |
| `headersTimeout` | `60000` | Timeout (ms) for receiving request headers |
| `keepAliveTimeout` | `5000` | How long (ms) to keep an idle connection open for reuse |
| `joinDuplicateHeaders` | `false` | Join duplicate headers with `, ` instead of keeping only the last |

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer({
  requestTimeout: 30_000,
  headersTimeout: 20_000,
  keepAliveTimeout: 5_000,
}, (req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Configured server\n');
});

server.listen(3000);
```

---

## `http.Server` Events

The `http.Server` class extends `net.Server` and adds HTTP-specific events.

| Event | Arguments | When |
|-------|-----------|------|
| `'request'` | `(req, res)` | A complete HTTP request has been received |
| `'connection'` | `(socket)` | A new TCP connection is established (before any HTTP parsing) |
| `'close'` | — | The server has stopped accepting connections and all existing connections have closed |
| `'upgrade'` | `(req, socket, head)` | The client requests an HTTP upgrade (e.g., WebSocket) |
| `'checkContinue'` | `(req, res)` | The client sent `Expect: 100-continue` |
| `'clientError'` | `(err, socket)` | A client error occurred before a request could be parsed |
| `'dropRequest'` | `(req, socket)` | A request is dropped when the server is too busy |

### The `'clientError'` Event

When a client sends malformed data (bad HTTP, invalid headers, connection reset during parsing), Node.js emits `'clientError'` instead of `'request'`. Without a handler, Node.js destroys the socket silently. With a handler, you can send a proper error response.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK\n');
});

server.on('clientError', (err, socket) => {
  console.error('Client error:', err.code, err.message);

  // Only send a response if the socket is still writable
  if (socket.writable) {
    socket.end('HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nBad Request\n');
  }
});

server.listen(3000, () => {
  console.log('Server with clientError handling on port 3000');
});
```

### The `'checkContinue'` Event

When a client wants to send a large body, it may first send `Expect: 100-continue` to ask permission. If you handle this event, you must respond with either `res.writeContinue()` or a rejection status.

```javascript
'use strict';

const http = require('node:http');

const MAX_BODY_SIZE = 10 * 1024 * 1024; // 10 MB

const server = http.createServer((req, res) => {
  // Regular requests land here
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ received: body.length }));
  });
});

server.on('checkContinue', (req, res) => {
  const contentLength = parseInt(req.headers['content-length'] || '0', 10);

  if (contentLength > MAX_BODY_SIZE) {
    // Reject — body is too large
    res.writeHead(413, { 'Content-Type': 'text/plain' });
    res.end('Payload too large\n');
    return;
  }

  // Accept — tell the client to send the body
  res.writeContinue();

  // Now handle the request normally
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ received: body.length }));
  });
});

server.listen(3000);
```

### The `'upgrade'` Event

The `'upgrade'` event fires when a client requests an HTTP protocol upgrade (e.g., WebSocket). It receives `(req, socket, head)` where `socket` is the raw `net.Socket` and `head` is the first packet of the new protocol. After sending the 101 response, you communicate directly over the raw TCP socket.

---

## `http.IncomingMessage`

When the `'request'` event fires, the first argument is an `http.IncomingMessage`. It is a **Readable Stream** containing the request body.

### Key Properties

| Property | Type | Description |
|----------|------|-------------|
| `req.method` | `string` | HTTP method: `'GET'`, `'POST'`, `'PUT'`, etc. |
| `req.url` | `string` | The request path including query string (e.g., `'/users?page=2'`) |
| `req.headers` | `object` | Lowercased header names mapped to values |
| `req.rawHeaders` | `string[]` | Alternating `[name, value, name, value, ...]` with original casing |
| `req.httpVersion` | `string` | `'1.0'` or `'1.1'` |
| `req.socket` | `net.Socket` | The underlying TCP socket |
| `req.complete` | `boolean` | `true` after all data has been received |
| `req.aborted` | `boolean` | `true` if the request was aborted by the client |

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  console.log(`${req.method} ${req.url} HTTP/${req.httpVersion}`);
  console.log('Headers:', req.headers);
  console.log('Raw headers:', req.rawHeaders);
  console.log('Remote:', req.socket.remoteAddress, req.socket.remotePort);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    method: req.method,
    url: req.url,
    headers: req.headers,
    httpVersion: req.httpVersion,
  }));
});

server.listen(3000);
```

### Reading the Request Body

Since `req` is a Readable Stream, you collect the body by listening for `'data'` and `'end'` events:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    return res.end('Only POST is accepted\n');
  }

  const chunks = [];
  let totalBytes = 0;
  const MAX_BODY = 1024 * 1024; // 1 MB limit

  req.on('data', (chunk) => {
    totalBytes += chunk.length;

    if (totalBytes > MAX_BODY) {
      res.writeHead(413, { 'Content-Type': 'text/plain' });
      res.end('Body too large\n');
      req.destroy(); // Stop reading
      return;
    }

    chunks.push(chunk);
  });

  req.on('end', () => {
    if (res.writableEnded) return; // Already responded with 413

    const body = Buffer.concat(chunks).toString();

    try {
      const data = JSON.parse(body);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ received: data }));
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Invalid JSON\n');
    }
  });

  req.on('error', (err) => {
    console.error('Request error:', err.message);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('Internal error\n');
    }
  });
});

server.listen(3000, () => {
  console.log('POST body reader on port 3000');
});
```

Node.js lowercases all header names in `req.headers` for easy access. If you need the original casing (rare), use `req.rawHeaders`, which is an alternating array of `[name, value, name, value, ...]` preserving the exact casing the client sent.

---

## `http.ServerResponse`

The second argument to the request handler is an `http.ServerResponse`. It is a **Writable Stream** that you use to send the HTTP response.

### Setting Headers

There are two approaches to setting headers, and they have different semantics:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Approach 1: res.setHeader() — sets a header that will be sent later
  // Headers are buffered until writeHead() or the first write()/end()
  res.setHeader('X-Request-Id', '12345');
  res.setHeader('Content-Type', 'application/json');

  // You can read them back
  console.log(res.getHeader('content-type')); // 'application/json'

  // You can remove them
  // res.removeHeader('X-Request-Id');

  // You can get all set header names
  console.log(res.getHeaderNames()); // ['x-request-id', 'content-type']

  // Approach 2: res.writeHead() — sets status code AND headers, and flushes them
  // This overwrites any header set with setHeader() that has the same name
  res.writeHead(200, {
    'Content-Type': 'application/json',     // Overwrites the setHeader above
    'Cache-Control': 'no-store',
  });

  res.end(JSON.stringify({ message: 'Hello' }));
});

server.listen(3000);
```

### The `res.headersSent` Property

Once headers are sent (by `writeHead()`, `write()`, or `end()`), they cannot be modified. Attempting to set headers after they are sent throws an error.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  console.log('Before write — headersSent:', res.headersSent); // false

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  console.log('After writeHead — headersSent:', res.headersSent); // true

  // This would throw: Cannot set headers after they are sent
  // res.setHeader('X-Foo', 'bar');

  // Always check before setting headers in error handlers
  if (!res.headersSent) {
    res.setHeader('X-Foo', 'bar');
  }

  res.end('Done\n');
});

server.listen(3000);
```

### `res.write()` and `res.end()`

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });

  // write() sends a chunk of the response body
  // Multiple calls to write() create chunked transfer encoding
  res.write('Line 1\n');
  res.write('Line 2\n');
  res.write('Line 3\n');

  // end() sends the final chunk (optional) and signals the end of the response
  res.end('Final line\n');

  // After end(), the response is finished
  // res.write('This would throw');
});

server.listen(3000);
```

Two additional properties help track response state: `res.writableEnded` becomes `true` immediately after `res.end()` is called, while `res.writableFinished` becomes `true` only after all data has been flushed to the underlying system. Listen for the `'finish'` event to know when the response is fully sent.

---

## Chunked Transfer Encoding

When you call `res.write()` without setting a `Content-Length` header, Node.js automatically uses `Transfer-Encoding: chunked`. Each `write()` call sends a chunk with its size prefix.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/plain',
    // No Content-Length — Node.js will use chunked encoding
  });

  // Each write() sends a separate chunk
  res.write('Chunk 1: Starting...\n');

  setTimeout(() => {
    res.write('Chunk 2: Processing...\n');
  }, 500);

  setTimeout(() => {
    res.write('Chunk 3: Almost done...\n');
  }, 1000);

  setTimeout(() => {
    res.end('Chunk 4: Complete!\n');
  }, 1500);
});

server.listen(3000, () => {
  console.log('Chunked server on port 3000');
  console.log('Test with: curl -N http://127.0.0.1:3000');
});
```

The raw HTTP output looks like:

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked

14\r\n
Chunk 1: Starting...\n
\r\n
18\r\n
Chunk 2: Processing...\n
\r\n
...
0\r\n
\r\n
```

If you set `Content-Length`, Node.js sends the response as a single block (no chunked encoding). Use `Content-Length` when you know the total size; use chunked when streaming.

---

## Making Outbound HTTP Requests

### `http.request()`

```javascript
'use strict';

const http = require('node:http');

const options = {
  hostname: '127.0.0.1',
  port: 3000,
  path: '/api/data',
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
  },
};

const req = http.request(options, (res) => {
  console.log(`Status: ${res.statusCode}`);
  console.log('Headers:', res.headers);

  const chunks = [];
  res.on('data', (chunk) => chunks.push(chunk));
  res.on('end', () => {
    const body = Buffer.concat(chunks).toString();
    console.log('Body:', body);
  });
});

req.on('error', (err) => {
  console.error('Request error:', err.message);
});

// Send the request body
const body = JSON.stringify({ name: 'Alice', age: 30 });
req.write(body);
req.end();
```

### `http.get()`

A shorthand for `http.request()` with `method: 'GET'` that automatically calls `req.end()`:

```javascript
'use strict';

const http = require('node:http');

http.get('http://127.0.0.1:3000/health', (res) => {
  let body = '';
  res.on('data', (chunk) => { body += chunk; });
  res.on('end', () => {
    console.log(`Status: ${res.statusCode}`);
    console.log(`Body: ${body}`);
  });
}).on('error', (err) => {
  console.error('GET error:', err.message);
});
```

### Request Timeout

Pass `timeout` in the options to set a socket timeout. When it fires, the `'timeout'` event triggers on the request — but it does **not** abort the request automatically. You must call `req.destroy()`:

```javascript
'use strict';

const http = require('node:http');

const req = http.request({
  hostname: '127.0.0.1',
  port: 3000,
  path: '/slow-endpoint',
  timeout: 5000,
}, (res) => {
  res.resume(); // Drain
});

req.on('timeout', () => req.destroy(new Error('Timeout')));
req.on('error', (err) => console.error('Request error:', err.message));
req.end();
```

---

## The `http.Agent`

The `http.Agent` manages connection pooling for outbound HTTP requests. Instead of opening a new TCP connection for every request, the agent reuses existing connections.

### Default Agent Configuration

```javascript
'use strict';

const http = require('node:http');

// The global agent is used by default for all http.request() calls
console.log('Global agent settings:');
console.log('  keepAlive:', http.globalAgent.keepAlive);         // false (Node < 19), true (Node >= 19)
console.log('  maxSockets:', http.globalAgent.maxSockets);       // Infinity
console.log('  maxTotalSockets:', http.globalAgent.maxTotalSockets); // Infinity
console.log('  maxFreeSockets:', http.globalAgent.maxFreeSockets);   // 256
```

### Custom Agent

```javascript
'use strict';

const http = require('node:http');

// Create a custom agent with connection pooling
const agent = new http.Agent({
  keepAlive: true,          // Reuse connections
  keepAliveMsecs: 1000,     // How often to send TCP keep-alive probes
  maxSockets: 10,           // Max concurrent sockets per host:port
  maxTotalSockets: 50,      // Max concurrent sockets across all hosts
  maxFreeSockets: 5,        // Max idle sockets to keep in the pool
  timeout: 30_000,          // Socket timeout in ms
  scheduling: 'lifo',       // 'lifo' reuses recent sockets (better for keep-alive)
});

function makeRequest(path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: 3000,
      path,
      agent, // Use our custom agent instead of the global one
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });

    req.on('error', reject);
    req.end();
  });
}

// Monitor agent status
setInterval(() => {
  const status = {
    freeSockets: Object.keys(agent.freeSockets).length,
    sockets: Object.keys(agent.sockets).length,
    requests: Object.keys(agent.requests).length,
  };
  console.log('Agent status:', status);
}, 5000);
```

To disable connection pooling entirely, pass `agent: false` in the request options. Each request will create and close its own TCP connection.

---

## Request/Response Lifecycle

Understanding the exact order of events is essential for debugging:

```
Client sends request
    ↓
Server 'connection' event (TCP socket established)
    ↓
HTTP parser reads headers
    ↓
Server 'request' event (req, res available)
    ↓
req 'data' events (body chunks arrive)
    ↓
req 'end' event (body fully received)
    ↓
Handler calls res.writeHead() → headers sent to client
    ↓
Handler calls res.write() → body chunks sent
    ↓
Handler calls res.end() → final chunk + signal end
    ↓
res 'finish' event (response fully flushed to OS)
    ↓
res 'close' event (underlying connection closed or reused)
```

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const start = Date.now();
  const elapsed = () => `+${Date.now() - start}ms`;

  console.log(`${elapsed()} request event: ${req.method} ${req.url}`);

  req.on('data', (chunk) => {
    console.log(`${elapsed()} req data: ${chunk.length} bytes`);
  });

  req.on('end', () => {
    console.log(`${elapsed()} req end`);

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    console.log(`${elapsed()} writeHead called, headersSent=${res.headersSent}`);

    res.end('Done\n');
    console.log(`${elapsed()} end called`);
  });

  res.on('finish', () => {
    console.log(`${elapsed()} res finish (flushed to OS)`);
  });

  res.on('close', () => {
    console.log(`${elapsed()} res close`);
  });
});

server.on('connection', (socket) => {
  console.log('TCP connection established');
});

server.listen(3000);
```

---

## Error Handling Patterns

### Comprehensive Server Error Handling

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  try {
    // Synchronous errors are caught here
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (url.pathname === '/error') {
      throw new Error('Intentional error');
    }

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Path: ${url.pathname}\n`);
  } catch (err) {
    console.error('Handler error:', err.message);
    if (!res.headersSent) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
    }
    res.end('Internal Server Error\n');
  }
});

// Handle errors that occur outside the request handler
server.on('clientError', (err, socket) => {
  if (err.code === 'ECONNRESET') {
    // Client disconnected — nothing to respond to
    return;
  }

  console.error('Client error:', err.code, err.message);
  if (socket.writable) {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  }
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error('Port 3000 is already in use');
    process.exit(1);
  }
  console.error('Server error:', err.message);
});

// Handle the underlying socket errors
server.on('connection', (socket) => {
  socket.on('error', (err) => {
    console.error('Socket error:', err.code);
  });
});

server.listen(3000);
```

---

## Key Takeaways

- `http.createServer()` creates an `http.Server` (which extends `net.Server`) and emits a `'request'` event for every parsed HTTP request, providing `IncomingMessage` (Readable Stream) and `ServerResponse` (Writable Stream).
- Headers can be set with `res.setHeader()` (buffered, modifiable) or `res.writeHead()` (immediate, flushes headers) — once `res.headersSent` is `true`, no header modifications are possible.
- The `'clientError'` event catches malformed requests before they reach your handler — without it, bad clients silently disconnect; with it, you can send proper 400 responses and log the issue.
- The `http.Agent` manages TCP connection pooling for outbound requests — configure `keepAlive`, `maxSockets`, and `maxFreeSockets` to control resource usage and throughput.
- Chunked transfer encoding is automatic when you call `res.write()` without a `Content-Length` header — Node.js handles the chunk framing, letting you stream responses incrementally.

---

## Next

Continue to [Lesson 07 — Routing & URL Parsing](lesson-07-routing-url-parsing.md) to learn how to parse URLs, extract query parameters, and build a zero-dependency router from scratch.
