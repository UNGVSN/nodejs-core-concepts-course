# Module 06 / Lesson 03 — TCP Protocol Deep Dive

> TCP turns an unreliable, best-effort network into a reliable, ordered byte stream. This lesson explains the machinery that makes that transformation possible — from the three-way handshake that opens a connection to the four-way teardown that closes it.

---

## Learning Objectives

- Trace the TCP three-way handshake (SYN, SYN-ACK, ACK) and explain the purpose of each step
- Explain how sequence numbers and acknowledgment numbers guarantee ordered, reliable delivery
- Describe TCP flow control using the sliding window mechanism
- Describe TCP congestion control and the algorithms that prevent network collapse
- Trace the four-way FIN teardown and explain the TIME_WAIT state

---

## What TCP Guarantees

TCP (Transmission Control Protocol) provides four guarantees that UDP does not:

1. **Reliable delivery** — Every byte you send arrives at the destination, or you get an error. TCP detects lost segments and retransmits them.
2. **Ordered delivery** — Bytes arrive in the exact order they were sent, even if the underlying packets arrive out of order.
3. **Error detection** — TCP checksums catch corrupted data. Damaged segments are discarded and retransmitted.
4. **Flow control** — The sender will not overwhelm a slow receiver.

These guarantees come at a cost: connection establishment overhead, higher latency, and head-of-line blocking. But for most server-to-server and client-to-server communication, the trade-off is worth it.

---

## The TCP Header

Every TCP segment carries a header with critical fields:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Sequence Number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Acknowledgment Number                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Data |           |U|A|P|R|S|F|                               |
| Offset| Reserved  |R|C|S|S|Y|I|            Window             |
|       |           |G|K|H|T|N|N|                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Checksum            |         Urgent Pointer        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

The fields that matter most for this lesson:

| Field | Size | Purpose |
|-------|------|---------|
| Source Port | 16 bits | Sender's port number |
| Destination Port | 16 bits | Receiver's port number |
| Sequence Number | 32 bits | Position of the first byte in this segment within the overall stream |
| Acknowledgment Number | 32 bits | The next byte the sender expects to receive from the other side |
| Flags (SYN, ACK, FIN, RST, PSH) | 1 bit each | Control the connection lifecycle and behavior |
| Window | 16 bits | How many bytes the sender is willing to receive (flow control) |

---

## The Three-Way Handshake

Every TCP connection begins with a three-way handshake. This process synchronizes sequence numbers and establishes the connection in both directions.

### Step 1: SYN (Client to Server)

The client picks a random **Initial Sequence Number** (ISN) and sends a segment with the SYN flag set.

```
Client → Server:  SYN, Seq=1000
```

The client is saying: "I want to connect. My starting sequence number is 1000."

### Step 2: SYN-ACK (Server to Client)

The server picks its own ISN and responds with both the SYN and ACK flags set:

```
Server → Client:  SYN+ACK, Seq=5000, Ack=1001
```

The server is saying: "I accept your connection. My starting sequence number is 5000. I have received your bytes up to 1000, so I expect byte 1001 next."

### Step 3: ACK (Client to Server)

The client acknowledges the server's SYN:

```
Client → Server:  ACK, Seq=1001, Ack=5001
```

The client is saying: "I acknowledge your sequence number. I expect byte 5001 next."

After this exchange, the connection is **ESTABLISHED** on both sides.

### Observing the Handshake in Node.js

You cannot see raw TCP flags from JavaScript, but you can observe the timing:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // This callback fires AFTER the three-way handshake completes.
  // The kernel handled SYN, SYN-ACK, ACK before Node.js even knew about it.
  console.log(`[server] Connection established from ${socket.remoteAddress}:${socket.remotePort}`);

  socket.on('data', (data) => {
    console.log(`[server] Received: ${data}`);
    socket.write('acknowledged\n');
  });

  socket.on('end', () => {
    console.log('[server] Client ended connection');
  });
});

