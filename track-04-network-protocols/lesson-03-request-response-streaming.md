# Track 04 / Lesson 03 — Request-Response & Streaming Protocols

> A single TCP connection is a bidirectional byte stream. Most developers use it as a half-duplex pipe: send a request, wait for a response, send the next request. But HTTP/2 sends hundreds of requests simultaneously on one connection, interleaving their frames. This lesson teaches you how to build that kind of multiplexed protocol from scratch.

## Learning Objectives

- Implement correlation IDs that match responses to requests on a multiplexed connection where messages arrive out of order
- Build a multiplexer that interleaves multiple logical streams on a single TCP connection using stream IDs and frame types
- Implement request pipelining where the client sends N requests without waiting for any response, and the server processes them concurrently
- Design bidirectional streaming where both client and server push data simultaneously without a strict request-response pattern
- Apply flow control at the protocol level using backpressure signals and receive window advertisements

---

## The Problem: Head-of-Line Blocking

In a naive request-response protocol, the client sends a request and waits for the response before sending the next one. If request #2 takes 500ms, request #3 waits even though the server could process it immediately.

```
Client                   Server
  |--- Request 1 -------->|
  |                        | (processing 10ms)
  |<------ Response 1 ----|
  |--- Request 2 -------->|
  |                        | (processing 500ms)  <-- everything waits
  |<------ Response 2 ----|
  |--- Request 3 -------->|
  |                        | (processing 5ms)
  |<------ Response 3 ----|

Total: 515ms sequential
```

With multiplexing, all three requests fly concurrently:

```
Client                   Server
  |--- Request 1 -------->|
  |--- Request 2 -------->|  (all sent immediately)
  |--- Request 3 -------->|
  |                        | (processing all three)
  |<------ Response 3 ----|  (5ms — arrives first)
  |<------ Response 1 ----|  (10ms)
  |<------ Response 2 ----|  (500ms)

Total: 500ms (limited only by the slowest request)
```

---

## Correlation IDs

The foundation of multiplexing is the correlation ID: a unique identifier attached to every request that the server echoes back in the response. The client uses it to match responses to their originating requests.

