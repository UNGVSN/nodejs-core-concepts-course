# Module 06 / Lesson 04 — UDP Protocol & Datagrams

> TCP guarantees delivery but pays for it with handshakes, acknowledgments, and retransmissions. UDP makes a different trade-off: it sends data and hopes for the best. This lesson shows you when that trade-off makes sense and how to work with UDP in Node.js using the `node:dgram` module.

---

## Learning Objectives

- Explain the connectionless model of UDP and how it differs from TCP's connection-oriented approach
- Create UDP sockets with `dgram.createSocket` and send/receive datagrams
- Identify use cases where UDP is the right choice: DNS, gaming, video streaming, service discovery
- Implement basic UDP multicast for one-to-many communication
- Contrast UDP's message boundaries with TCP's byte stream semantics

---

## What UDP Is (and Is Not)

UDP (User Datagram Protocol) is a transport-layer protocol that provides:

- **Connectionless communication** — No handshake. No connection state. You just send.
- **Message boundaries** — Each `send()` produces exactly one datagram on the wire. The receiver gets exactly that message, not a fragment of it and not two messages merged together.
- **Minimal overhead** — The UDP header is only 8 bytes (compared to TCP's minimum 20 bytes).

UDP does **not** provide:

- Reliable delivery — Packets can be lost with no notification.
- Ordered delivery — Packets can arrive out of order.
- Flow control — The sender can overwhelm the receiver.
- Congestion control — The sender can flood the network.

### The UDP Header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            Length             |           Checksum            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

That is it. Four fields, 8 bytes. No sequence numbers, no acknowledgments, no window sizes.

---

## Creating a UDP Socket

The `node:dgram` module provides UDP functionality. Unlike `node:net`, there is no `createServer` and `createConnection` — because there is no connection. You create a socket, bind it to a port, and start sending or receiving.

```javascript
'use strict';

const dgram = require('node:dgram');

// Create a UDP socket for IPv4
const socket = dgram.createSocket('udp4');

// Bind to a port to receive incoming datagrams
socket.bind(4000, () => {
  const addr = socket.address();
  console.log(`UDP socket bound to ${addr.address}:${addr.port}`);
});

// Listen for incoming messages
socket.on('message', (msg, rinfo) => {
  console.log(`Received ${msg.length} bytes from ${rinfo.address}:${rinfo.port}`);
  console.log(`Message: ${msg.toString()}`);
});

// Handle errors
socket.on('error', (err) => {
  console.error('Socket error:', err.message);
  socket.close();
});
```

The `rinfo` (remote info) parameter tells you who sent the datagram. This is essential because UDP has no connection — you must identify senders by their address and port.

---

## Sending Datagrams

To send a datagram, you call `socket.send()` with the message, destination port, and destination address:

```javascript
'use strict';

const dgram = require('node:dgram');

const client = dgram.createSocket('udp4');

const message = Buffer.from('Hello, UDP server!');

// send(msg, offset, length, port, address, callback)
client.send(message, 0, message.length, 4000, '127.0.0.1', (err) => {
  if (err) {
    console.error('Send error:', err.message);
  } else {
    console.log('Message sent');
  }
  client.close();
});
```

You can also use the shorter form:

```javascript
'use strict';

const dgram = require('node:dgram');

const client = dgram.createSocket('udp4');

// Shorter form — offset and length are optional
client.send('Hello, UDP server!', 4000, '127.0.0.1', (err) => {
  if (err) console.error(err.message);
  client.close();
});
```

Notice: `send()` does not guarantee delivery. The callback fires when the message has been handed to the OS for sending, not when the destination receives it. The message might be lost in transit, and you will never know.

---

## A Complete UDP Echo Server and Client

```javascript
'use strict';

const dgram = require('node:dgram');

// --- Server ---
const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  console.log(`[server] Received from ${rinfo.address}:${rinfo.port}: ${msg}`);

  // Echo the message back to the sender
  server.send(msg, rinfo.port, rinfo.address, (err) => {
    if (err) console.error('[server] Send error:', err.message);
  });
});

server.on('listening', () => {
  const addr = server.address();
  console.log(`[server] Listening on ${addr.address}:${addr.port}`);
});

server.bind(4000);

// --- Client ---
setTimeout(() => {
  const client = dgram.createSocket('udp4');

  const messages = ['hello', 'world', 'goodbye'];
  let received = 0;

  client.on('message', (msg, rinfo) => {
    console.log(`[client] Echo from ${rinfo.address}:${rinfo.port}: ${msg}`);
    received++;

    if (received === messages.length) {
      client.close();
      server.close();
    }
  });

  for (const text of messages) {
    client.send(text, 4000, '127.0.0.1');
  }
}, 100);
```

---

## Message Boundaries vs TCP Stream

This is one of the most important distinctions between UDP and TCP.

### TCP: A Byte Stream

TCP is a continuous byte stream. If the sender writes three messages of 10 bytes each, the receiver might get one `data` event with 30 bytes, or three events with 10 bytes each, or two events with 15 bytes each. TCP does not preserve message boundaries.

```javascript
'use strict';

const net = require('node:net');

// TCP does NOT preserve message boundaries
const server = net.createServer((socket) => {
  socket.on('data', (data) => {
    // This might fire once with "AAABBBCCC" or three times with "AAA", "BBB", "CCC"
    // or any other combination — TCP makes no guarantees about framing
    console.log(`[TCP] Received ${data.length} bytes: ${data.toString()}`);
  });
  socket.on('end', () => server.close());
});

server.listen(4001, () => {
  const client = net.createConnection({ port: 4001 }, () => {
    client.write('AAA');
    client.write('BBB');
    client.write('CCC');
    client.end();
  });
});
```

### UDP: Discrete Messages

UDP preserves message boundaries. Each `send()` produces exactly one datagram. Each `message` event delivers exactly one datagram. Messages are never merged, split, or reordered within a single datagram.

```javascript
'use strict';

const dgram = require('node:dgram');

// UDP DOES preserve message boundaries
const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  // Each send() results in exactly one 'message' event
  // You will always get "AAA", "BBB", "CCC" as separate messages
  console.log(`[UDP] Received: ${msg.toString()}`);
});

let messageCount = 0;
server.on('message', () => {
  messageCount++;
  if (messageCount === 3) server.close();
});

server.bind(4002, () => {
  const client = dgram.createSocket('udp4');

  client.send('AAA', 4002, '127.0.0.1');
  client.send('BBB', 4002, '127.0.0.1');
  client.send('CCC', 4002, '127.0.0.1');

  setTimeout(() => client.close(), 100);
});
```

However, UDP datagrams **can** arrive out of order or not arrive at all. So you get clean message boundaries but no delivery or ordering guarantee.

---

## When to Use UDP

UDP is the right choice when:

### 1. Real-Time Data Where Stale Is Useless

Video streaming, voice calls, live gaming. If a video frame arrives 500ms late, retransmitting it is pointless — the moment has passed. You want the latest data, not a perfect reconstruction of old data.

### 2. Simple Request-Response (With Application-Level Retry)

DNS lookups are UDP by default. The client sends a query, waits for a response. If no response arrives within a timeout, it retries. The simplicity of UDP makes this faster than establishing a TCP connection for a single query.

### 3. Broadcast and Multicast

Service discovery (mDNS, SSDP) uses UDP multicast to find devices on a local network. TCP has no equivalent — it is point-to-point only.

### 4. High-Frequency, Loss-Tolerant Telemetry

Metrics collection, sensor data, log shipping where individual data points are expendable. Sending thousands of small UDP packets per second is cheaper than maintaining thousands of TCP connections.

---

## UDP Multicast

Multicast sends a single datagram to multiple receivers simultaneously. The sender sends once, and the network infrastructure replicates the packet to all subscribers.

### Multicast Addresses

IPv4 multicast uses the address range `224.0.0.0` to `239.255.255.255`. You "join" a multicast group to receive messages sent to that address.

```javascript
'use strict';

const dgram = require('node:dgram');

const MULTICAST_ADDR = '224.1.1.1';
const PORT = 5000;

// --- Receiver (join the multicast group) ---
function createReceiver(id) {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.on('message', (msg, rinfo) => {
    console.log(`[receiver-${id}] ${msg} (from ${rinfo.address}:${rinfo.port})`);
  });

  socket.bind(PORT, () => {
    socket.addMembership(MULTICAST_ADDR);
    console.log(`[receiver-${id}] Joined multicast group ${MULTICAST_ADDR}`);
  });

  return socket;
}

// --- Sender (send to the multicast group) ---
function createSender() {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.bind(() => {
    socket.setMulticastTTL(128); // Time-to-live for multicast packets
    socket.setBroadcast(true);

    let count = 0;
    const interval = setInterval(() => {
      const msg = `Multicast message #${++count}`;
      socket.send(msg, PORT, MULTICAST_ADDR);
      console.log(`[sender] Sent: ${msg}`);

      if (count >= 3) {
        clearInterval(interval);
        setTimeout(() => socket.close(), 100);
      }
    }, 500);
  });

  return socket;
}

