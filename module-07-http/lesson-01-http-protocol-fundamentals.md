# Module 07 / Lesson 01 — HTTP Protocol Fundamentals

> Every web request you have ever made — every page load, every API call, every image download — traveled over HTTP. Before you can build a server, you need to understand the protocol it speaks.

## Learning Objectives

- Describe the request-response model and how it maps to TCP connections
- Compare HTTP/1.0, HTTP/1.1, and HTTP/2 connection behavior and performance characteristics
- Trace the full lifecycle of an HTTP connection from DNS lookup to socket close
- Explain persistent connections, pipelining, and multiplexing
- Identify where Node.js fits into the HTTP stack

---

## The Request-Response Model

HTTP is a **text-based, stateless, request-response protocol** that runs on top of TCP. The client sends a request, the server sends a response, and that is one complete exchange. There is no concept of "sessions" or "memory" built into the protocol itself — every request is independent.

```
Client                          Server
  |                               |
  |--- TCP SYN ------------------>|
  |<-- TCP SYN-ACK ---------------|
  |--- TCP ACK ------------------>|
  |                               |
  |--- HTTP Request ------------->|
  |<-- HTTP Response -------------|
  |                               |
  |--- TCP FIN ------------------>|  (HTTP/1.0)
  |<-- TCP FIN-ACK ---------------|
```

This simplicity is both the strength and the weakness of HTTP. It makes the protocol easy to implement, debug, and reason about. The downside is that state management (authentication, shopping carts, user preferences) must be layered on top through cookies, tokens, or server-side sessions.

### Why TCP?

HTTP needs **reliable, ordered delivery**. When a browser requests an HTML page, every byte must arrive, in order, without corruption. TCP provides exactly that guarantee. UDP does not — which is why HTTP was built on TCP (though HTTP/3 uses QUIC over UDP, that is a different story).

The key implication: every HTTP connection begins with a TCP three-way handshake. That handshake costs one round trip of latency before a single byte of HTTP data can be sent.

---

## HTTP/1.0 — One Request Per Connection

HTTP/1.0 (RFC 1945, 1996) is the simplest version. Each request opens a new TCP connection, sends one request, receives one response, and closes the connection.

```
'use strict';

const net = require('node:net');

// Simulating HTTP/1.0 behavior: one request, one connection
const client = net.createConnection({ host: 'localhost', port: 3000 }, () => {
  // Send a raw HTTP/1.0 request
  client.write(
    'GET / HTTP/1.0\r\n' +
    'Host: localhost\r\n' +
    '\r\n'
  );
});

client.on('data', (chunk) => {
  console.log('Response received:');
  console.log(chunk.toString());
});

// In HTTP/1.0, the server closes the connection after the response
client.on('end', () => {
  console.log('Connection closed by server (HTTP/1.0 behavior)');
});
```

### The Cost of HTTP/1.0

Loading a typical web page in 1996 might require 5-10 resources (HTML, a few images, a stylesheet). With HTTP/1.0, that means 5-10 separate TCP connections, each paying the handshake cost. On a connection with 100ms round-trip time, the handshakes alone add 500-1000ms of latency before any content starts loading.

This was tolerable on early web pages with minimal assets. It became unacceptable as pages grew to include dozens or hundreds of resources.

---

## HTTP/1.1 — Persistent Connections and Pipelining

HTTP/1.1 (RFC 2616, 1999; updated by RFC 7230-7235, 2014) introduced three critical improvements:

### 1. Persistent Connections (Keep-Alive)

HTTP/1.1 connections are **persistent by default**. After the server sends a response, the TCP connection stays open for additional requests. No more handshake per request.

```
Client                          Server
  |                               |
  |--- TCP Handshake ------------>|  (once)
  |                               |
  |--- GET /index.html ---------->|
  |<-- 200 OK (HTML) -------------|
  |                               |
  |--- GET /style.css ----------->|  (same TCP connection)
  |<-- 200 OK (CSS) --------------|
  |                               |
  |--- GET /logo.png ------------>|  (same TCP connection)
  |<-- 200 OK (PNG) --------------|
  |                               |
  |--- Connection: close -------->|  (explicit close)
  |<-- FIN ---------------------->|
```

To close a persistent connection, the client or server sends a `Connection: close` header. In HTTP/1.0, you had to explicitly request keep-alive with `Connection: keep-alive`.

### 2. The Host Header (Required)

HTTP/1.1 made the `Host` header mandatory. This single change enabled **virtual hosting** — multiple websites sharing the same IP address and port. The server inspects the `Host` header to determine which site the request is for.

```
'use strict';

const net = require('node:net');

// Two requests to different virtual hosts on the same connection
const client = net.createConnection({ host: '93.184.216.34', port: 80 }, () => {
  // First request — site A
  client.write(
    'GET / HTTP/1.1\r\n' +
    'Host: example.com\r\n' +    // Server routes based on this
    '\r\n'
  );
});
```