server.listen(4000, () => {
  console.log('[server] Listening on port 4000');

  const connectStart = Date.now();

  const client = net.createConnection({ port: 4000 }, () => {
    // The 'connect' event fires after the handshake completes
    const handshakeMs = Date.now() - connectStart;
    console.log(`[client] Connected in ${handshakeMs}ms (includes 3-way handshake)`);

    client.write('hello\n');
  });

  client.on('data', (data) => {
    console.log(`[client] Received: ${data}`);
    client.end();
  });

  client.on('close', () => server.close());
});
```

On localhost, the handshake completes in under a millisecond. Over a WAN with 50ms latency, it takes at least 1.5 round trips (~75ms). This is why TCP has "connection overhead" — every new connection pays this cost before any data flows.

### The Backlog Queue

When the kernel receives a SYN, it places the half-open connection in the **SYN queue**. When the handshake completes, the connection moves to the **accept queue**. Node.js reads from the accept queue when it invokes the connection callback.

The `backlog` parameter on `server.listen()` controls the size of the accept queue:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.end('hello\n');
});

// The second argument to listen is the backlog (default: 511 on most systems)
server.listen(4000, 511, () => {
  console.log('Listening with backlog of 511');
});
```

If the accept queue is full, the kernel silently drops incoming SYN packets (the client will retry). This is one reason a slow application can cause connection timeouts without any visible error — the server process is not rejecting connections; it is simply too slow to accept them.

---

## Sequence Numbers and Acknowledgments

Once the handshake completes, every byte in the stream has a sequence number. TCP uses these to guarantee ordering and detect loss.

### How It Works

Suppose the client sends 100 bytes starting at sequence number 1001:

```
Client → Server:  Seq=1001, Len=100, Data=[100 bytes]
```

The server acknowledges by setting the ACK number to the next byte it expects:

```
Server → Client:  Ack=1101
```

This means: "I have received all bytes up to 1100. Send me byte 1101 next."

### Retransmission

If the server does not acknowledge within a timeout (the **Retransmission Timeout**, or RTO), the client resends the segment. The RTO is dynamically calculated based on measured round-trip times.

```
Client → Server:  Seq=1001, Len=100, Data=[100 bytes]
  ... packet lost ...
  (RTO expires)
Client → Server:  Seq=1001, Len=100, Data=[100 bytes]  (retransmit)
Server → Client:  Ack=1101
```

### Duplicate ACKs and Fast Retransmit

If the server receives segments out of order, it sends **duplicate ACKs** for the missing segment. After three duplicate ACKs, the client retransmits immediately without waiting for the RTO — this is called **fast retransmit**.

```
Client → Server:  Seq=1001, Len=100   (received)
Client → Server:  Seq=1101, Len=100   (LOST)
Client → Server:  Seq=1201, Len=100   (received, but 1101 is missing)
Server → Client:  Ack=1101             (duplicate ACK #1 — still waiting for 1101)
Client → Server:  Seq=1301, Len=100   (received, but 1101 still missing)
Server → Client:  Ack=1101             (duplicate ACK #2)
Client → Server:  Seq=1401, Len=100   (received)
Server → Client:  Ack=1101             (duplicate ACK #3 — triggers fast retransmit)
Client → Server:  Seq=1101, Len=100   (retransmit!)
Server → Client:  Ack=1501             (caught up — received everything through 1500)
```

---

## Flow Control — The Sliding Window

Flow control prevents the sender from overwhelming the receiver. Each side advertises a **window size** — the number of bytes it is willing to accept before requiring an acknowledgment.

### The Receive Window

When the server sends an ACK, it includes a window size:

```
Server → Client:  Ack=1101, Window=16384
```

This means: "I can accept 16,384 bytes starting from byte 1101." The client must not send more than this amount of unacknowledged data.

### Window Scaling

The TCP header's window field is only 16 bits, limiting it to 65,535 bytes. Modern TCP connections use the **Window Scale** option (negotiated during the handshake) to multiply the window by a power of 2. A scale factor of 7 gives a maximum window of 65,535 x 128 = 8,388,480 bytes (~8 MB).

### Zero Window

If the receiver's buffer is full, it advertises a window of zero. The sender stops sending and periodically sends **window probes** (tiny segments) to check if the receiver has freed up space.

### Relation to Node.js Backpressure

