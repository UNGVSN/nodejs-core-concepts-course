# Module 06 — Networking

> Before there is HTTP, there is TCP. Before there is TCP, there are packets, ports, and sockets. This module strips away the comfortable abstractions and puts you face-to-face with raw network programming. By the time you build your first TCP server with `node:net`, you will understand exactly what `http.createServer` does under the hood — because you will have built the foundation it sits on.

---

## Learning Objectives

- Describe the OSI model and TCP/IP stack and locate where Node.js operates within them
- Explain IP addressing (IPv4, IPv6), subnets, and MAC addresses at the level needed for server configuration
- Trace a TCP connection through the three-way handshake, data transfer, and four-way teardown
- Build UDP clients and servers with `node:dgram` and understand when UDP is the right choice
- Resolve domain names programmatically with `node:dns` and explain the difference between `lookup` and `resolve`
- Create multi-client TCP servers and clients with `node:net`, handling connection lifecycle, framing, and cleanup
- Debug network issues using Wireshark, `tcpdump`, and Node.js built-in diagnostics

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| L01 | [Network Fundamentals](lesson-01-network-fundamentals.md) | OSI model, TCP/IP stack, packets, ports, sockets — the foundation everything else builds on |
| L02 | [IP Addressing](lesson-02-ip-addressing.md) | IPv4, IPv6, subnets, MAC addresses, ARP, `node:net` address utilities |
| L03 | [TCP Protocol Deep Dive](lesson-03-tcp-protocol.md) | Three-way handshake, flow control, congestion control, segments, sequence numbers |
| L04 | [UDP Protocol & Datagrams](lesson-04-udp-datagrams.md) | `node:dgram`, connectionless communication, use cases (DNS, gaming, video streaming) |
| L05 | [DNS Resolution](lesson-05-dns-resolution.md) | How DNS works end-to-end, `node:dns`, `dns.resolve` vs `dns.lookup`, caching behavior |
| L06 | [The net Module](lesson-06-net-module.md) | `net.createServer`, `net.createConnection`, socket events, encoding, `allowHalfOpen` |
| L07 | [Building TCP Servers & Clients](lesson-07-tcp-servers-clients.md) | Multi-client TCP server, message framing protocols, connection pooling, graceful shutdown |
| L08 | [Network Debugging](lesson-08-network-debugging.md) | Using Wireshark, `tcpdump`, Node.js `--inspect`, diagnosing latency and connection issues |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [TCP Echo Server](exercise-01-tcp-echo-server.md) | Build an echo server handling multiple concurrent clients with proper cleanup on disconnect |
| E02 | [TCP Chat Room](exercise-02-tcp-chat-room.md) | Multi-room chat: join, leave, broadcast, private messages — all on raw TCP sockets |
| E03 | [UDP Ping-Pong](exercise-03-udp-ping-pong.md) | UDP client and server measuring round-trip latency with high-resolution timestamps |
| E04 | [DNS Resolver](exercise-04-dns-resolver.md) | Build a DNS resolver that queries a DNS server and parses the wire-format response |
| E05 | [TCP File Transfer](exercise-05-tcp-file-transfer.md) | Send files over TCP with a custom framing protocol — length-prefixed messages, checksums |

---

## Progressive Project — Step 06: TCP Server Foundation

In this step you rip out `http.createServer` and replace it with a raw TCP server using `net.createServer`. Your framework now speaks TCP, and you manually parse HTTP request bytes from the socket. This is where you truly understand what HTTP looks like on the wire.

**What you will build:**

- A raw TCP server using `net.createServer` that listens on a configurable port
- An HTTP request parser that extracts the request line (method, path, HTTP version) from raw bytes
- Header parsing from the socket data — split on `\r\n`, extract key-value pairs
- Body extraction based on `Content-Length` or chunked transfer encoding boundaries
- Connection management: track active sockets, implement timeout, handle abrupt disconnects
- Integrate with the existing middleware chain and router from Steps 02-05

**Key code pattern:**

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  let buffer = Buffer.alloc(0);

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    // Check if we have received the full headers (terminated by \r\n\r\n)
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) return; // Still waiting for headers

    const headerSection = buffer.subarray(0, headerEnd).toString('utf-8');
    const [requestLine, ...headerLines] = headerSection.split('\r\n');
    const [method, path, httpVersion] = requestLine.split(' ');

    const headers = {};
    for (const line of headerLines) {
      const colonIndex = line.indexOf(':');
      const key = line.substring(0, colonIndex).trim().toLowerCase();
      const value = line.substring(colonIndex + 1).trim();
      headers[key] = value;
    }

    // Body starts after \r\n\r\n
    const body = buffer.subarray(headerEnd + 4);

    handleRequest(socket, { method, path, httpVersion, headers, body });
  });

  socket.on('error', (err) => {
    if (err.code !== 'ECONNRESET') console.error('Socket error:', err.message);
  });
});

server.listen(3000, () => console.log('TCP server listening on :3000'));
```

**Builds on:** Step 05 (Streaming Response Support) — you already stream file responses; now you control the transport layer itself.

**Leads to:** Step 07 (Full HTTP Protocol Implementation) — you will build a complete HTTP parser and response builder on top of this TCP foundation.

---

## Prerequisites

- Module 05 (Streams) — TCP sockets are Duplex streams; everything you learned about backpressure, piping, and events applies directly
- Module 03 (Buffers) — network data arrives as Buffers; you will parse raw bytes, compute offsets, and concatenate chunks

---

## Key Concepts Introduced

- **Socket** — a bidirectional communication endpoint identified by IP address and port number
- **Three-way handshake** — SYN, SYN-ACK, ACK — the TCP connection establishment ritual
- **Framing** — the protocol-level technique for knowing where one message ends and the next begins
- **Nagle's algorithm** — TCP's small-packet batching optimization (and why you might disable it)
- **Half-open connection** — a TCP state where one side has closed its write end but can still read
- **DNS lookup vs resolve** — `dns.lookup` uses the OS resolver (blocking the thread pool); `dns.resolve` queries DNS directly (non-blocking)

---

## Next

Continue to [Module 07 — HTTP From Scratch](../module-07-http/README.md) to build a complete HTTP protocol implementation on top of the TCP server you created here.
