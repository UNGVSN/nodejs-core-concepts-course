# Track 03 / Lesson 05 — Low-Level Networking

> HTTP and TCP abstractions hide a world of raw networking primitives that systems programmers use daily. UDP multicast lets you discover services on a network without knowing their addresses. Broadcast lets you announce to everyone at once. Socket options let you tune kernel behavior. This lesson takes you below the transport layer and puts you in control of the wire.

## Learning Objectives

- Use `node:dgram` to send and receive UDP datagrams with advanced socket options
- Configure UDP multicast for group communication using `addMembership`, `setMulticastTTL`, and `setMulticastLoopback`
- Implement UDP broadcast for network-wide announcements using `setBroadcast(true)`
- Set socket options like `reuseAddr` and `reusePort` for multi-process socket sharing
- Build a complete service discovery protocol and network presence heartbeat system

---

## UDP Fundamentals with node:dgram

UDP (User Datagram Protocol) is a connectionless, unreliable transport protocol. There is no handshake, no guaranteed delivery, no ordering, and no flow control. What you get in return is speed — minimal overhead, no connection state, and the ability to send to multiple recipients simultaneously.

```javascript
'use strict';

const dgram = require('node:dgram');

// ─── Simple UDP Echo Server ─────────────────────────────────────────
const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  console.log(`Received ${msg.length} bytes from ${rinfo.address}:${rinfo.port}`);
  console.log(`Message: ${msg.toString()}`);

  // Echo back to the sender
  const response = Buffer.from(`Echo: ${msg.toString()}`);
  server.send(response, rinfo.port, rinfo.address, (err) => {
    if (err) console.error(`Send error: ${err.message}`);
  });
});

server.on('error', (err) => {
  console.error(`Server error: ${err.message}`);
  server.close();
});

server.on('listening', () => {
  const addr = server.address();
  console.log(`UDP echo server listening on ${addr.address}:${addr.port}`);
});

server.bind(41234);
```

```javascript
'use strict';

const dgram = require('node:dgram');

// ─── Simple UDP Client ──────────────────────────────────────────────
const client = dgram.createSocket('udp4');
const message = Buffer.from('Hello, UDP!');

client.send(message, 41234, '127.0.0.1', (err) => {
  if (err) {
    console.error(`Send error: ${err.message}`);
    client.close();
    return;
  }
  console.log(`Sent: ${message.toString()}`);
});

client.on('message', (msg, rinfo) => {
  console.log(`Response from ${rinfo.address}:${rinfo.port}: ${msg.toString()}`);
  client.close();
});

// Timeout in case the server does not respond
setTimeout(() => {
  console.log('No response — closing');
  client.close();
}, 2000);
```

### Key Differences from TCP

```javascript
'use strict';

// UDP vs TCP comparison:
//
// | Feature          | TCP (node:net)        | UDP (node:dgram)       |
// |------------------|-----------------------|------------------------|
// | Connection       | Required (3-way HS)   | None (fire and forget) |
// | Reliability      | Guaranteed delivery   | Best-effort            |
// | Ordering         | Guaranteed FIFO       | No ordering            |
// | Flow control     | Window-based          | None                   |
// | Max message size | Stream (no limit)     | ~65,507 bytes per msg  |
// | Overhead         | 20+ byte TCP header   | 8-byte UDP header      |
// | Multicast        | Not supported         | Supported              |
// | Broadcast        | Not supported         | Supported              |
// | Use cases        | HTTP, databases, SSH  | DNS, gaming, streaming |
```

---

## Socket Options: reuseAddr and reusePort

Socket options control kernel-level behavior. Two options are particularly important for systems programming.

### SO_REUSEADDR

By default, after a UDP socket is closed, the OS keeps the address reserved for a brief period (TIME_WAIT). `reuseAddr` allows immediate rebinding.