```javascript
'use strict';

const crypto = require('node:crypto');

class PendingRequests {
  constructor() {
    this.pending = new Map(); // correlationId -> { resolve, reject, timer }
  }

  // Register a new request and return a Promise that resolves with the response
  register(timeoutMs = 5000) {
    const correlationId = crypto.randomUUID();

    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(correlationId);
        reject(new Error(`Request ${correlationId} timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      // Do not let the timer block process exit
      timer.unref();

      this.pending.set(correlationId, { resolve, reject, timer });
    });

    return { correlationId, promise };
  }

  // Resolve a pending request when the response arrives
  resolve(correlationId, response) {
    const entry = this.pending.get(correlationId);
    if (!entry) {
      console.warn(`No pending request for correlation ID: ${correlationId}`);
      return false;
    }

    clearTimeout(entry.timer);
    this.pending.delete(correlationId);
    entry.resolve(response);
    return true;
  }

  // Reject a pending request on error
  reject(correlationId, error) {
    const entry = this.pending.get(correlationId);
    if (!entry) return false;

    clearTimeout(entry.timer);
    this.pending.delete(correlationId);
    entry.reject(error);
    return true;
  }

  // Reject all pending requests (connection lost)
  rejectAll(error) {
    for (const [id, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    this.pending.clear();
  }

  get size() {
    return this.pending.size;
  }
}

// Demo
async function demo() {
  const pending = new PendingRequests();

  // Simulate sending 3 requests
  const req1 = pending.register(3000);
  const req2 = pending.register(3000);
  const req3 = pending.register(3000);

  console.log('Pending requests:', pending.size);

  // Simulate responses arriving out of order
  setTimeout(() => pending.resolve(req3.correlationId, { data: 'response 3' }), 50);
  setTimeout(() => pending.resolve(req1.correlationId, { data: 'response 1' }), 100);
  setTimeout(() => pending.resolve(req2.correlationId, { data: 'response 2' }), 200);

  const results = await Promise.all([req1.promise, req2.promise, req3.promise]);
  console.log('All responses received:', results);
}

demo().catch(console.error);
```

The `PendingRequests` class is the client-side bookkeeping that makes multiplexing possible. Without it, the client cannot match responses to requests when they arrive out of order.

---

## Building a Multiplexed RPC Protocol

A multiplexed protocol assigns a stream ID to each logical conversation and interleaves frames from different streams on the same TCP connection.

### Frame Format

```
+----------+----------+----------+---------+---------+
| StreamID | FrameType| Length   | Payload | (no CRC |
| 4 bytes  | 1 byte   | 4 bytes  | N bytes |  here)  |
+----------+----------+----------+---------+---------+
```

```javascript
'use strict';

const net = require('node:net');
const crypto = require('node:crypto');

// Frame types
const FRAME = {
  REQUEST:   0x01,
  RESPONSE:  0x02,
  ERROR:     0x03,
  DATA:      0x04, // Streaming data frame
  END:       0x05, // End of stream
  PING:      0x06,
  PONG:      0x07,
};

const FRAME_HEADER_SIZE = 9; // 4 (streamId) + 1 (type) + 4 (length)
const MAX_FRAME_PAYLOAD = 1024 * 1024; // 1 MB

// --- Encoder ---
function encodeFrame(streamId, type, payload) {
  const payloadBuf = Buffer.isBuffer(payload)
    ? payload
    : Buffer.from(payload || '', 'utf8');

  const frame = Buffer.alloc(FRAME_HEADER_SIZE + payloadBuf.length);
  frame.writeUInt32BE(streamId, 0);
  frame.writeUInt8(type, 4);
  frame.writeUInt32BE(payloadBuf.length, 5);
  payloadBuf.copy(frame, FRAME_HEADER_SIZE);

  return frame;
}

// --- Decoder ---
class FrameDecoder {
  constructor() {
    this.buffer = Buffer.alloc(0);
  }

  feed(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const frames = [];

    while (this.buffer.length >= FRAME_HEADER_SIZE) {
      const payloadLength = this.buffer.readUInt32BE(5);

      if (payloadLength > MAX_FRAME_PAYLOAD) {
        throw new Error(`Frame payload too large: ${payloadLength}`);
      }

      const totalSize = FRAME_HEADER_SIZE + payloadLength;
      if (this.buffer.length < totalSize) break;

      frames.push({
        streamId: this.buffer.readUInt32BE(0),
        type: this.buffer.readUInt8(4),
        payload: this.buffer.subarray(FRAME_HEADER_SIZE, totalSize),
      });

      this.buffer = this.buffer.subarray(totalSize);
    }

    return frames;
  }
}
```

---

## Multiplexed RPC Server

The server receives frames from multiple streams interleaved on the same connection and processes each stream independently.

```javascript
'use strict';

const net = require('node:net');

// (FRAME, FRAME_HEADER_SIZE, encodeFrame, FrameDecoder defined above)

function createRPCServer(port, handler) {
  const server = net.createServer((socket) => {
    const decoder = new FrameDecoder();
    const addr = `${socket.remoteAddress}:${socket.remotePort}`;

    console.log(`[server] ${addr} connected`);

    socket.on('data', (chunk) => {
      let frames;
      try {
        frames = decoder.feed(chunk);
      } catch (err) {
        console.error(`[server] decode error: ${err.message}`);
        socket.destroy();
        return;
      }

      for (const frame of frames) {
        if (frame.type === FRAME.PING) {
          socket.write(encodeFrame(frame.streamId, FRAME.PONG, Buffer.alloc(0)));
          continue;
        }

        if (frame.type === FRAME.REQUEST) {
          const requestBody = frame.payload.toString('utf8');

          // Process the request asynchronously
          handler(requestBody)
            .then((result) => {
              const responsePayload = Buffer.from(JSON.stringify(result), 'utf8');
              socket.write(encodeFrame(frame.streamId, FRAME.RESPONSE, responsePayload));
            })
            .catch((err) => {
              const errorPayload = Buffer.from(JSON.stringify({ error: err.message }), 'utf8');
              socket.write(encodeFrame(frame.streamId, FRAME.ERROR, errorPayload));
            });
        }
      }
    });

    socket.on('close', () => console.log(`[server] ${addr} disconnected`));
    socket.on('error', (err) => console.error(`[server] ${addr} error: ${err.message}`));
  });

  server.listen(port, () => console.log(`[server] RPC server on :${port}`));
  return server;
}

// Example handler — simulates variable processing time
async function echoHandler(body) {
  const request = JSON.parse(body);
  const delay = Math.floor(Math.random() * 200);
  await new Promise((r) => setTimeout(r, delay));
  return { echo: request, processedIn: `${delay}ms` };
}

createRPCServer(6000, echoHandler);
```

---

## Multiplexed RPC Client

The client assigns a unique stream ID to each request, sends all requests without waiting, and matches responses using stream IDs.

```javascript
'use strict';

const net = require('node:net');

// (FRAME, encodeFrame, FrameDecoder defined above)

class RPCClient {
  constructor(host, port) {
    this.host = host;
    this.port = port;
    this.nextStreamId = 1;
    this.pending = new Map(); // streamId -> { resolve, reject, timer }
    this.socket = null;
    this.decoder = new FrameDecoder();
    this.connected = false;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection({ host: this.host, port: this.port }, () => {
        this.connected = true;
        resolve();
      });

      this.socket.on('data', (chunk) => this.handleData(chunk));

      this.socket.on('close', () => {
        this.connected = false;
        // Reject all pending requests
        for (const [id, entry] of this.pending) {
          clearTimeout(entry.timer);
          entry.reject(new Error('Connection closed'));
        }
        this.pending.clear();
      });

      this.socket.on('error', (err) => {
        if (!this.connected) reject(err);
      });
    });
  }

  handleData(chunk) {
    let frames;
    try {
      frames = this.decoder.feed(chunk);
    } catch (err) {
      console.error('[client] decode error:', err.message);
      return;
    }

    for (const frame of frames) {
      const entry = this.pending.get(frame.streamId);
      if (!entry) {
        console.warn(`[client] unexpected stream ID: ${frame.streamId}`);
        continue;
      }

      clearTimeout(entry.timer);
      this.pending.delete(frame.streamId);

      if (frame.type === FRAME.RESPONSE) {
        entry.resolve(JSON.parse(frame.payload.toString('utf8')));
      } else if (frame.type === FRAME.ERROR) {
        entry.reject(new Error(frame.payload.toString('utf8')));
      }
    }
  }

  call(method, params, timeoutMs = 5000) {
    if (!this.connected) {
      return Promise.reject(new Error('Not connected'));
    }

    const streamId = this.nextStreamId++;
    const body = JSON.stringify({ method, params });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(streamId);
        reject(new Error(`Stream ${streamId} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      timer.unref();

      this.pending.set(streamId, { resolve, reject, timer });
      this.socket.write(encodeFrame(streamId, FRAME.REQUEST, body));
    });
  }

  close() {
    if (this.socket) {
      this.socket.end();
    }
  }
}

// --- Demo: send 10 concurrent requests ---
async function demo() {
  const client = new RPCClient('127.0.0.1', 6000);
  await client.connect();
  console.log('[client] connected');

  const startTime = Date.now();

  // Fire 10 requests concurrently — no waiting between them
  const promises = [];
  for (let i = 1; i <= 10; i++) {
    promises.push(
      client.call('echo', { message: `request #${i}` })
        .then((res) => {
          console.log(`[client] response for #${i}:`, res.processedIn);
          return res;
        })
    );
  }

  const results = await Promise.all(promises);
  const elapsed = Date.now() - startTime;

  console.log(`[client] All ${results.length} responses in ${elapsed}ms`);
  console.log('[client] (Sequential would have taken ~1000ms on average)');

  client.close();
}

