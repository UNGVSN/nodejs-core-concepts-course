# Module 06 / Lesson 08 — Network Debugging

> Network bugs are uniquely frustrating because the code that causes the problem and the symptom you observe are often on different machines. A connection leak does not crash your server immediately — it slowly exhausts file descriptors over hours. A half-open socket silently stops receiving data. An unhandled socket error brings down the entire process at 3 AM. This lesson gives you a systematic toolkit for finding and fixing these problems before they find you.

## Learning Objectives

- Use `socket.bytesRead`, `socket.bytesWritten`, and `socket.readyState` to inspect connection health
- Trace all socket events to build a complete timeline of connection behavior
- Leverage `NODE_DEBUG=net` and `NODE_DEBUG=net,dns` for built-in diagnostic output
- Identify and fix common network bugs: connection leaks, half-open sockets, unhandled errors, and backpressure stalls
- Build diagnostic tools for port scanning, latency measurement, and connection pool health checks

---

## A Systematic Approach to Network Debugging

Network problems generally fall into five categories:

| Category | Symptoms | Root Cause |
|----------|----------|------------|
| Connection failures | `ECONNREFUSED`, `ETIMEDOUT`, `ENOTFOUND` | Server not running, firewall, DNS issue |
| Connection leaks | Increasing memory/FD usage, `EMFILE` | Sockets not closed after use |
| Data corruption | Garbled messages, protocol errors | Missing or broken message framing |
| Performance degradation | High latency, low throughput | Backpressure ignored, Nagle's algorithm, DNS thread pool |
| Unexpected disconnections | `ECONNRESET`, `EPIPE` | Remote crash, network interruption, idle timeout |

The debugging workflow:

1. **Reproduce** the issue with the smallest possible setup
2. **Instrument** the sockets with event logging
3. **Measure** bytes, connections, and timing
4. **Isolate** the layer (DNS, TCP, application protocol, business logic)
5. **Fix** and verify with automated tests

---

## Inspecting Socket State

Every `net.Socket` exposes properties that reveal its current state.

```javascript
'use strict';

const net = require('node:net');

function logSocketState(label, socket) {
  console.log(`[${label}] Socket state:`);
  console.log(`  readyState:    ${socket.readyState}`);
  console.log(`  bytesRead:     ${socket.bytesRead}`);
  console.log(`  bytesWritten:  ${socket.bytesWritten}`);
  console.log(`  remoteAddress: ${socket.remoteAddress || 'N/A'}`);
  console.log(`  remotePort:    ${socket.remotePort || 'N/A'}`);
  console.log(`  localAddress:  ${socket.localAddress || 'N/A'}`);
  console.log(`  localPort:     ${socket.localPort || 'N/A'}`);
  console.log(`  pending:       ${socket.pending}`);
  console.log(`  destroyed:     ${socket.destroyed}`);
  console.log(`  connecting:    ${socket.connecting}`);
}

const server = net.createServer((socket) => {
  logSocketState('server-side', socket);

  socket.on('data', () => {
    logSocketState('after-data', socket);
  });

  socket.on('end', () => {
    logSocketState('on-end', socket);
  });

  socket.on('close', () => {
    logSocketState('on-close', socket);
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });

  socket.write('Hello\n');
});

server.listen(4000, () => {
  const client = net.createConnection({ port: 4000 }, () => {
    logSocketState('client-connected', client);
    client.write('Test data\n');
    client.end();
  });

  client.on('data', () => {});
  client.on('end', () => server.close());
  client.on('error', (err) => console.error('Client error:', err.message));
});
```

### The `readyState` Values

| State | Meaning |
|-------|---------|
| `'opening'` | `connect()` called, not yet connected |
| `'open'` | Connected, readable and writable |
| `'readOnly'` | Remote end sent FIN, but you can still read buffered data |
| `'writeOnly'` | You called `end()`, remote can still send |
| `'closed'` | Fully closed |

---

## Event Tracing

The most powerful debugging technique for network code is logging every event on every socket. This creates a timeline that reveals exactly what happened and in what order.