```javascript
'use strict';

const dgram = require('node:dgram');

// reuseAddr: true allows binding to an address/port that was recently released
// This prevents "EADDRINUSE" errors during rapid restart cycles
const socket = dgram.createSocket({
  type: 'udp4',
  reuseAddr: true,
});

socket.bind(41235, () => {
  console.log('Bound with reuseAddr: true');
  console.log('This socket can rebind immediately after closing');
  const addr = socket.address();
  console.log(`Listening on ${addr.address}:${addr.port}`);
});

socket.on('message', (msg, rinfo) => {
  console.log(`${rinfo.address}:${rinfo.port} -> ${msg.toString()}`);
});

process.on('SIGINT', () => {
  socket.close(() => {
    console.log('Socket closed');
    process.exit(0);
  });
});
```

### SO_REUSEPORT

`reusePort` allows multiple sockets to bind to the same address and port simultaneously. The kernel distributes incoming datagrams among all bound sockets, enabling multi-process UDP handling (available on Linux 3.9+ and macOS).

```javascript
'use strict';

const dgram = require('node:dgram');

// Each worker process creates its own socket bound to the SAME port
const socket = dgram.createSocket({
  type: 'udp4',
  reuseAddr: true,
  // reusePort: true  — pass in the options if your Node.js version supports it
});

socket.bind(41236, () => {
  console.log(`[PID ${process.pid}] Bound to port 41236`);
});

socket.on('message', (msg, rinfo) => {
  console.log(`[PID ${process.pid}] ${msg} from ${rinfo.address}:${rinfo.port}`);
  socket.send(Buffer.from(`Handled by ${process.pid}`), rinfo.port, rinfo.address);
});

// Run multiple instances of this script — the kernel distributes datagrams
```

---

## UDP Multicast: Group Communication

Multicast sends a single datagram to all members of a group, identified by a special IP address range (224.0.0.0 - 239.255.255.255 for IPv4). The network hardware and switches handle replication — the sender transmits once, and every group member receives a copy.

### Multicast Sender

```javascript
'use strict';

const dgram = require('node:dgram');

const MULTICAST_GROUP = '239.1.2.3';
const MULTICAST_PORT = 41237;

const sender = dgram.createSocket({
  type: 'udp4',
  reuseAddr: true,
});

// Bind to any port (we are sending, not receiving on a specific port)
sender.bind(0, () => {
  // Set multicast TTL (Time To Live)
  // 0 = same host only
  // 1 = same subnet (default)
  // 32 = same site
  // 64 = same region
  // 128 = same continent
  // 255 = unrestricted
  sender.setMulticastTTL(1);

  // Enable loopback so the sender also receives its own messages
  // (useful for testing on a single machine)
  sender.setMulticastLoopback(true);

  console.log(`Sending multicast to ${MULTICAST_GROUP}:${MULTICAST_PORT}`);

  let sequence = 0;
  const interval = setInterval(() => {
    sequence++;
    const message = JSON.stringify({
      type: 'announcement',
      seq: sequence,
      timestamp: Date.now(),
      sender: `node-${process.pid}`,
    });

    sender.send(message, MULTICAST_PORT, MULTICAST_GROUP, (err) => {
      if (err) console.error(`Send error: ${err.message}`);
      else console.log(`Sent message #${sequence}`);
    });
  }, 1000);

  process.on('SIGINT', () => {
    clearInterval(interval);
    sender.close(() => {
      console.log('\nSender closed');
      process.exit(0);
    });
  });
});
```

### Multicast Receiver

```javascript
'use strict';

const dgram = require('node:dgram');

const MULTICAST_GROUP = '239.1.2.3';
const MULTICAST_PORT = 41237;

const receiver = dgram.createSocket({
  type: 'udp4',
  reuseAddr: true,
});

receiver.bind(MULTICAST_PORT, () => {
  // Join the multicast group — tell the kernel we want to receive
  // datagrams sent to this group address
  receiver.addMembership(MULTICAST_GROUP);

  console.log(`Joined multicast group ${MULTICAST_GROUP} on port ${MULTICAST_PORT}`);
  console.log('Waiting for messages...\n');
});