// Create two receivers and one sender
const r1 = createReceiver(1);
const r2 = createReceiver(2);

setTimeout(() => {
  const sender = createSender();
  // Both receivers will get each message — sent once, received twice
  setTimeout(() => {
    r1.close();
    r2.close();
  }, 3000);
}, 500);
```

### Multicast Options

| Method | Purpose |
|--------|---------|
| `socket.addMembership(multicastAddr)` | Join a multicast group |
| `socket.dropMembership(multicastAddr)` | Leave a multicast group |
| `socket.setMulticastTTL(ttl)` | Set the Time-To-Live for multicast packets (how many router hops) |
| `socket.setMulticastLoopback(flag)` | Whether the sender receives its own multicast messages |
| `socket.setMulticastInterface(interfaceAddr)` | Choose which network interface to use for multicast |

---

## UDP Broadcast

Broadcast sends to all devices on the local network. Unlike multicast, receivers do not need to join a group — they just listen on the right port.

```javascript
'use strict';

const dgram = require('node:dgram');

const BROADCAST_ADDR = '255.255.255.255';
const PORT = 5001;

// --- Receiver ---
const receiver = dgram.createSocket({ type: 'udp4', reuseAddr: true });

receiver.on('message', (msg, rinfo) => {
  console.log(`[receiver] ${msg} (from ${rinfo.address}:${rinfo.port})`);
  receiver.close();
});