Without the `Host` header, the server has no way to know which of its hosted sites the client wants. This is why HTTP/1.1 servers must reject requests that lack it with a `400 Bad Request`.

### 3. Chunked Transfer Encoding

HTTP/1.1 introduced `Transfer-Encoding: chunked`, allowing servers to start sending a response before knowing its total size. Each chunk is prefixed with its length in hexadecimal, followed by `\r\n`, the chunk data, and another `\r\n`. A zero-length chunk signals the end.

```
HTTP/1.1 200 OK
Transfer-Encoding: chunked

1a\r\n
This is the first chunk.\r\n
1c\r\n
And this is the second one.\r\n
0\r\n
\r\n
```

This is essential for streaming responses — server-sent events, large generated content, or any case where the server does not want to buffer the entire response in memory.

### Pipelining (Theoretical)

HTTP/1.1 also defined **pipelining** — sending multiple requests without waiting for each response. In practice, pipelining never worked reliably. Servers must return responses in the exact order requests arrived (head-of-line blocking), and many proxies and servers implemented it incorrectly. Every major browser disabled it.

---

## HTTP/2 — Binary Framing and Multiplexing

HTTP/2 (RFC 7540, 2015) solved the head-of-line blocking problem at the application layer by fundamentally changing how messages are transmitted.

### Key Differences from HTTP/1.1

| Feature | HTTP/1.1 | HTTP/2 |
|---------|----------|--------|
| Format | Text-based | Binary framing |
| Multiplexing | One request at a time per connection | Many concurrent streams on one connection |
| Header compression | None (repeated headers every request) | HPACK compression |
| Server push | Not possible | Server can push resources proactively |
| Connection count | 6-8 connections per origin (browser limit) | Single connection per origin |

### Streams and Frames

HTTP/2 divides communication into **frames** (the smallest unit) and **streams** (a sequence of frames belonging to one request-response pair). Multiple streams can interleave their frames on the same TCP connection.

```
Single TCP Connection
  |
  |-- Stream 1: GET /index.html
  |     Frame: HEADERS (request)
  |     Frame: HEADERS (response)
  |     Frame: DATA (response body, part 1)
  |
  |-- Stream 2: GET /style.css    (concurrent!)
  |     Frame: HEADERS (request)
  |     Frame: HEADERS (response)
  |     Frame: DATA (response body)
  |
  |-- Stream 1 continued:
  |     Frame: DATA (response body, part 2)
  |     Frame: DATA (response body, part 3, END_STREAM)
```

### HTTP/2 in Node.js

Node.js provides HTTP/2 support through the `node:http2` module, separate from `node:http`:

```
'use strict';

const http2 = require('node:http2');
const fs = require('node:fs');

// HTTP/2 requires TLS in browsers (h2), though Node.js supports cleartext (h2c)
const server = http2.createSecureServer({
  key: fs.readFileSync('server-key.pem'),
  cert: fs.readFileSync('server-cert.pem'),
});

server.on('stream', (stream, headers) => {
  const path = headers[':path'];
  const method = headers[':method'];

  console.log(`${method} ${path}`);

  // HTTP/2 uses pseudo-headers prefixed with ':'
  stream.respond({
    ':status': 200,
    'content-type': 'text/plain',
  });
  stream.end('Hello from HTTP/2');
});

server.listen(8443, () => {
  console.log('HTTP/2 server listening on port 8443');
});
```

Notice the differences: HTTP/2 uses **pseudo-headers** (`:method`, `:path`, `:status`) instead of the request line. The `stream` event replaces the `request` event, and each stream is a `Duplex` stream.

---

## Connection Lifecycle in Detail

Here is the full lifecycle of an HTTP/1.1 request, step by step:

### 1. DNS Resolution

The client resolves the hostname to an IP address. Node.js uses `dns.lookup()` by default, which calls the OS resolver (often checking `/etc/hosts` first, then querying a DNS server).

### 2. TCP Handshake

The client opens a TCP connection to the server's IP and port. This is the three-way handshake: SYN, SYN-ACK, ACK.

### 3. TLS Handshake (if HTTPS)

For HTTPS, a TLS handshake follows the TCP handshake. This negotiates the cipher suite, exchanges certificates, and establishes a shared encryption key. TLS 1.3 does this in one round trip; TLS 1.2 takes two.

### 4. Request Sent

The client sends the HTTP request: the request line, headers, empty line, and optionally a body.

### 5. Server Processing

The server receives the request, runs it through its handler (routing, middleware, business logic), and prepares the response.

### 6. Response Sent

The server sends the HTTP response: the status line, headers, empty line, and body.

### 7. Connection Decision

With HTTP/1.1, the connection stays open by default. The client can send another request (go to step 4) or close the connection. The server may also close it after a keep-alive timeout.

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  console.log(`  Connection: ${req.headers.connection || 'keep-alive (default)'}`);

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

// Configure keep-alive behavior
server.keepAliveTimeout = 5000;   // Close idle connections after 5 seconds
server.headersTimeout = 10000;    // Reject requests that take >10s to send headers