receiver.on('message', (msg, rinfo) => {
  try {
    const data = JSON.parse(msg.toString());
    console.log(
      `[${new Date(data.timestamp).toISOString()}] ` +
      `From ${rinfo.address}:${rinfo.port} ` +
      `(sender: ${data.sender}, seq: ${data.seq})`
    );
  } catch {
    console.log(`Raw message from ${rinfo.address}: ${msg.toString()}`);
  }
});

receiver.on('error', (err) => {
  console.error(`Receiver error: ${err.message}`);
});

process.on('SIGINT', () => {
  // Leave the multicast group before closing
  try {
    receiver.dropMembership(MULTICAST_GROUP);
  } catch {
    // May fail if already dropped
  }
  receiver.close(() => {
    console.log('\nReceiver closed');
    process.exit(0);
  });
});
```

### Multicast on a Specific Interface

On machines with multiple network interfaces, specify which one to use for multicast by passing the local IP as the second argument to `addMembership` and calling `setMulticastInterface`:

```javascript
'use strict';

const dgram = require('node:dgram');
const os = require('node:os');

// Find the first non-internal IPv4 address
function getLocalIPv4() {
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const addr of addrs) {
      if (addr.family === 'IPv4' && !addr.internal) return addr.address;
    }
  }
  return '0.0.0.0';
}

const localIP = getLocalIPv4();
const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

socket.bind(41238, () => {
  socket.addMembership('239.1.2.3', localIP);     // Join on specific interface
  socket.setMulticastInterface(localIP);           // Send from specific interface
  console.log(`Multicast on ${localIP}`);
});

socket.on('message', (msg, rinfo) => {
  console.log(`${rinfo.address}: ${msg}`);
});
```

---

## UDP Broadcast: Everyone Hears

Broadcast sends a datagram to every host on the local subnet. Unlike multicast (which requires explicit group membership), broadcast reaches all hosts on the subnet whether they subscribed or not. You must call `setBroadcast(true)` before sending to a broadcast address.

```javascript
'use strict';

const dgram = require('node:dgram');

const BROADCAST_PORT = 41239;
const mode = process.argv[2]; // 'send' or 'listen'

if (mode === 'send') {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.bind(0, () => {
    socket.setBroadcast(true); // Required before sending to broadcast address
    console.log('Broadcasting every 2 seconds...');

    let seq = 0;
    const interval = setInterval(() => {
      seq++;
      const msg = JSON.stringify({ seq, pid: process.pid, time: Date.now() });
      // 255.255.255.255 = limited broadcast (local subnet only)
      // You can also use directed broadcast: 192.168.1.255
      socket.send(msg, BROADCAST_PORT, '255.255.255.255', (err) => {
        if (err) console.error(`Error: ${err.message}`);
        else console.log(`Broadcast #${seq}`);
      });
    }, 2000);

    process.on('SIGINT', () => { clearInterval(interval); socket.close(); process.exit(0); });
  });
} else {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.bind(BROADCAST_PORT, () => {
    console.log(`Listening for broadcasts on port ${BROADCAST_PORT}`);
  });

  socket.on('message', (msg, rinfo) => {
    const data = JSON.parse(msg.toString());
    console.log(`From ${rinfo.address}: seq=${data.seq}, PID=${data.pid}`);
  });

  process.on('SIGINT', () => { socket.close(); process.exit(0); });
}
// Usage:  Terminal 1: node broadcast.js listen
//         Terminal 2: node broadcast.js send
```

---

## Building a Service Discovery Protocol

Service discovery lets processes find each other on a network without hardcoded addresses. This is the foundation of tools like mDNS/Bonjour, Consul, and etcd's peer discovery.

```javascript
'use strict';

const dgram = require('node:dgram');
const os = require('node:os');
const crypto = require('node:crypto');

const DISCOVERY_GROUP = '239.10.20.30';
const DISCOVERY_PORT = 41240;

function getLocalIP() {
  const interfaces = os.networkInterfaces();
  for (const addrs of Object.values(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === 'IPv4' && !addr.internal) {
        return addr.address;
      }
    }
  }
  return '127.0.0.1';
}