receiver.bind(PORT);

// --- Sender ---
const sender = dgram.createSocket('udp4');

sender.bind(() => {
  sender.setBroadcast(true); // Required — broadcast is disabled by default

  sender.send('Anyone out there?', PORT, BROADCAST_ADDR, (err) => {
    if (err) console.error(err.message);
    sender.close();
  });
});
```

### Broadcast vs Multicast

| Feature | Broadcast | Multicast |
|---------|-----------|-----------|
| Scope | All devices on subnet | Only devices that joined the group |
| Address | `255.255.255.255` or subnet broadcast | `224.0.0.0` – `239.255.255.255` |
| Router forwarding | No (stays on local subnet) | Yes (with IGMP/PIM) |
| Overhead | High (every device processes the packet) | Lower (only group members process it) |

---

## Datagram Size Limits

UDP datagrams have a theoretical maximum size of 65,535 bytes (the UDP length field is 16 bits, and includes the 8-byte header). But in practice:

- **Ethernet MTU** is 1500 bytes. A UDP datagram larger than ~1472 bytes (1500 - 20 IP header - 8 UDP header) will be **fragmented** at the IP layer.
- **IP fragmentation** is unreliable — if any fragment is lost, the entire datagram is lost.
- **Many firewalls and NATs** drop fragmented UDP packets.
- **Safe maximum**: Keep UDP messages under **1400 bytes** to avoid fragmentation on any network.

```javascript
'use strict';

const dgram = require('node:dgram');

const socket = dgram.createSocket('udp4');

// This is fine — well under MTU
const smallMsg = Buffer.alloc(512, 0x41);
socket.send(smallMsg, 4000, '127.0.0.1');

// This might be fragmented — risky on real networks
const largeMsg = Buffer.alloc(8000, 0x42);
socket.send(largeMsg, 4000, '127.0.0.1');

// This will fail on most systems — too large for a single datagram
const hugeMsg = Buffer.alloc(70000, 0x43);
socket.send(hugeMsg, 4000, '127.0.0.1', (err) => {
  if (err) console.error('Send error:', err.message);
  // EMSGSIZE — message too long
  socket.close();
});
```

---

## Building a Simple UDP Service Discovery Protocol

A practical example: a service announces itself on the local network, and clients discover it.

```javascript
'use strict';

const dgram = require('node:dgram');

const DISCOVERY_PORT = 5555;
const MULTICAST_ADDR = '224.0.0.114';

