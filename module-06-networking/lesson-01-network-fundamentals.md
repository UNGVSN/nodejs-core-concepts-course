# Module 06 / Lesson 01 — Network Fundamentals

> Every time you call `http.createServer`, you are standing on top of a tower of protocols, each one solving a specific problem. This lesson takes you to the ground floor so you can understand every layer beneath your Node.js code.

---

## Learning Objectives

- Describe the seven layers of the OSI model and identify where each protocol operates
- Map the OSI model onto the four-layer TCP/IP model used in real-world networking
- Distinguish between packets, frames, and segments and explain when each term applies
- Explain port numbers, well-known ports, and ephemeral port ranges
- Define what a socket is and how it serves as an endpoint for bidirectional communication

---

## Why Network Fundamentals Matter

When your TCP server is not receiving data, the bug might not be in your JavaScript. It might be a firewall blocking a port, a misconfigured subnet, or a MTU mismatch causing silent packet fragmentation. Understanding the network stack gives you the vocabulary and mental model to diagnose problems that live outside your codebase.

Node.js operates primarily at the **transport layer** (TCP/UDP) and **application layer** (HTTP, DNS). But data flows through every layer on every request. You need to know what happens at each one.

---

## The OSI Model — Seven Layers

The Open Systems Interconnection model is a conceptual framework that standardizes how networked systems communicate. It was published by the ISO in 1984. Nobody implements it literally, but everyone uses it as a reference for talking about networking.

### Layer 7 — Application

The layer closest to the user. This is where HTTP, HTTPS, FTP, SMTP, DNS, and SSH operate. When you call `http.createServer`, you are writing application-layer code.

```javascript
'use strict';

const http = require('node:http');

// This is Layer 7 — your application speaks HTTP
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello from the application layer\n');
});

server.listen(3000);
```

### Layer 6 — Presentation

Handles data encoding, encryption, and compression. When TLS encrypts your HTTP traffic into HTTPS, that is a presentation-layer concern. In Node.js, the `node:tls` and `node:zlib` modules operate here.

### Layer 5 — Session

Manages sessions between applications — establishing, maintaining, and terminating connections. In practice, this layer is rarely implemented as a distinct component. TCP's connection state and HTTP cookies handle most session concerns.

### Layer 4 — Transport

This is where **TCP** and **UDP** live. The transport layer is responsible for end-to-end communication between processes on different machines. TCP provides reliable, ordered delivery. UDP provides fast, unreliable delivery. Node.js gives you direct access through `node:net` (TCP) and `node:dgram` (UDP).

```javascript
'use strict';

const net = require('node:net');

// This is Layer 4 — your application speaks raw TCP
const server = net.createServer((socket) => {
  socket.write('Hello from the transport layer\n');
  socket.end();
});

server.listen(4000);
```

### Layer 3 — Network

The **IP** layer. Responsible for logical addressing (IP addresses) and routing packets between networks. IPv4 and IPv6 operate here. When a packet traverses the internet, routers at this layer decide the next hop.

### Layer 2 — Data Link

Handles communication within a single network segment. Ethernet and Wi-Fi operate here. Data at this layer is organized into **frames**, and devices are identified by **MAC addresses** (48-bit hardware addresses).

### Layer 1 — Physical

The actual electrical signals, light pulses, or radio waves that carry bits over a physical medium — copper cables, fiber optics, or wireless frequencies. This layer is pure hardware.

### The Mnemonic

Top-down: **A**ll **P**eople **S**eem **T**o **N**eed **D**ata **P**rocessing (Application through Physical).

Bottom-up: **P**lease **D**o **N**ot **T**hrow **S**ausage **P**izza **A**way.

---

## The TCP/IP Model — Four Layers

The OSI model is a teaching tool. The TCP/IP model is what the internet actually runs on. It collapses seven layers into four.

| TCP/IP Layer | OSI Layers | Protocols |
|--------------|-----------|-----------|
| **Application** | 7, 6, 5 | HTTP, HTTPS, FTP, DNS, SMTP, SSH, TLS |
| **Transport** | 4 | TCP, UDP |
| **Internet** | 3 | IPv4, IPv6, ICMP, ARP |
| **Link** | 2, 1 | Ethernet, Wi-Fi, PPP |

The TCP/IP model is pragmatic. It does not care about the theoretical distinction between presentation and session layers — they are all just "application" concerns.

### Where Node.js Lives

Node.js gives you APIs at two levels:

1. **Transport layer** — `node:net` (TCP sockets), `node:dgram` (UDP sockets), `node:tls` (encrypted TCP)
2. **Application layer** — `node:http`, `node:https`, `node:dns`

Everything below the transport layer is handled by the operating system kernel and the network hardware. You cannot write a Layer 3 router in pure JavaScript — you need raw sockets, which Node.js does not expose by default.