/**
 * Create a discoverable service node.
 *
 * @param {string} serviceName - Name of the service (e.g., 'api', 'worker')
 * @param {number} servicePort - Port the actual service listens on
 */
function createServiceNode(serviceName, servicePort) {
  const nodeId = crypto.randomBytes(4).toString('hex');
  const localIP = getLocalIP();
  const peers = new Map(); // nodeId -> { name, host, port, lastSeen }

  const socket = dgram.createSocket({
    type: 'udp4',
    reuseAddr: true,
  });

  socket.bind(DISCOVERY_PORT, () => {
    socket.addMembership(DISCOVERY_GROUP);
    socket.setMulticastTTL(1);
    socket.setMulticastLoopback(true);

    console.log(`[${nodeId}] Service "${serviceName}" discoverable`);
    console.log(`[${nodeId}] Listening at ${localIP}:${servicePort}`);
    console.log(`[${nodeId}] Discovery group: ${DISCOVERY_GROUP}:${DISCOVERY_PORT}\n`);
  });

  // Send periodic announcements
  const announceInterval = setInterval(() => {
    const announcement = JSON.stringify({
      type: 'announce',
      nodeId,
      name: serviceName,
      host: localIP,
      port: servicePort,
      timestamp: Date.now(),
    });

    socket.send(announcement, DISCOVERY_PORT, DISCOVERY_GROUP);
  }, 3000);

  // Listen for announcements from other services
  socket.on('message', (msg) => {
    try {
      const data = JSON.parse(msg.toString());
      if (data.type !== 'announce') return;
      if (data.nodeId === nodeId) return; // Ignore our own messages

      const isNew = !peers.has(data.nodeId);
      peers.set(data.nodeId, {
        name: data.name,
        host: data.host,
        port: data.port,
        lastSeen: Date.now(),
      });

      if (isNew) {
        console.log(`[${nodeId}] Discovered new peer: ${data.name} at ${data.host}:${data.port} (id: ${data.nodeId})`);
      }
    } catch {
      // Ignore malformed messages
    }
  });

  // Expire stale peers
  const cleanupInterval = setInterval(() => {
    const now = Date.now();
    const staleThreshold = 10_000; // 10 seconds

    for (const [peerId, peer] of peers) {
      if (now - peer.lastSeen > staleThreshold) {
        console.log(`[${nodeId}] Peer expired: ${peer.name} (${peerId})`);
        peers.delete(peerId);
      }
    }
  }, 5000);

  // Shutdown: send goodbye, leave group, close socket
  function shutdown() {
    clearInterval(announceInterval);
    clearInterval(cleanupInterval);
    const goodbye = JSON.stringify({ type: 'goodbye', nodeId, name: serviceName });
    socket.send(goodbye, DISCOVERY_PORT, DISCOVERY_GROUP, () => {
      socket.dropMembership(DISCOVERY_GROUP);
      socket.close();
      console.log(`[${nodeId}] Goodbye sent, shutting down`);
      process.exit(0);
    });
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  return { nodeId, peers, socket };
}

// Example: Run multiple instances with different service names
const serviceName = process.argv[2] || 'default';
const servicePort = parseInt(process.argv[3], 10) || 3000;

createServiceNode(serviceName, servicePort);
// Usage:
//   Terminal 1: node lesson-05.js api 3000
//   Terminal 2: node lesson-05.js worker 3001
//   Terminal 3: node lesson-05.js cache 6379
```

---

## Network Presence Heartbeat System

A heartbeat system extends the discovery protocol with liveness detection. Each node sends periodic heartbeats containing health metrics. Peers track three states: `alive`, `suspected` (missed 2+ heartbeats), and `dead` (missed 4+ heartbeats).

```javascript
'use strict';

const dgram = require('node:dgram');
const os = require('node:os');
const crypto = require('node:crypto');

const HEARTBEAT_GROUP = '239.10.20.31';
const HEARTBEAT_PORT = 41241;
const INTERVAL_MS = 2000;
const DEAD_THRESHOLD_MS = 8000; // 4 missed heartbeats

function createHeartbeatNode(role) {
  const nodeId = crypto.randomBytes(4).toString('hex');
  const startTime = Date.now();
  const peers = new Map();

  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.bind(HEARTBEAT_PORT, () => {
    socket.addMembership(HEARTBEAT_GROUP);
    socket.setMulticastTTL(1);
    socket.setMulticastLoopback(true);
    console.log(`[${nodeId}] Heartbeat node started (role: ${role})`);
  });

  // Send heartbeats with health metrics
  const heartbeatTimer = setInterval(() => {
    const msg = JSON.stringify({
      id: nodeId, role,
      uptime: Math.floor((Date.now() - startTime) / 1000),
      memoryMB: Math.floor(process.memoryUsage().rss / 1024 / 1024),
      load: os.loadavg()[0].toFixed(2),
      ts: Date.now(),
    });
    socket.send(msg, HEARTBEAT_PORT, HEARTBEAT_GROUP);
  }, INTERVAL_MS);

  // Receive and track peer heartbeats
  socket.on('message', (msg) => {
    try {
      const data = JSON.parse(msg.toString());
      if (data.id === nodeId) return;

      const prev = peers.get(data.id);
      peers.set(data.id, { ...data, lastSeen: Date.now(), status: 'alive' });

      if (!prev) console.log(`[${nodeId}] NEW: ${data.id} (${data.role})`);
      else if (prev.status === 'suspected') console.log(`[${nodeId}] RECOVERED: ${data.id}`);
    } catch { /* ignore malformed */ }
  });

  // Detect failures: suspected after 2x interval, dead after threshold
  const healthTimer = setInterval(() => {
    const now = Date.now();
    for (const [id, peer] of peers) {
      const elapsed = now - peer.lastSeen;
      if (elapsed > DEAD_THRESHOLD_MS && peer.status !== 'dead') {
        peer.status = 'dead';
        console.log(`[${nodeId}] DEAD: ${id} (${peer.role}) — ${(elapsed / 1000).toFixed(1)}s`);
      } else if (elapsed > INTERVAL_MS * 2 && peer.status === 'alive') {
        peer.status = 'suspected';
        console.log(`[${nodeId}] SUSPECTED: ${id} (${peer.role})`);
      }
    }
  }, INTERVAL_MS);

  process.on('SIGINT', () => {
    clearInterval(heartbeatTimer);
    clearInterval(healthTimer);
    socket.dropMembership(HEARTBEAT_GROUP);
    socket.close();
    process.exit(0);
  });
}

createHeartbeatNode(process.argv[2] || 'node');
// Run 3 terminals:  node heartbeat.js primary | worker | cache
// Kill one and watch the others detect the failure
```

---

## Packet Fragmentation Awareness

UDP datagrams above the network's MTU (Maximum Transmission Unit, typically 1500 bytes for Ethernet) are fragmented by the IP layer. If any fragment is lost, the entire datagram is dropped.

```javascript
'use strict';

// Maximum safe UDP payload sizes:
//
// Ethernet MTU:          1500 bytes
// - IP header:             20 bytes
// - UDP header:             8 bytes
// = Safe UDP payload:    1472 bytes (no fragmentation on Ethernet)
//
// IPv6 minimum MTU:      1280 bytes
// - IPv6 header:           40 bytes
// - UDP header:             8 bytes
// = Safe IPv6 payload:   1232 bytes
//
// Max theoretical UDP:  65,507 bytes (65,535 - 20 - 8)
// But anything above MTU fragments, and one lost fragment drops the whole datagram.
//
// Rule of thumb: keep UDP payloads under 1400 bytes for safe cross-network delivery.
// For multicast discovery and heartbeat protocols, messages are typically < 500 bytes.
```

---

## Raw TCP with Manual Protocol Framing

When you need full control over a TCP protocol — custom framing, binary headers, or non-standard message formats — `net.createServer` with manual buffer management is the tool. TCP is a byte stream with no message boundaries, so you must implement your own framing.

```javascript
'use strict';

const net = require('node:net');

// Custom binary protocol: [4B type][4B length][payload]
const MSG_PING = 1, MSG_DATA = 2, MSG_CLOSE = 3;
const HEADER_SIZE = 8;

function encode(type, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const hdr = Buffer.alloc(HEADER_SIZE);
  hdr.writeUInt32BE(type, 0);
  hdr.writeUInt32BE(body.length, 4);
  return Buffer.concat([hdr, body]);
}

function parseMessages(buffer, handler) {
  while (buffer.length >= HEADER_SIZE) {
    const type = buffer.readUInt32BE(0);
    const len = buffer.readUInt32BE(4);
    if (buffer.length < HEADER_SIZE + len) break;
    const payload = buffer.subarray(HEADER_SIZE, HEADER_SIZE + len);
    buffer = buffer.subarray(HEADER_SIZE + len);
    handler(type, payload);
  }
  return buffer; // Return unconsumed bytes
}

const server = net.createServer((socket) => {
  let buf = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    buf = parseMessages(buf, (type, payload) => {
      switch (type) {
        case MSG_PING:
          socket.write(encode(MSG_PING, 'PONG'));
          break;
        case MSG_DATA:
          socket.write(encode(MSG_DATA, `ACK: ${payload}`));
          break;
        case MSG_CLOSE:
          socket.write(encode(MSG_CLOSE, 'BYE'));
          socket.end();
          break;
      }
    });
  });
});