This is the kernel-level mechanism behind the backpressure you learned about in Module 05. When a Node.js process does not read from a socket fast enough, the kernel's receive buffer fills up, the window shrinks to zero, and the sender pauses. When your code resumes reading, the buffer drains, the window opens, and data flows again.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Simulate a slow consumer — do not read for 2 seconds
  socket.pause();
  console.log('[server] Paused reading — receive window will shrink');

  setTimeout(() => {
    console.log('[server] Resuming reading — receive window will open');
    socket.resume();
    socket.on('data', (chunk) => {
      console.log(`[server] Received ${chunk.length} bytes`);
    });
    socket.on('end', () => {
      console.log('[server] Client done sending');
      server.close();
    });
  }, 2000);
});

server.listen(4000, () => {
  const client = net.createConnection({ port: 4000 }, () => {
    // Write a lot of data — eventually the kernel will tell us to pause
    let bytesWritten = 0;

    function writeMore() {
      let ok = true;
      while (ok) {
        ok = client.write(Buffer.alloc(16384, 0x41)); // 16 KB chunks
        bytesWritten += 16384;
      }
      // write() returned false — the kernel buffer is full (backpressure)
      console.log(`[client] Backpressure after ${bytesWritten} bytes`);
      client.once('drain', () => {
        console.log('[client] Drain event — can write again');
        client.end();
      });
    }

    writeMore();
  });
});
```

---

## Congestion Control

Flow control protects the receiver. **Congestion control** protects the network. TCP adjusts its sending rate based on detected packet loss to avoid overwhelming intermediate routers.

### Congestion Window (cwnd)

Each TCP connection maintains a **congestion window** — the maximum number of unacknowledged bytes in flight. The actual sending window is the minimum of the congestion window and the receiver's advertised window.

```
effective_window = min(cwnd, receiver_window)
```

### Slow Start

A new connection starts with a small congestion window (typically 10 segments = ~14 KB on modern systems). For every ACK received, the window doubles. This is **exponential growth** — called "slow start" because it starts slow, even though it ramps up quickly.

```
cwnd = 1 segment   → send 1 segment, receive 1 ACK
cwnd = 2 segments  → send 2 segments, receive 2 ACKs
cwnd = 4 segments  → send 4 segments, receive 4 ACKs
cwnd = 8 segments  → ...
```

This continues until either: the window hits the **slow start threshold** (ssthresh), or a packet is lost.

### Congestion Avoidance

Once cwnd reaches ssthresh, TCP switches to **congestion avoidance**: the window grows by one segment per round trip instead of doubling. This is linear growth — cautious probing for available bandwidth.

### Loss Detection and Recovery

When TCP detects a loss (via timeout or three duplicate ACKs):

1. **ssthresh** is set to half the current cwnd
2. **cwnd** is reduced (to 1 for timeout, to ssthresh for fast retransmit)
3. TCP restarts the growth process

### Why This Matters for Node.js

Congestion control explains several behaviors you will encounter:

- **Slow first requests**: A new TCP connection starts with a small window. The first HTTP response on a new connection is slower than subsequent responses because the window has not ramped up yet. This is why HTTP/1.1 keep-alive and HTTP/2 multiplexing exist — they reuse connections with warmed-up windows.
- **Throughput drops after packet loss**: If a router drops a packet, TCP slashes its sending rate. A single dropped packet can halve throughput temporarily.
- **Long-distance connections are slower**: The round-trip time (RTT) limits how fast the congestion window can grow. A 200ms RTT connection takes longer to ramp up than a 2ms RTT connection.

---

## The Four-Way FIN Teardown

Closing a TCP connection requires four segments because each side must close independently.

### The Steps

```
Client → Server:  FIN, Seq=5000
Server → Client:  ACK, Ack=5001
  (Server may continue sending data here — "half-close" state)