---

## Packets, Frames, and Segments

These three terms are not interchangeable. Each belongs to a specific layer of the network stack.

### Segment (Layer 4 — Transport)

A TCP segment is the unit of data at the transport layer. It contains a TCP header (source port, destination port, sequence number, flags) and a payload. The term "segment" is specific to TCP. UDP calls its units **datagrams**.

### Packet (Layer 3 — Network)

An IP packet wraps a TCP segment (or UDP datagram) with an IP header containing source and destination IP addresses. The term "packet" is the most commonly used because Layer 3 is where routing decisions are made.

### Frame (Layer 2 — Data Link)

An Ethernet frame wraps an IP packet with a frame header containing source and destination MAC addresses and a frame check sequence (CRC) for error detection.

### The Encapsulation Model

When your Node.js server sends data, it travels down the stack, gaining headers at each layer:

```
Application:   [HTTP response data]
Transport:     [TCP header | HTTP response data]
Network:       [IP header | TCP header | HTTP response data]
Data Link:     [Ethernet header | IP header | TCP header | HTTP response data | CRC]
Physical:      [electrical signals representing the frame bits]
```

When the data arrives at the destination, each layer strips its header and passes the payload up to the next layer. This is **encapsulation** (going down) and **decapsulation** (going up).

---

## Ports — Addressing Processes on a Machine

An IP address identifies a machine. A port number identifies a specific process (or service) on that machine. Together, an IP address and port form a **socket address** — the complete address needed to reach a specific application.

### Port Number Ranges

Port numbers are 16-bit unsigned integers, ranging from 0 to 65,535.

| Range | Name | Description |
|-------|------|-------------|
| 0–1023 | Well-known ports | Reserved for system services. Requires root/admin to bind. |
| 1024–49151 | Registered ports | Assigned by IANA for specific applications. |
| 49152–65535 | Ephemeral (dynamic) ports | Assigned automatically by the OS for outbound connections. |

### Well-Known Ports You Should Memorize

| Port | Protocol | Service |
|------|----------|---------|
| 20, 21 | TCP | FTP (data, control) |
| 22 | TCP | SSH |
| 25 | TCP | SMTP |
| 53 | TCP/UDP | DNS |
| 80 | TCP | HTTP |
| 110 | TCP | POP3 |
| 143 | TCP | IMAP |
| 443 | TCP | HTTPS |
| 3306 | TCP | MySQL |
| 5432 | TCP | PostgreSQL |
| 6379 | TCP | Redis |
| 27017 | TCP | MongoDB |

### Ephemeral Ports in Node.js

When Node.js makes an outbound TCP connection, the operating system assigns an ephemeral port for the client side. You can see this in action:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // The client's address includes the ephemeral port the OS assigned
  const remote = `${socket.remoteAddress}:${socket.remotePort}`;
  console.log(`Connection from ${remote}`);

  socket.end('goodbye\n');
});

server.listen(4000, () => {
  console.log('Server listening on port 4000');

  // Connect to ourselves — the OS assigns an ephemeral port for this client socket
  const client = net.createConnection({ port: 4000 }, () => {
    const local = `${client.localAddress}:${client.localPort}`;
    console.log(`Client local address: ${local}`);
    // localPort will be something like 52341 — an ephemeral port
  });

  client.on('data', (data) => console.log(`Received: ${data}`));
  client.on('end', () => server.close());
});
```

### Port Conflicts

If you try to bind a server to a port that is already in use, you get `EADDRINUSE`:

```javascript
'use strict';

const net = require('node:net');

const server1 = net.createServer();
const server2 = net.createServer();

server1.listen(4000, () => {
  console.log('Server 1 listening on 4000');

  server2.listen(4000, () => {
    console.log('This will never print');
  });

  server2.on('error', (err) => {
    console.error(err.code); // 'EADDRINUSE'
    console.error('Port 4000 is already in use');
    server1.close();
  });
});
```

---

## Sockets — The Endpoint Abstraction

A **socket** is an endpoint for sending or receiving data across a network. It is identified by a combination of:

- **Protocol** (TCP or UDP)
- **Local IP address**
- **Local port number**
- **Remote IP address** (for connected sockets)
- **Remote port number** (for connected sockets)

This five-tuple uniquely identifies every TCP connection on a machine.

### Socket Types

| Type | Protocol | Behavior |
|------|----------|----------|
| Stream socket | TCP | Connection-oriented, reliable, ordered byte stream |
| Datagram socket | UDP | Connectionless, unreliable, message-oriented |

### Sockets in Node.js

In Node.js, a `net.Socket` object represents a TCP stream socket. It is a **Duplex stream** — you can both read from it and write to it. This is a critical insight: everything you learned about streams in Module 05 applies directly to network sockets.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // socket is a Duplex stream
  console.log('Readable:', socket.readable);   // true
  console.log('Writable:', socket.writable);   // true

  // You can pipe data through it like any other stream
  socket.pipe(socket); // Echo server: pipe incoming data back to the sender
});

server.listen(4000, () => {
  console.log('Echo server on port 4000');
});
```