server.listen(3000, () => {
  console.log('Server listening on port 3000');
  console.log(`Keep-alive timeout: ${server.keepAliveTimeout}ms`);
  console.log(`Headers timeout: ${server.headersTimeout}ms`);
});
```

### Observing the Lifecycle

You can watch the connection lifecycle by listening to socket-level events:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end(`Request #${req.socket._requestCount || 1} on this connection\n`);

  // Track requests per socket for keep-alive observation
  req.socket._requestCount = (req.socket._requestCount || 0) + 1;
});

server.on('connection', (socket) => {
  const remote = `${socket.remoteAddress}:${socket.remotePort}`;
  console.log(`[TCP] New connection from ${remote}`);

  socket.on('close', () => {
    console.log(`[TCP] Connection closed: ${remote} (served ${socket._requestCount || 0} requests)`);
  });
});

server.listen(3000, () => {
  console.log('Lifecycle observer running on port 3000');
});
```

---

## HTTP in the Node.js Stack

Understanding where HTTP sits in the Node.js architecture helps you reason about performance and correctness:

```
┌─────────────────────────────────────┐
│          Your Application           │  JavaScript
│   (routing, middleware, handlers)   │
├─────────────────────────────────────┤
│        node:http / node:http2       │  JavaScript + C++
│   (request/response abstraction)    │
├─────────────────────────────────────┤
│             llhttp                  │  C (HTTP parser)
│   (parses raw HTTP from bytes)      │
├─────────────────────────────────────┤
│          node:net / node:tls        │  JavaScript + C++
│      (TCP sockets, TLS layer)       │
├─────────────────────────────────────┤
│              libuv                  │  C
│   (event loop, async I/O, DNS)      │
├─────────────────────────────────────┤
│         Operating System            │
│   (TCP/IP stack, file descriptors)  │
└─────────────────────────────────────┘
```

The **llhttp** parser (which replaced the older http-parser in Node.js 12) is a high-performance C parser that converts raw bytes from a TCP socket into structured JavaScript objects (`IncomingMessage`). It handles:

- Request line parsing (method, URL, version)
- Header parsing (name-value pairs)
- Body framing (Content-Length or chunked)
- Keep-alive connection management
- Malformed request rejection

You do not interact with llhttp directly. The `node:http` module wraps it and gives you `req` and `res` objects. But knowing it exists helps you understand why Node.js can handle HTTP parsing so efficiently — and why building your own parser (as we do in Exercise 01) is primarily an educational exercise.

---

## Performance Implications

The protocol version you use has real performance consequences:

### Connection Overhead

| Protocol | Connections per page load | Handshake overhead |
|----------|--------------------------|-------------------|
| HTTP/1.0 | One per resource (50-100+) | Massive |
| HTTP/1.1 | 6-8 persistent connections | Moderate (6-8 handshakes) |
| HTTP/2 | 1 connection per origin | Minimal (1 handshake) |

### Head-of-Line Blocking

HTTP/1.1's persistent connections still suffer from head-of-line blocking: if the server takes 2 seconds to respond to the first request on a connection, the second request queued behind it waits the full 2 seconds — even if its response is ready instantly.

HTTP/2 eliminates this at the application layer (streams are independent), but TCP-level head-of-line blocking persists: if a single TCP packet is lost, all streams on that connection stall until the packet is retransmitted. This is the motivation for HTTP/3 and QUIC.

### What This Means for Node.js Servers

For most Node.js services:

- **Internal APIs** (microservice-to-microservice): HTTP/1.1 with keep-alive is fine. Latency is low, connection count is manageable.
- **Public-facing servers**: HTTP/2 provides significant benefits for asset-heavy pages. Use `node:http2` or put Node.js behind a reverse proxy (nginx, Cloudflare) that handles HTTP/2 termination.
- **Learning**: Master HTTP/1.1 first. Every concept (methods, headers, status codes, body parsing) transfers directly to HTTP/2. The framing changes; the semantics do not.

---

## Key Takeaways

- HTTP is a stateless, text-based, request-response protocol built on TCP — every exchange is one request followed by one response
- HTTP/1.1's persistent connections eliminated the per-request TCP handshake cost, and the mandatory `Host` header enabled virtual hosting
- HTTP/2 introduced binary framing and multiplexing, allowing concurrent streams on a single TCP connection and eliminating application-level head-of-line blocking
- Node.js uses llhttp (a C parser) under the hood to parse HTTP efficiently — the `node:http` module wraps this into `IncomingMessage` and `ServerResponse` objects
- Understanding the connection lifecycle (DNS, TCP handshake, optional TLS, request, response, keep-alive) is essential for debugging latency and connection issues

## Next

In [Lesson 02 — Request Anatomy](lesson-02-request-anatomy.md), we dissect the exact structure of an HTTP request — the request line, headers, empty line, and body — and parse one from raw bytes.