demo().catch(console.error);
```

---

## Request Pipelining

Pipelining is a simpler form of multiplexing: the client sends multiple requests in order and the server responds in the same order. No correlation IDs needed — ordering is guaranteed.

```javascript
'use strict';

const net = require('node:net');

// Pipelining: FIFO ordering — responses arrive in the same order as requests

class PipelinedClient {
  constructor(host, port) {
    this.host = host;
    this.port = port;
    this.responseQueue = []; // Ordered queue of { resolve, reject }
    this.decoder = new FrameDecoder();
    this.socket = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection({ host: this.host, port: this.port }, () => {
        resolve();
      });

      this.socket.on('data', (chunk) => {
        const frames = this.decoder.feed(chunk);

        for (const frame of frames) {
          const entry = this.responseQueue.shift();
          if (!entry) {
            console.error('[pipeline] Unexpected response — no pending request');
            continue;
          }

          if (frame.type === FRAME.RESPONSE) {
            entry.resolve(JSON.parse(frame.payload.toString('utf8')));
          } else {
            entry.reject(new Error(frame.payload.toString('utf8')));
          }
        }
      });

      this.socket.on('error', (err) => {
        if (this.responseQueue.length === 0) reject(err);
      });
    });
  }

  send(data) {
    return new Promise((resolve, reject) => {
      this.responseQueue.push({ resolve, reject });
      const payload = Buffer.from(JSON.stringify(data), 'utf8');
      // Stream ID 0 for pipelined (order-based) protocol
      this.socket.write(encodeFrame(0, FRAME.REQUEST, payload));
    });
  }

  close() {
    this.socket.end();
  }
}