```javascript
'use strict';

const net = require('node:net');

const SOCKET_EVENTS = [
  'connect', 'ready', 'data', 'end', 'close',
  'error', 'drain', 'timeout', 'lookup'
];

let socketId = 0;

function instrumentSocket(socket, label) {
  const id = ++socketId;
  const prefix = `[Socket#${id} ${label}]`;
  const startTime = Date.now();

  function elapsed() {
    return `+${Date.now() - startTime}ms`;
  }

  for (const event of SOCKET_EVENTS) {
    socket.on(event, (...args) => {
      const details = [];

      if (event === 'data') {
        details.push(`${args[0].length} bytes`);
      } else if (event === 'error') {
        details.push(`${args[0].code}: ${args[0].message}`);
      } else if (event === 'close') {
        details.push(`hadError=${args[0]}`);
      } else if (event === 'lookup') {
        const [err, address, family] = args;
        details.push(err ? `err=${err.message}` : `${address} IPv${family}`);
      }

      console.log(
        `${prefix} ${elapsed()} ${event}` +
        (details.length > 0 ? ` (${details.join(', ')})` : '')
      );
    });
  }

  // Intercept write to log outbound data
  const originalWrite = socket.write.bind(socket);
  socket.write = function(data, encoding, callback) {
    const size = Buffer.isBuffer(data) ? data.length : Buffer.byteLength(data);
    console.log(`${prefix} ${elapsed()} write (${size} bytes)`);
    return originalWrite(data, encoding, callback);
  };

  console.log(`${prefix} ${elapsed()} created`);
  return socket;
}

// Usage
const server = net.createServer((socket) => {
  instrumentSocket(socket, 'server');
  socket.on('data', (chunk) => socket.write(`Echo: ${chunk}`));
  socket.on('error', () => {}); // Prevent crash — already logged by instrumenter
});