// --- Service (announces itself) ---
function startService(name, servicePort) {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.bind(DISCOVERY_PORT, () => {
    socket.addMembership(MULTICAST_ADDR);
    console.log(`[${name}] Listening for discovery requests`);
  });

  socket.on('message', (msg, rinfo) => {
    if (msg.toString() === 'DISCOVER') {
      const response = JSON.stringify({
        name,
        port: servicePort,
        timestamp: Date.now(),
      });

      socket.send(response, rinfo.port, rinfo.address, (err) => {
        if (err) console.error(`[${name}] Response error:`, err.message);
        else console.log(`[${name}] Responded to ${rinfo.address}:${rinfo.port}`);
      });
    }
  });

  return socket;
}

// --- Client (discovers services) ---
function discoverServices(timeout = 2000) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const services = [];

    socket.on('message', (msg, rinfo) => {
      try {
        const service = JSON.parse(msg.toString());
        services.push({ ...service, address: rinfo.address });
        console.log(`[client] Found: ${service.name} at ${rinfo.address}:${service.port}`);
      } catch {
        // Ignore non-JSON responses
      }
    });

    socket.bind(() => {
      socket.setBroadcast(true);
      socket.send('DISCOVER', DISCOVERY_PORT, MULTICAST_ADDR);
      console.log('[client] Sent discovery request');
    });

    setTimeout(() => {
      socket.close();
      resolve(services);
    }, timeout);
  });
}

// Demo: start two services, then discover them
const svc1 = startService('api-server', 3000);
const svc2 = startService('websocket-server', 3001);

setTimeout(async () => {
  const found = await discoverServices(1000);
  console.log(`\nDiscovered ${found.length} services`);

  svc1.close();
  svc2.close();
}, 500);
```

---

## Socket Options Reference

Key options for `dgram.createSocket`:

```javascript
'use strict';

const dgram = require('node:dgram');

const socket = dgram.createSocket({
  type: 'udp4',              // 'udp4' or 'udp6'
  reuseAddr: true,           // Allow multiple sockets to bind to the same port (for multicast)
  recvBufferSize: 1048576,   // OS receive buffer size in bytes (1 MB)
  sendBufferSize: 1048576,   // OS send buffer size in bytes (1 MB)
});
```

Methods on the socket:

| Method | Purpose |
|--------|---------|
| `socket.bind(port, [address])` | Bind to a port to receive datagrams |
| `socket.send(msg, port, address, [cb])` | Send a datagram |
| `socket.close([cb])` | Close the socket |
| `socket.address()` | Get the bound address and port |
| `socket.setTTL(ttl)` | Set the IP Time-To-Live |
| `socket.setBroadcast(flag)` | Enable/disable broadcast |
| `socket.setMulticastTTL(ttl)` | Set multicast TTL |
| `socket.addMembership(addr)` | Join a multicast group |
| `socket.dropMembership(addr)` | Leave a multicast group |
| `socket.ref()` / `socket.unref()` | Keep/release the event loop |

---

## Error Handling

UDP errors are different from TCP errors. Since there is no connection, most errors are local:

```javascript
'use strict';

const dgram = require('node:dgram');

const socket = dgram.createSocket('udp4');

socket.on('error', (err) => {
  console.error('Socket error:', err.message);
  console.error('Error code:', err.code);
  // Common codes:
  // EADDRINUSE   — port already bound
  // EACCES       — permission denied (binding to port < 1024 without root)
  // EMSGSIZE     — datagram too large
  // ENOTFOUND    — DNS resolution failed for the destination
  socket.close();
});

// Trying to bind to a privileged port without root
socket.bind(53); // Will emit 'error' with EACCES on most systems
```

There is no `ECONNREFUSED` or `ECONNRESET` — those are TCP concepts. If you send a UDP datagram to a closed port, the remote host might send an ICMP "port unreachable" message, which Node.js surfaces as an error event. But this is best-effort — many firewalls suppress ICMP.

---

## Key Takeaways

- UDP is connectionless — no handshake, no connection state, no guaranteed delivery. Each `send()` is independent.
- UDP preserves message boundaries: one `send()` produces exactly one `message` event. TCP does not — it delivers a byte stream that must be framed.
- Use UDP for real-time data (video, gaming, VoIP), simple request-response (DNS), broadcast/multicast (service discovery), and high-frequency telemetry.
- Keep UDP datagrams under 1400 bytes to avoid IP fragmentation, which causes silent packet loss on many networks.
- `dgram.createSocket` gives you multicast (`addMembership`) and broadcast (`setBroadcast`) capabilities that TCP cannot provide.

---

## Next

Continue to [Lesson 05 — DNS Resolution](lesson-05-dns-resolution.md) to understand how domain names are resolved to IP addresses — the process that happens before any TCP or UDP connection can be established.