// Demo
async function pipelineDemo() {
  const client = new PipelinedClient('127.0.0.1', 6000);
  await client.connect();

  // Pipeline 5 requests — all sent before any response arrives
  const results = await Promise.all([
    client.send({ cmd: 'GET', key: 'user:1' }),
    client.send({ cmd: 'GET', key: 'user:2' }),
    client.send({ cmd: 'SET', key: 'user:3', value: 'alice' }),
    client.send({ cmd: 'GET', key: 'user:3' }),
    client.send({ cmd: 'DEL', key: 'user:1' }),
  ]);

  console.log('Pipeline results:', results);
  client.close();
}

// pipelineDemo().catch(console.error);
```

**Pipelining vs. multiplexing:** Pipelining is simpler (no stream IDs, FIFO ordering) but suffers from head-of-line blocking — a slow response delays all subsequent responses. Multiplexing allows out-of-order responses but requires correlation IDs.

---

## Bidirectional Streaming

Both sides send data simultaneously without a strict request-response pattern. Each side has its own stream of messages. This is how gRPC bidirectional streaming and WebSocket work.

```javascript
'use strict';

const net = require('node:net');
const { EventEmitter } = require('node:events');

// A bidirectional stream channel on a single TCP connection
class BidirectionalChannel extends EventEmitter {
  constructor(socket, streamId) {
    super();
    this.socket = socket;
    this.streamId = streamId;
    this.ended = false;
  }

  // Send a data frame
  send(data) {
    if (this.ended) throw new Error('Stream already ended');
    const payload = Buffer.from(JSON.stringify(data), 'utf8');
    this.socket.write(encodeFrame(this.streamId, FRAME.DATA, payload));
  }

  // Signal end of stream
  end() {
    if (this.ended) return;
    this.ended = true;
    this.socket.write(encodeFrame(this.streamId, FRAME.END, Buffer.alloc(0)));
    this.emit('localEnd');
  }

  // Called by the connection manager when a frame arrives for this stream
  handleFrame(frame) {
    if (frame.type === FRAME.DATA) {
      const data = JSON.parse(frame.payload.toString('utf8'));
      this.emit('data', data);
    } else if (frame.type === FRAME.END) {
      this.emit('remoteEnd');
    } else if (frame.type === FRAME.ERROR) {
      this.emit('error', new Error(frame.payload.toString('utf8')));
    }
  }
}