server.listen(8010, () => {
  console.log('Protocol server on port 8010');

  // Client sends PING, DATA, then CLOSE
  const client = net.connect(8010, () => {
    client.write(encode(MSG_PING, ''));
    setTimeout(() => client.write(encode(MSG_DATA, 'Hello, protocol!')), 100);
    setTimeout(() => client.write(encode(MSG_CLOSE, '')), 200);
  });

  let cbuf = Buffer.alloc(0);
  client.on('data', (chunk) => {
    cbuf = Buffer.concat([cbuf, chunk]);
    cbuf = parseMessages(cbuf, (type, payload) => {
      const name = { [MSG_PING]: 'PING', [MSG_DATA]: 'DATA', [MSG_CLOSE]: 'CLOSE' }[type];
      console.log(`[Client] ${name}: ${payload}`);
    });
  });

  client.on('end', () => {
    console.log('[Client] Disconnected');
    server.close();
  });
});
```

The key pattern is the `parseMessages` function: accumulate bytes in a buffer, extract complete messages in a loop, and return the leftover bytes. This handles TCP's arbitrary packet boundaries correctly.

---

## Key Takeaways

- `node:dgram` provides full UDP support including multicast (`addMembership`, `setMulticastTTL`) and broadcast (`setBroadcast(true)`) — capabilities that TCP fundamentally cannot offer
- UDP multicast enables one-to-many communication where the sender transmits once and the network delivers to all group members — ideal for service discovery, log distribution, and real-time data feeds
- Socket options `reuseAddr` and `reusePort` control kernel-level socket behavior: `reuseAddr` prevents `EADDRINUSE` during rapid restarts, and `reusePort` enables multiple processes to share a single port for load distribution
- UDP payloads above the network MTU (typically 1472 bytes for Ethernet) are fragmented at the IP layer, and any lost fragment drops the entire datagram — keep payloads below MTU for reliable delivery
- Building network presence and service discovery systems requires three components: periodic announcements (heartbeats), peer tracking with expiration, and health status transitions (alive, suspected, dead) — all achievable with multicast and fewer than 150 lines of Node.js

## Next

This is the final lesson in Track 03 — Systems Programming. You now have the tools to write native addons, communicate over Unix sockets, share memory between threads, pass file descriptors between processes, and work with raw network primitives. Return to the main course or explore another specialized track to continue deepening your Node.js expertise.