Server → Client:  FIN, Seq=8000
Client → Server:  ACK, Ack=8001
```

1. **Client sends FIN**: "I am done sending data."
2. **Server sends ACK**: "I acknowledge your FIN." The server can still send data.
3. **Server sends FIN**: "I am done sending data too."
4. **Client sends ACK**: "I acknowledge your FIN." Connection is now fully closed.

### Half-Close in Node.js

Node.js supports TCP half-close through the `allowHalfOpen` option:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer({ allowHalfOpen: true }, (socket) => {
  socket.on('end', () => {
    // Client sent FIN — but the socket is still writable
    console.log('[server] Client ended their side');
    console.log('[server] Socket still writable:', socket.writable); // true

    // Send final data, then close our side
    socket.end('here is your response after you closed your end\n');
  });

  socket.on('data', (data) => {
    console.log(`[server] Received: ${data}`);
  });
});

server.listen(4000, () => {
  const client = net.createConnection({ port: 4000 }, () => {
    client.write('request data\n');
    client.end(); // Send FIN — but we can still read!
  });

  client.on('data', (data) => {
    console.log(`[client] Received after our FIN: ${data}`);
  });

  client.on('close', () => server.close());
});
```

Without `allowHalfOpen: true`, Node.js automatically calls `socket.end()` when it receives a FIN from the remote side, closing both directions immediately.

### TIME_WAIT

After the final ACK, the side that initiated the close enters **TIME_WAIT** for 2x the Maximum Segment Lifetime (MSL), typically 60 seconds on Linux. This prevents delayed packets from a previous connection being mistakenly accepted by a new connection on the same port.

TIME_WAIT is why you see `EADDRINUSE` when quickly restarting a server. The old socket is in TIME_WAIT, holding the port. The fix:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.end('hello\n');
});

// SO_REUSEADDR allows binding to a port in TIME_WAIT
// Node.js enables this by default for net.Server — but not for all platforms equally
server.listen(4000, () => {
  console.log('Listening on 4000 (SO_REUSEADDR enabled by default)');
});
```

---

## Nagle's Algorithm and TCP_NODELAY

Nagle's algorithm batches small writes into larger segments to reduce the number of packets on the network. It holds a small write if there is already an unacknowledged segment in flight.

This is efficient for bulk transfers but adds latency to interactive protocols:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  socket.on('data', (data) => {
    console.log(`Received: ${data.length} bytes`);
  });

  socket.on('end', () => server.close());
});

server.listen(4000, () => {
  const client = net.createConnection({ port: 4000 }, () => {
    // With Nagle ON (default), these small writes may be batched
    client.write('a');
    client.write('b');
    client.write('c');

    // To send each write immediately:
    // client.setNoDelay(true);
    // Now each write() sends its own TCP segment

    setTimeout(() => client.end(), 100);
  });
});
```

Use `socket.setNoDelay(true)` for latency-sensitive protocols. Keep Nagle enabled for throughput-sensitive bulk transfers. See DECISIONS.md for the full trade-off analysis.

---

## TCP Segment Size and MSS

The **Maximum Segment Size** (MSS) is the largest amount of data (in bytes) that a TCP segment can carry. It is negotiated during the handshake via TCP options.

MSS = MTU - IP header (20 bytes) - TCP header (20 bytes)

For a standard Ethernet MTU of 1500 bytes:

```
MSS = 1500 - 20 - 20 = 1460 bytes
```

When you call `socket.write(Buffer.alloc(100000))` in Node.js, the kernel splits that into roughly 69 segments of 1460 bytes each. This segmentation is invisible to your JavaScript code — you just see the bytes flow.

---

## Key Takeaways

- The three-way handshake (SYN, SYN-ACK, ACK) establishes a TCP connection by synchronizing sequence numbers between client and server.
- Sequence numbers and acknowledgments guarantee reliable, ordered delivery; lost segments are retransmitted automatically.
- Flow control (the sliding window) prevents the sender from overwhelming the receiver; this is the kernel-level mechanism behind Node.js stream backpressure.
- Congestion control (slow start, congestion avoidance) prevents TCP from overwhelming the network; it explains why new connections start slow.
- The four-way FIN teardown closes the connection; TIME_WAIT prevents port reuse conflicts; `allowHalfOpen` gives you control over half-close behavior in Node.js.

---

## Next

Continue to [Lesson 04 — UDP Protocol & Datagrams](lesson-04-udp-datagrams.md) to explore the other side of the transport layer — connectionless, unreliable, fast communication with `node:dgram`.