// Connection manager that routes frames to the correct channel
class ConnectionManager {
  constructor(socket) {
    this.socket = socket;
    this.channels = new Map();
    this.decoder = new FrameDecoder();

    socket.on('data', (chunk) => {
      const frames = this.decoder.feed(chunk);
      for (const frame of frames) {
        const channel = this.channels.get(frame.streamId);
        if (channel) {
          channel.handleFrame(frame);
        } else {
          // New stream initiated by remote side
          this.emit('newStream', frame);
        }
      }
    });
  }

  createChannel(streamId) {
    const channel = new BidirectionalChannel(this.socket, streamId);
    this.channels.set(streamId, channel);
    return channel;
  }

  removeChannel(streamId) {
    this.channels.delete(streamId);
  }
}

// Inherit EventEmitter for newStream events
Object.setPrototypeOf(ConnectionManager.prototype, EventEmitter.prototype);
```

### Bidirectional Streaming Example: Live Counter

The server pushes incrementing counter values, and the client pushes commands to control the counter.

```javascript
'use strict';

const net = require('node:net');

// Server: push counter updates, accept commands from client
const server = net.createServer((socket) => {
  const mgr = new ConnectionManager(socket);
  const channel = mgr.createChannel(1);

  let counter = 0;
  let running = true;

  // Server pushes counter updates every 200ms
  const interval = setInterval(() => {
    if (!running) return;
    counter++;
    channel.send({ type: 'counter', value: counter });
  }, 200);

  // Server listens for commands from the client
  channel.on('data', (data) => {
    console.log('[server] received command:', data);
    if (data.cmd === 'reset') {
      counter = 0;
      channel.send({ type: 'ack', cmd: 'reset', value: counter });
    } else if (data.cmd === 'pause') {
      running = false;
      channel.send({ type: 'ack', cmd: 'pause' });
    } else if (data.cmd === 'resume') {
      running = true;
      channel.send({ type: 'ack', cmd: 'resume' });
    }
  });

  channel.on('remoteEnd', () => {
    clearInterval(interval);
    console.log('[server] client ended stream');
    channel.end();
    socket.end();
  });

  socket.on('error', () => clearInterval(interval));
  socket.on('close', () => clearInterval(interval));
});

server.listen(6001, () => {
  console.log('[server] bidirectional streaming on :6001');
});
```

---

## Flow Control at the Protocol Level

When the producer is faster than the consumer, data piles up. TCP has built-in flow control (receive window), but protocol-level flow control gives you finer-grained control per stream.

```javascript
'use strict';

const net = require('node:net');

// Protocol-level flow control using WINDOW_UPDATE frames
const FRAME_WINDOW_UPDATE = 0x08;
const INITIAL_WINDOW_SIZE = 64 * 1024; // 64 KB per stream

class FlowControlledStream {
  constructor(socket, streamId, windowSize = INITIAL_WINDOW_SIZE) {
    this.socket = socket;
    this.streamId = streamId;
    this.sendWindow = windowSize;    // How many bytes we can send
    this.receiveWindow = windowSize; // How many bytes we can accept
    this.sendQueue = [];             // Queued frames waiting for window space
    this.totalReceived = 0;
  }

  // Send data, respecting the send window
  send(payload) {
    const payloadBuf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');

    if (payloadBuf.length > this.sendWindow) {
      // Queue the frame — it will be sent when a WINDOW_UPDATE arrives
      this.sendQueue.push(payloadBuf);
      console.log(`[flow] stream ${this.streamId}: queued ${payloadBuf.length} bytes (window=${this.sendWindow})`);
      return false; // Indicates backpressure
    }

    this.sendWindow -= payloadBuf.length;
    this.socket.write(encodeFrame(this.streamId, FRAME.DATA, payloadBuf));
    return true;
  }