server.listen(4000, () => {
  console.log('Instrumented server on port 4000');

  const client = net.createConnection({ port: 4000 });
  instrumentSocket(client, 'client');

  client.on('connect', () => {
    client.write('Hello\n');
    setTimeout(() => client.end(), 500);
  });

  client.on('data', () => {});
  client.on('end', () => server.close());
  client.on('error', () => {});
});
```

Sample output from this instrumentation:

```
[Socket#1 client] +0ms created
[Socket#2 server] +3ms created
[Socket#1 client] +3ms connect
[Socket#1 client] +3ms ready
[Socket#1 client] +4ms write (6 bytes)
[Socket#2 server] +4ms data (6 bytes)
[Socket#2 server] +4ms write (12 bytes)
[Socket#1 client] +5ms data (12 bytes)
[Socket#1 client] +505ms write (0 bytes)
[Socket#2 server] +505ms end
[Socket#2 server] +506ms close (hadError=false)
[Socket#1 client] +506ms end
[Socket#1 client] +506ms close (hadError=false)
```

This timeline makes it immediately obvious when events are missing, out of order, or delayed.

---

## The `NODE_DEBUG` Environment Variable

Node.js has built-in debug logging for the `net` and `dns` modules. Enable it without changing any code:

```bash
# Enable net module debug output
NODE_DEBUG=net node server.js

# Enable both net and dns debug output
NODE_DEBUG=net,dns node server.js

# Enable all built-in debugging (verbose)
NODE_DEBUG=net,dns,http,stream node server.js
```

Example output with `NODE_DEBUG=net`:

```
NET 12345: pipe false
NET 12345: bind to 0.0.0.0
NET 12345: onconnection
NET 12345: _read
NET 12345: Socket._handle.readStart
NET 12345: afterWrite 1
NET 12345: afterWrite 0
```

The numbers after `NET` are the process PID. This is useful for correlating output across multiple processes.

### Custom Debug Logging

You can create your own debug loggers using the same pattern Node.js uses internally:

```javascript
'use strict';

const util = require('node:util');

const debug = util.debuglog('myapp:net');

// This only prints when NODE_DEBUG=myapp:net (or NODE_DEBUG=myapp:*)
debug('Starting server on port %d', 4000);
debug('Connection from %s:%d', '127.0.0.1', 54321);
debug('Received %d bytes', 1024);
```

```bash
# Activate the debug logger
NODE_DEBUG=myapp:net node server.js
# Output: MYAPP:NET 12345: Starting server on port 4000
```

---

## Common Network Bugs

### Bug 1: Connection Leaks

A connection leak happens when sockets are opened but never closed. Each open socket consumes a file descriptor. When you run out, the OS returns `EMFILE` (too many open files) and your server cannot accept new connections.

```javascript
'use strict';

const net = require('node:net');

// BAD: This function leaks connections
function fetchDataBad(host, port) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ port, host }, () => {
      client.write('GET /data\n');
    });

    client.on('data', (chunk) => {
      resolve(chunk.toString());
      // BUG: Never calls client.end() or client.destroy()
      // The socket stays open forever
    });

    client.on('error', reject);
  });
}

// GOOD: This function properly closes connections
function fetchDataGood(host, port) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const client = net.createConnection({ port, host }, () => {
      client.write('GET /data\n');
    });

    client.on('data', (chunk) => {
      chunks.push(chunk);
    });

    client.on('end', () => {
      resolve(Buffer.concat(chunks).toString());
    });

    client.on('error', (err) => {
      client.destroy();
      reject(err);
    });

    // Safety net: timeout and destroy
    client.setTimeout(5000, () => {
      client.destroy(new Error('Connection timed out'));
    });
  });
}
```

### Detecting Connection Leaks

```javascript
'use strict';

const net = require('node:net');

const connections = new Set();
let totalCreated = 0;
let totalDestroyed = 0;

const server = net.createServer((socket) => {
  connections.add(socket);
  totalCreated++;

  socket.on('close', () => {
    connections.delete(socket);
    totalDestroyed++;
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });

  socket.on('data', (chunk) => {
    socket.write(chunk);
  });
});

// Periodic leak detector
setInterval(() => {
  console.log(
    `Connections: active=${connections.size}` +
    ` created=${totalCreated}` +
    ` destroyed=${totalDestroyed}` +
    ` leaked=${totalCreated - totalDestroyed - connections.size}`
  );
}, 5000);

server.listen(4000);
```

### Bug 2: Half-Open Connections

A half-open connection occurs when one side has closed its write end but the other side does not realize it. By default (`allowHalfOpen: false`), Node.js automatically sends a FIN when the remote end sends one. But if you set `allowHalfOpen: true` and forget to call `socket.end()`, the connection leaks.

```javascript
'use strict';

const net = require('node:net');

// BAD: allowHalfOpen without calling end()
const leakyServer = net.createServer({ allowHalfOpen: true }, (socket) => {
  socket.on('end', () => {
    console.log('Client sent FIN');
    // BUG: We never call socket.end() — connection stays half-open forever
    // socket.end();  ← This line is missing
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});

// GOOD: Always pair allowHalfOpen with an explicit end()
const goodServer = net.createServer({ allowHalfOpen: true }, (socket) => {
  const chunks = [];

  socket.on('data', (chunk) => {
    chunks.push(chunk);
  });

  socket.on('end', () => {
    // Process all the data the client sent
    const request = Buffer.concat(chunks).toString();
    console.log('Complete request:', request);

    // Send the response and close our end
    socket.write('Response data\n');
    socket.end(); // Send our FIN
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });
});
```

### Bug 3: Unhandled Socket Errors Crashing the Process

In Node.js, an `EventEmitter` that emits an `'error'` event with no listener throws the error as an uncaught exception, crashing the process. Every socket must have an error handler.

```javascript
'use strict';

const net = require('node:net');

// BAD: No error handler — ECONNRESET crashes the process
// const server = net.createServer((socket) => {
//   socket.on('data', (chunk) => socket.write(chunk));
//   // If the client abruptly disconnects, ECONNRESET is emitted
//   // No 'error' handler → process crashes
// });

// GOOD: Always attach an error handler
const server = net.createServer((socket) => {
  socket.on('data', (chunk) => {
    socket.write(chunk);
  });

  socket.on('error', (err) => {
    if (err.code === 'ECONNRESET') {
      console.log('Client abruptly disconnected');
    } else if (err.code === 'EPIPE') {
      console.log('Wrote to a closed socket');
    } else {
      console.error('Unexpected socket error:', err.code, err.message);
    }
  });
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
});

server.listen(4000);
```

### Bug 4: Ignoring Backpressure

When `socket.write()` returns `false`, the internal buffer is full. Continuing to write without waiting for `'drain'` causes unbounded memory growth.

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  let paused = false;

  // Simulate a producer that generates data faster than the client can consume
  const interval = setInterval(() => {
    if (paused) return;

    const data = Buffer.alloc(64 * 1024, 'A'); // 64 KB per tick
    const flushed = socket.write(data);

    if (!flushed) {
      paused = true;
      console.log('Backpressure detected — pausing writes');

      socket.once('drain', () => {
        paused = false;
        console.log('Drain received — resuming writes');
      });
    }
  }, 10);

  socket.on('close', () => {
    clearInterval(interval);
  });

  socket.on('error', (err) => {
    clearInterval(interval);
    console.error('Socket error:', err.message);
  });
});

server.listen(4000);
```

---

## Building a Port Scanner

A diagnostic tool that checks which ports are open on a given host.

```javascript
'use strict';

const net = require('node:net');

/**
 * Check if a port is open on a given host.
 * @param {string} host
 * @param {number} port
 * @param {number} timeoutMs
 * @returns {Promise<{ port: number, open: boolean, latencyMs: number }>}
 */
function checkPort(host, port, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const start = Date.now();
    const socket = new net.Socket();

    socket.setTimeout(timeoutMs);

    socket.on('connect', () => {
      const latencyMs = Date.now() - start;
      socket.destroy();
      resolve({ port, open: true, latencyMs });
    });

    socket.on('timeout', () => {
      socket.destroy();
      resolve({ port, open: false, latencyMs: timeoutMs });
    });

    socket.on('error', () => {
      resolve({ port, open: false, latencyMs: Date.now() - start });
    });

    socket.connect(port, host);
  });
}

/**
 * Scan a range of ports on a host.
 * Scans in batches to avoid overwhelming the OS with connections.
 */
async function scanPorts(host, startPort, endPort, concurrency = 50) {
  console.log(`Scanning ${host} ports ${startPort}-${endPort}...`);
  const start = Date.now();
  const openPorts = [];

  for (let i = startPort; i <= endPort; i += concurrency) {
    const batch = [];
    for (let j = i; j < Math.min(i + concurrency, endPort + 1); j++) {
      batch.push(checkPort(host, j));
    }

    const results = await Promise.all(batch);

    for (const result of results) {
      if (result.open) {
        openPorts.push(result);
        console.log(`  Port ${result.port}: OPEN (${result.latencyMs}ms)`);
      }
    }
  }

  const elapsed = Date.now() - start;
  console.log(`\nScan complete in ${elapsed}ms`);
  console.log(`Open ports: ${openPorts.length}`);

  return openPorts;
}

// Scan common ports on localhost
scanPorts('127.0.0.1', 1, 1024, 100);
```

---

## Measuring Latency and Throughput

### TCP Connection Latency

```javascript
'use strict';

const net = require('node:net');

/**
 * Measure TCP connection establishment time over multiple iterations.
 */
async function measureLatency(host, port, iterations = 10) {
  const latencies = [];

  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    await new Promise((resolve, reject) => {
      const socket = net.createConnection({ port, host }, () => {
        const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
        latencies.push(elapsed);
        socket.destroy();
        resolve();
      });
      socket.on('error', reject);
      socket.setTimeout(5000, () => socket.destroy());
    });
  }

  latencies.sort((a, b) => a - b);
  console.log('Connection latency (ms):');
  console.log(`  Min:    ${latencies[0].toFixed(2)}`);
  console.log(`  Avg:    ${(latencies.reduce((a, b) => a + b) / latencies.length).toFixed(2)}`);
  console.log(`  P95:    ${latencies[Math.floor(latencies.length * 0.95)].toFixed(2)}`);
  console.log(`  Max:    ${latencies[latencies.length - 1].toFixed(2)}`);
}
```

### Throughput Measurement

To measure throughput, send a known amount of data (e.g., 100 MB in 64 KB chunks) from client to server. On the server side, track `bytesReceived` and compute `MB/s = (bytesReceived / 1024 / 1024) / elapsedSeconds`. The key insight: use the backpressure-aware write loop (check `socket.write()` return value, wait for `'drain'` when it returns `false`) to get accurate throughput numbers without exhausting memory.

---

## Connection Health Checks

For services maintaining persistent connection pools, periodically check each socket's health:

```javascript
'use strict';

const net = require('node:net');

/**
 * Check if a socket is healthy.
 */
function isHealthy(socket) {
  return socket && !socket.destroyed && socket.readyState === 'open';
}

/**
 * Run a health check on a collection of sockets, replacing dead ones.
 */
function healthCheck(connections, host, port) {
  console.log('--- Health Check ---');
  for (let i = 0; i < connections.length; i++) {
    const conn = connections[i];
    const healthy = isHealthy(conn);
    console.log(
      `  #${i}: ${healthy ? 'HEALTHY' : 'UNHEALTHY'}` +
      ` state=${conn?.readyState || 'N/A'}` +
      ` bytesRead=${conn?.bytesRead || 0}`
    );

    if (!healthy) {
      // Replace dead connection
      const newConn = net.createConnection({ port, host });
      newConn.on('error', (err) => {
        console.error(`  Replacement #${i} failed: ${err.message}`);
      });
      connections[i] = newConn;
    }
  }
}
```

The key pattern: check `socket.readyState`, `socket.destroyed`, and `socket.bytesRead`/`bytesWritten` to distinguish live connections from zombies. Run health checks on a `setInterval` (e.g., every 10 seconds) and replace any socket that fails the check.

---

## Debugging Checklist

When a network issue occurs, work through this checklist:

```
[ ] Is the server actually running? (Check process list, logs)
[ ] Can you connect with nc/telnet? (Isolate: is it your code or the network?)
[ ] Is DNS resolving correctly? (NODE_DEBUG=dns)
[ ] Are there error handlers on EVERY socket and server? (Unhandled errors crash)
[ ] Are sockets being properly closed? (Check for connection leaks)
[ ] Is the framing protocol correct? (Partial reads / coalesced writes)
[ ] Are you handling backpressure? (Check socket.write() return value)
[ ] Is the thread pool exhausted? (UV_THREADPOOL_SIZE, dns.lookup contention)
[ ] Is there a firewall or proxy in the path? (Timeouts, resets)
[ ] Are keep-alive probes enabled? (Dead connections on idle sockets)
```

---

## Key Takeaways

- `NODE_DEBUG=net` activates built-in TCP debug logging without code changes — combine it with `dns` and `http` for full-stack network visibility.
- Instrument every socket event (`connect`, `data`, `end`, `close`, `error`, `drain`, `timeout`) with timestamps to build an exact timeline of connection behavior — this is the single most effective network debugging technique.
- Connection leaks are silent killers: track created vs destroyed socket counts and alert when the difference grows; use `socket.setTimeout()` as a safety net to destroy stale connections.
- Every `net.Socket` must have an `'error'` handler — `ECONNRESET` from an abruptly disconnected client will crash your entire process if unhandled.
- Measure connection latency and throughput with `process.hrtime.bigint()` to establish baselines; deviations from those baselines are your earliest warning of network degradation.

---

## Next

This concludes Module 06. Continue to [Module 07 — HTTP From Scratch](../module-07-http/lesson-01-http-protocol-fundamentals.md) to build on your TCP knowledge and learn how HTTP works at the protocol level before touching `http.createServer()`.