### Socket States

A TCP socket goes through several states during its lifetime:

1. **CLOSED** — No connection exists
2. **LISTEN** — Server is waiting for incoming connections
3. **SYN_SENT** — Client has sent a SYN, waiting for SYN-ACK
4. **SYN_RECEIVED** — Server has received SYN, sent SYN-ACK, waiting for ACK
5. **ESTABLISHED** — Connection is active, data can flow in both directions
6. **FIN_WAIT_1/2** — Connection is being closed from this side
7. **CLOSE_WAIT** — The other side has closed; waiting for local close
8. **TIME_WAIT** — Connection is closed; waiting for any delayed packets to expire

You will see these states when running `netstat` or `ss` on a server. Understanding them helps you diagnose connection issues — for example, a large number of `TIME_WAIT` sockets indicates rapid connection creation and teardown (common with HTTP/1.0 without keep-alive).

---

## Putting It All Together: A Request's Journey

When a browser sends an HTTP request to your Node.js server at `http://example.com:3000/api/users`, the following happens at each layer:

1. **Application layer** — The browser constructs an HTTP GET request with headers
2. **Transport layer** — TCP segments the request, adds source port (ephemeral) and destination port (3000), manages sequence numbers
3. **Internet layer** — IP wraps each segment in a packet with source IP (the browser's machine) and destination IP (your server's machine)
4. **Link layer** — Ethernet frames the packets with MAC addresses for the next hop (usually the default gateway router)
5. **Physical layer** — Bits travel over the wire (or air) as electrical or optical signals

At each router along the path, the link and physical layers are stripped and rebuilt (because the next-hop MAC address changes), but the IP and TCP layers remain unchanged until the packet reaches the destination.

When the packet arrives at your server:

1. The NIC (Network Interface Card) receives the electrical signals and reconstructs the frame
2. The kernel strips the Ethernet header, checks the CRC
3. The kernel strips the IP header, verifies the destination IP matches
4. The kernel strips the TCP header, matches the destination port to a listening socket
5. The kernel delivers the payload to your Node.js process
6. Your `'data'` event handler fires with a Buffer containing the HTTP request bytes

---

## Inspecting Network Information in Node.js

The `node:os` module provides access to network interface information:

```javascript
'use strict';

const os = require('node:os');

const interfaces = os.networkInterfaces();

for (const [name, addrs] of Object.entries(interfaces)) {
  for (const addr of addrs) {
    console.log(`${name}: ${addr.family} ${addr.address} (${addr.internal ? 'internal' : 'external'})`);
    // Example output:
    // lo0: IPv4 127.0.0.1 (internal)
    // lo0: IPv6 ::1 (internal)
    // en0: IPv4 192.168.1.42 (external)
    // en0: IPv6 fe80::1 (external)
  }
}
```

This is useful for server startup logging, binding to specific interfaces, and health checks.

---

## MTU — Maximum Transmission Unit

The Maximum Transmission Unit is the largest packet size (in bytes) that a network link can carry without fragmentation. For Ethernet, the standard MTU is **1500 bytes**. This means an IP packet larger than 1500 bytes must be split into fragments.

Why this matters for Node.js: if you write a 64 KB chunk to a TCP socket, the OS will split it into many segments, each fitting within the path MTU. TCP handles this transparently. UDP does not — if you send a UDP datagram larger than the path MTU, it may be fragmented or dropped. This is why UDP applications typically keep messages under 1400 bytes.

---

## Key Takeaways

- The OSI model has seven layers; the TCP/IP model has four. Node.js operates at the transport layer (`node:net`, `node:dgram`) and application layer (`node:http`, `node:dns`).
- Data is encapsulated with headers as it descends the stack (application to physical) and decapsulated as it ascends at the destination.
- Port numbers (0-65535) identify processes on a machine; well-known ports (0-1023) are reserved for standard services.
- A socket is an endpoint identified by a five-tuple: protocol, local IP, local port, remote IP, remote port.
- TCP sockets in Node.js are Duplex streams — everything from Module 05 (Streams) applies to network programming.

---

## Next

Continue to [Lesson 02 — IP Addressing](lesson-02-ip-addressing.md) to understand how machines are identified on a network, from 32-bit IPv4 addresses to 128-bit IPv6, subnets, and the ARP protocol that bridges Layer 2 and Layer 3.