  // Called when we receive data — track the receive window
  onDataReceived(payloadLength) {
    this.receiveWindow -= payloadLength;
    this.totalReceived += payloadLength;

    // When window drops below 50%, send a WINDOW_UPDATE to replenish
    if (this.receiveWindow < INITIAL_WINDOW_SIZE / 2) {
      const increment = INITIAL_WINDOW_SIZE - this.receiveWindow;
      this.receiveWindow += increment;

      const updateBuf = Buffer.alloc(4);
      updateBuf.writeUInt32BE(increment, 0);
      this.socket.write(encodeFrame(this.streamId, FRAME_WINDOW_UPDATE, updateBuf));

      console.log(`[flow] stream ${this.streamId}: sent WINDOW_UPDATE +${increment} bytes`);
    }
  }

  // Called when we receive a WINDOW_UPDATE from the peer
  onWindowUpdate(increment) {
    this.sendWindow += increment;
    console.log(`[flow] stream ${this.streamId}: window updated to ${this.sendWindow}`);

    // Drain the send queue
    while (this.sendQueue.length > 0 && this.sendWindow > 0) {
      const queued = this.sendQueue[0];
      if (queued.length > this.sendWindow) break;

      this.sendQueue.shift();
      this.sendWindow -= queued.length;
      this.socket.write(encodeFrame(this.streamId, FRAME.DATA, queued));
      console.log(`[flow] stream ${this.streamId}: drained ${queued.length} bytes from queue`);
    }
  }
}

// Demo: fast producer with flow control
function flowControlDemo() {
  const server = net.createServer((socket) => {
    const stream = new FlowControlledStream(socket, 1);

    // Simulate a fast producer sending 1 KB chunks
    let sent = 0;
    const interval = setInterval(() => {
      const chunk = Buffer.alloc(1024, 0x41); // 1 KB of 'A'
      const ok = stream.send(chunk);
      sent += 1024;

      if (!ok) {
        console.log(`[producer] backpressure at ${sent} bytes — pausing`);
        clearInterval(interval);
      }
    }, 10);

    socket.on('close', () => clearInterval(interval));
    socket.on('error', () => clearInterval(interval));
  });

  server.listen(6002, () => {
    console.log('[flow-control] demo server on :6002');
  });
}

// flowControlDemo();
```

This mirrors HTTP/2's flow control mechanism: each stream has its own window, and the receiver sends `WINDOW_UPDATE` frames to grant more send capacity. This prevents a single fast stream from starving all other streams on the connection.

---

## Multiplexing vs. Multiple Connections

| Aspect                | Multiplexing (1 connection) | Multiple connections |
|-----------------------|-----------------------------|----------------------|
| TCP handshake cost    | Once                        | Once per connection  |
| TLS handshake cost    | Once                        | Once per connection  |
| Head-of-line blocking | At TCP level only           | Independent per conn |
| Memory overhead       | Low (one socket)            | Higher (N sockets)   |
| Complexity            | High (stream management)    | Low                  |
| Server resource usage | 1 fd per client             | N fds per client     |
| OS port exhaustion    | Not a risk                  | Risk with many conns |

HTTP/2 chose multiplexing. HTTP/1.1 browsers open 6 parallel connections. Both are valid strategies. The right choice depends on your latency requirements, connection setup costs, and implementation complexity budget.

---

## Key Takeaways

- Correlation IDs are the foundation of multiplexed protocols — without them, the client cannot match out-of-order responses to their originating requests, making concurrent communication on a single connection impossible.
- Multiplexing assigns a stream ID to each logical conversation so frames from different streams can be interleaved on one TCP connection, eliminating the need for multiple connections and their associated handshake costs.
- Pipelining (sending N requests without waiting for responses, expecting FIFO-ordered responses) is simpler than full multiplexing but suffers from head-of-line blocking — a slow response delays all subsequent ones.
- Bidirectional streaming allows both sides to push data simultaneously without a request-response pattern, enabling real-time patterns like live counters, chat, and sensor feeds.
- Protocol-level flow control (per-stream send windows and WINDOW_UPDATE frames) prevents a fast producer from overwhelming a slow consumer, complementing TCP's own flow control which operates at the connection level, not the stream level.

---

## Next

Continue to [Lesson 04 — Connection Pooling & Load Balancing](lesson-04-connection-pooling.md) to build a connection pool that reuses TCP connections, performs health checks, and distributes load across backend servers.
