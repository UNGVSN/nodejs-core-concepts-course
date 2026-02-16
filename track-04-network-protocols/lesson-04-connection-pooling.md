# Track 04 / Lesson 04 — Connection Pooling & Load Balancing

> Opening a TCP connection takes a three-way handshake. Adding TLS adds another round trip. If your service makes 10,000 requests per second and opens a new connection for each one, you are wasting 20,000 round trips on handshakes alone. Connection pooling eliminates that waste by keeping a set of warm, ready-to-use connections that your application borrows and returns. This lesson builds a production-grade connection pool from scratch.

## Learning Objectives

- Explain why connection pooling matters for performance and identify the costs of TCP and TLS handshakes that pooling eliminates
- Build a connection pool class with acquire, release, and destroy operations that manages a set of reusable TCP connections
- Implement pool sizing with configurable minimum, maximum, and idle timeout parameters that balance resource usage with availability
- Add health checks (periodic ping and check-on-acquire) that detect and remove dead connections before they cause application errors
- Implement round-robin, least-connections, and weighted round-robin load balancing strategies for distributing requests across backend servers

---

## The Cost of Connection Establishment

Every new TCP connection requires a three-way handshake (SYN, SYN-ACK, ACK). With TLS, add a TLS handshake (ClientHello, ServerHello, key exchange, Finished). On a 20ms latency link, this means 60-80ms of pure overhead before the first byte of application data.

```javascript
'use strict';

const net = require('node:net');
const { performance } = require('node:perf_hooks');

// Measure the cost of opening a new TCP connection vs reusing one
async function measureConnectionCost(host, port, iterations) {
  // Strategy 1: New connection per request
  const newConnStart = performance.now();
  for (let i = 0; i < iterations; i++) {
    await new Promise((resolve, reject) => {
      const socket = net.createConnection({ host, port }, () => {
        socket.write('PING\n');
      });
      socket.on('data', () => {
        socket.end();
      });
      socket.on('close', resolve);
      socket.on('error', reject);
    });
  }
  const newConnTime = performance.now() - newConnStart;

  // Strategy 2: Reuse a single connection
  const reuseStart = performance.now();
  const socket = await new Promise((resolve, reject) => {
    const s = net.createConnection({ host, port }, () => resolve(s));
    s.on('error', reject);
  });

  for (let i = 0; i < iterations; i++) {
    await new Promise((resolve) => {
      socket.write('PING\n');
      socket.once('data', () => resolve());
    });
  }
  socket.end();
  const reuseTime = performance.now() - reuseStart;

  console.log(`New connection per request: ${newConnTime.toFixed(1)}ms for ${iterations} requests`);
  console.log(`Reused connection:          ${reuseTime.toFixed(1)}ms for ${iterations} requests`);
  console.log(`Speedup: ${(newConnTime / reuseTime).toFixed(1)}x`);
}

// measureConnectionCost('127.0.0.1', 4000, 100);
```

On localhost, the difference is noticeable. Over a network with real latency, it is dramatic.

---

## Connection Lifecycle

A pooled connection moves through these states:

```
CREATE ──→ IDLE ──→ ACTIVE ──→ IDLE ──→ ACTIVE ──→ IDLE ──→ DESTROY
              ↑                    │
              └────────────────────┘
                   (release)

IDLE → DESTROY triggers:
  - Idle timeout expired
  - Health check failed
  - Pool is shrinking
  - Connection error
```

---

## Building the Connection Pool

```javascript
'use strict';

const net = require('node:net');
const { EventEmitter } = require('node:events');

class ConnectionPool extends EventEmitter {
  constructor(options = {}) {
    super();
    this.host = options.host || '127.0.0.1';
    this.port = options.port || 3000;
    this.minSize = options.min || 2;
    this.maxSize = options.max || 10;
    this.idleTimeoutMs = options.idleTimeout || 30_000;
    this.acquireTimeoutMs = options.acquireTimeout || 5_000;
    this.healthCheckIntervalMs = options.healthCheckInterval || 10_000;

    this.idle = [];         // Available connections
    this.active = new Set(); // Currently in-use connections
    this.waitQueue = [];     // Callers waiting for a connection
    this.closed = false;
    this.healthTimer = null;

    // Metadata per connection
    this.connMeta = new WeakMap();
  }

  // Initialize the pool with minimum connections
  async initialize() {
    const promises = [];
    for (let i = 0; i < this.minSize; i++) {
      promises.push(this.createConnection());
    }

    const connections = await Promise.all(promises);
    for (const conn of connections) {
      this.idle.push(conn);
    }

    // Start periodic health checks
    this.healthTimer = setInterval(() => this.healthCheck(), this.healthCheckIntervalMs);
    this.healthTimer.unref();

    this.emit('ready', { idle: this.idle.length, active: this.active.size });
  }

  // Create a new TCP connection
  createConnection() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: this.host, port: this.port }, () => {
        this.connMeta.set(socket, {
          createdAt: Date.now(),
          lastUsedAt: Date.now(),
          idleTimer: null,
          useCount: 0,
        });

        socket.on('error', (err) => {
          this.emit('connectionError', err, socket);
          this.destroyConnection(socket);
        });

        socket.on('close', () => {
          this.removeFromPool(socket);
        });

        resolve(socket);
      });

      socket.on('error', (err) => {
        reject(err);
      });
    });
  }

  // Acquire a connection from the pool
  async acquire() {
    if (this.closed) {
      throw new Error('Pool is closed');
    }

    // Try to get an idle connection
    while (this.idle.length > 0) {
      const socket = this.idle.pop();
      const meta = this.connMeta.get(socket);

      if (!meta) continue;

      // Clear the idle timer
      if (meta.idleTimer) {
        clearTimeout(meta.idleTimer);
        meta.idleTimer = null;
      }

      // Check-on-acquire: verify the connection is still alive
      if (socket.destroyed || !socket.writable) {
        this.emit('staleConnection', socket);
        continue; // Skip dead connections
      }

      meta.lastUsedAt = Date.now();
      meta.useCount++;
      this.active.add(socket);
      this.emit('acquire', { idle: this.idle.length, active: this.active.size });
      return socket;
    }

    // No idle connections — can we create a new one?
    const totalConnections = this.idle.length + this.active.size;
    if (totalConnections < this.maxSize) {
      const socket = await this.createConnection();
      const meta = this.connMeta.get(socket);
      meta.lastUsedAt = Date.now();
      meta.useCount++;
      this.active.add(socket);
      this.emit('acquire', { idle: this.idle.length, active: this.active.size });
      return socket;
    }

    // Pool exhausted — wait in queue
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waitQueue.findIndex((e) => e.resolve === resolve);
        if (idx !== -1) this.waitQueue.splice(idx, 1);
        reject(new Error(`Acquire timeout after ${this.acquireTimeoutMs}ms — pool exhausted`));
      }, this.acquireTimeoutMs);
      timer.unref();

      this.waitQueue.push({ resolve, reject, timer });
      this.emit('waiting', { queueLength: this.waitQueue.length });
    });
  }

  // Release a connection back to the pool
  release(socket) {
    if (!this.active.has(socket)) {
      console.warn('Attempted to release a connection not owned by this pool');
      return;
    }

    this.active.delete(socket);

    // If the connection is dead, do not return it to the pool
    if (socket.destroyed || !socket.writable) {
      this.emit('connectionDestroyed', socket);
      return;
    }

    // If there are waiters, give the connection directly to the next one
    if (this.waitQueue.length > 0) {
      const waiter = this.waitQueue.shift();
      clearTimeout(waiter.timer);

      const meta = this.connMeta.get(socket);
      if (meta) {
        meta.lastUsedAt = Date.now();
        meta.useCount++;
      }
      this.active.add(socket);
      waiter.resolve(socket);
      return;
    }

    // Return to idle pool with an idle timeout
    const meta = this.connMeta.get(socket);
    if (meta) {
      meta.lastUsedAt = Date.now();
      meta.idleTimer = setTimeout(() => {
        this.destroyConnection(socket);
        this.emit('idleTimeout', socket);
      }, this.idleTimeoutMs);
      meta.idleTimer.unref();
    }

    this.idle.push(socket);
    this.emit('release', { idle: this.idle.length, active: this.active.size });
  }

  // Destroy a specific connection
  destroyConnection(socket) {
    this.removeFromPool(socket);
    if (!socket.destroyed) {
      socket.destroy();
    }
  }

  // Remove a connection from all tracking structures
  removeFromPool(socket) {
    const meta = this.connMeta.get(socket);
    if (meta && meta.idleTimer) {
      clearTimeout(meta.idleTimer);
    }

    this.active.delete(socket);
    const idleIdx = this.idle.indexOf(socket);
    if (idleIdx !== -1) {
      this.idle.splice(idleIdx, 1);
    }
  }

  // Periodic health check — remove dead idle connections
  async healthCheck() {
    const toRemove = [];

    for (const socket of this.idle) {
      if (socket.destroyed || !socket.writable) {
        toRemove.push(socket);
      }
    }

    for (const socket of toRemove) {
      this.destroyConnection(socket);
      this.emit('healthCheckFailed', socket);
    }

    // Ensure minimum pool size
    const deficit = this.minSize - (this.idle.length + this.active.size);
    for (let i = 0; i < deficit; i++) {
      try {
        const socket = await this.createConnection();
        this.idle.push(socket);
      } catch (err) {
        this.emit('connectionError', err);
      }
    }
  }

  // Gracefully close the pool
  async close() {
    this.closed = true;

    if (this.healthTimer) {
      clearInterval(this.healthTimer);
    }

    // Reject all waiters
    for (const waiter of this.waitQueue) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error('Pool is closing'));
    }
    this.waitQueue = [];

    // Destroy all idle connections
    for (const socket of this.idle) {
      this.destroyConnection(socket);
    }
    this.idle = [];

    // Destroy all active connections
    for (const socket of this.active) {
      socket.destroy();
    }
    this.active.clear();

    this.emit('closed');
  }

  // Pool statistics
  stats() {
    return {
      idle: this.idle.length,
      active: this.active.size,
      waiting: this.waitQueue.length,
      total: this.idle.length + this.active.size,
      maxSize: this.maxSize,
    };
  }
}
```

---

## Using the Connection Pool

```javascript
'use strict';

const net = require('node:net');

// Create a simple echo server for testing
const server = net.createServer((socket) => {
  socket.on('data', (chunk) => {
    socket.write(chunk); // Echo back
  });
});

server.listen(4000, async () => {
  console.log('Echo server on :4000');

  const pool = new ConnectionPool({
    host: '127.0.0.1',
    port: 4000,
    min: 2,
    max: 5,
    idleTimeout: 10_000,
    acquireTimeout: 3_000,
  });

  pool.on('ready', (info) => console.log('Pool ready:', info));
  pool.on('acquire', (info) => console.log('  acquire:', info));
  pool.on('release', (info) => console.log('  release:', info));
  pool.on('idleTimeout', () => console.log('  idle timeout — connection destroyed'));

  await pool.initialize();

  // Use the pool: acquire, use, release
  async function sendRequest(message) {
    const socket = await pool.acquire();

    return new Promise((resolve, reject) => {
      socket.once('data', (chunk) => {
        pool.release(socket);
        resolve(chunk.toString('utf8'));
      });

      socket.once('error', (err) => {
        pool.release(socket);
        reject(err);
      });

      socket.write(message);
    });
  }

  // Send 10 requests concurrently using at most 5 connections
  const promises = [];
  for (let i = 0; i < 10; i++) {
    promises.push(sendRequest(`Request #${i}\n`));
  }

  const results = await Promise.all(promises);
  console.log('Results:', results.map((r) => r.trim()));
  console.log('Pool stats:', pool.stats());

  await pool.close();
  server.close();
});
```

---

## Health Checks: Ping on Acquire vs. Periodic Ping

Two strategies for detecting dead connections:

### Check-on-Acquire

Verify the connection is alive immediately before handing it to the caller. The simplest approach is checking `socket.writable` and `socket.destroyed`, which we already do in `acquire()`. For deeper validation, send a protocol-level PING:

```javascript
'use strict';

const net = require('node:net');

async function pingCheck(socket, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      resolve(false); // Timed out — connection is dead
    }, timeoutMs);
    timer.unref();

    // Send a PING and wait for PONG
    socket.write('PING\n');

    function onData(chunk) {
      const response = chunk.toString('utf8').trim();
      if (response === 'PONG') {
        clearTimeout(timer);
        socket.removeListener('data', onData);
        resolve(true);
      }
    }

    socket.on('data', onData);

    socket.once('error', () => {
      clearTimeout(timer);
      socket.removeListener('data', onData);
      resolve(false);
    });
  });
}

// Enhanced acquire with PING health check
async function acquireWithPing(pool) {
  const socket = await pool.acquire();

  const alive = await pingCheck(socket, 1000);
  if (!alive) {
    pool.destroyConnection(socket);
    // Retry — the pool will create a new connection
    return acquireWithPing(pool);
  }

  return socket;
}
```

**Trade-off:** Check-on-acquire adds latency to every acquire call (the PING round trip). Periodic pinging runs in the background so acquire stays fast, but stale connections may linger between checks.

### Periodic Background Ping

```javascript
'use strict';

function startPeriodicPing(pool, intervalMs = 10_000) {
  const timer = setInterval(async () => {
    const idleConnections = [...pool.idle];

    for (const socket of idleConnections) {
      const alive = await pingCheck(socket, 2000);
      if (!alive) {
        console.log('[health] removing dead connection');
        pool.destroyConnection(socket);
      }
    }

    // Replenish to minimum
    const deficit = pool.minSize - (pool.idle.length + pool.active.size);
    for (let i = 0; i < deficit; i++) {
      try {
        const socket = await pool.createConnection();
        pool.idle.push(socket);
        console.log('[health] replenished pool — new connection created');
      } catch (err) {
        console.error('[health] failed to create connection:', err.message);
      }
    }
  }, intervalMs);

  timer.unref();
  return timer;
}
```

---

## Load Balancing Strategies

When you have multiple backend servers, the pool needs a strategy to decide which one gets the next request.

### Round-Robin

Distribute requests evenly by cycling through backends in order.

```javascript
'use strict';

const net = require('node:net');

class RoundRobinBalancer {
  constructor(backends) {
    // backends: [{ host, port }, ...]
    this.backends = backends;
    this.index = 0;
  }

  next() {
    const backend = this.backends[this.index];
    this.index = (this.index + 1) % this.backends.length;
    return backend;
  }
}

// Usage
const balancer = new RoundRobinBalancer([
  { host: '127.0.0.1', port: 4001 },
  { host: '127.0.0.1', port: 4002 },
  { host: '127.0.0.1', port: 4003 },
]);

for (let i = 0; i < 6; i++) {
  const backend = balancer.next();
  console.log(`Request ${i + 1} → ${backend.host}:${backend.port}`);
}
// Output: 4001, 4002, 4003, 4001, 4002, 4003
```

### Least-Connections

Send the next request to the backend with the fewest active connections.

```javascript
'use strict';

class LeastConnectionsBalancer {
  constructor(backends) {
    this.backends = backends.map((b) => ({
      ...b,
      activeConnections: 0,
    }));
  }

  next() {
    // Find the backend with the fewest active connections
    let min = this.backends[0];
    for (let i = 1; i < this.backends.length; i++) {
      if (this.backends[i].activeConnections < min.activeConnections) {
        min = this.backends[i];
      }
    }
    min.activeConnections++;
    return min;
  }

  release(backend) {
    backend.activeConnections = Math.max(0, backend.activeConnections - 1);
  }
}

// Usage
const lcb = new LeastConnectionsBalancer([
  { host: '127.0.0.1', port: 4001 },
  { host: '127.0.0.1', port: 4002 },
  { host: '127.0.0.1', port: 4003 },
]);

// Simulate uneven connection times
const b1 = lcb.next(); // 4001 (all at 0, picks first)
const b2 = lcb.next(); // 4002 (4001 has 1, picks 4002)
const b3 = lcb.next(); // 4003
const b4 = lcb.next(); // any of the three (all at 1)

console.log('After 4 acquires:', lcb.backends.map((b) => `${b.port}: ${b.activeConnections}`));

lcb.release(b1); // Free 4001
const b5 = lcb.next(); // 4001 (now at 0, lowest)
console.log('After releasing b1:', lcb.backends.map((b) => `${b.port}: ${b.activeConnections}`));
```

### Weighted Round-Robin

Assign weights to backends based on capacity. A backend with weight 3 gets three times as many requests as one with weight 1.

```javascript
'use strict';

class WeightedRoundRobinBalancer {
  constructor(backends) {
    // backends: [{ host, port, weight }, ...]
    this.backends = backends;
    this.currentIndex = 0;
    this.currentWeight = 0;
    this.maxWeight = Math.max(...backends.map((b) => b.weight));
    this.gcdWeight = this.gcd(backends.map((b) => b.weight));
  }

  gcd(values) {
    function gcd2(a, b) {
      while (b) { [a, b] = [b, a % b]; }
      return a;
    }
    return values.reduce(gcd2);
  }

  next() {
    while (true) {
      this.currentIndex = (this.currentIndex + 1) % this.backends.length;

      if (this.currentIndex === 0) {
        this.currentWeight -= this.gcdWeight;
        if (this.currentWeight <= 0) {
          this.currentWeight = this.maxWeight;
        }
      }

      if (this.backends[this.currentIndex].weight >= this.currentWeight) {
        return this.backends[this.currentIndex];
      }
    }
  }
}

// Backend A has 3x capacity of C, 1.5x capacity of B
const wrr = new WeightedRoundRobinBalancer([
  { host: '127.0.0.1', port: 4001, weight: 6 },
  { host: '127.0.0.1', port: 4002, weight: 4 },
  { host: '127.0.0.1', port: 4003, weight: 2 },
]);

// Distribution over 12 requests
const counts = { 4001: 0, 4002: 0, 4003: 0 };
for (let i = 0; i < 12; i++) {
  const b = wrr.next();
  counts[b.port]++;
}
console.log('Distribution:', counts);
// Approximately: { 4001: 6, 4002: 4, 4003: 2 }
```

---

## Integration With `http.Agent`

Node.js `http.Agent` is itself a connection pool. Understanding its options helps you configure it correctly or decide when to build your own.

```javascript
'use strict';

const http = require('node:http');

// Default Agent: keeps connections alive, limits per-host connections
const agent = new http.Agent({
  keepAlive: true,           // Reuse connections (default true since Node 19)
  keepAliveMsecs: 1000,      // TCP keepalive probe interval
  maxSockets: 10,            // Max concurrent connections per host
  maxFreeSockets: 5,         // Max idle connections to keep alive
  timeout: 30_000,           // Socket timeout
  scheduling: 'lifo',        // 'lifo' reuses recent sockets (better for idle timeout)
                             // 'fifo' distributes evenly (better for load balancing)
});

// Use the agent for requests
function makeRequest(path) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: 3000,
      path,
      agent,
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });

    req.on('error', reject);
    req.end();
  });
}

// Monitor agent statistics
function agentStats(agent) {
  const stats = {};
  for (const [name, sockets] of Object.entries(agent.sockets)) {
    stats[name] = { active: sockets.length };
  }
  for (const [name, sockets] of Object.entries(agent.freeSockets)) {
    if (!stats[name]) stats[name] = {};
    stats[name].idle = sockets.length;
  }
  return stats;
}

// console.log('Agent stats:', agentStats(agent));
```

**When to use `http.Agent` vs. a custom pool:**

- Use `http.Agent` when you are making HTTP requests — it handles keep-alive, connection reuse, and per-host limits automatically.
- Build a custom pool when you are using raw TCP, a custom binary protocol, or need features `http.Agent` does not provide (weighted backends, health checks, circuit breaking).

---

## Handling Pool Exhaustion

When all connections are in use and the pool is at maximum size, new requests must either wait or fail immediately. The choice depends on your application:

```javascript
'use strict';

// Strategy 1: Queue with timeout (what our pool does)
// pool.acquire() waits up to acquireTimeoutMs, then rejects

// Strategy 2: Fail immediately
class FailFastPool extends ConnectionPool {
  async acquire() {
    if (this.idle.length === 0 && this.active.size >= this.maxSize) {
      throw new Error('Pool exhausted — all connections in use');
    }
    return super.acquire();
  }
}

// Strategy 3: Overflow — create a temporary connection beyond max
class OverflowPool extends ConnectionPool {
  async acquire() {
    try {
      return await super.acquire();
    } catch (err) {
      if (err.message.includes('exhausted') || err.message.includes('timeout')) {
        console.warn('[pool] overflow — creating temporary connection beyond max');
        const socket = await this.createConnection();
        // Mark as overflow so it gets destroyed on release instead of returned
        const meta = this.connMeta.get(socket);
        if (meta) meta.overflow = true;
        this.active.add(socket);
        return socket;
      }
      throw err;
    }
  }

  release(socket) {
    const meta = this.connMeta.get(socket);
    if (meta && meta.overflow) {
      this.active.delete(socket);
      socket.destroy();
      console.log('[pool] overflow connection destroyed on release');
      return;
    }
    super.release(socket);
  }
}
```

---

## Key Takeaways

- Connection pooling eliminates the repeated cost of TCP and TLS handshakes by keeping a set of warm, pre-established connections that are borrowed for a request and returned when done — the performance difference grows with network latency.
- A pool manages connections through a lifecycle (create, idle, active, idle, destroy) with configurable minimum size (always available), maximum size (resource cap), and idle timeout (clean up unused connections).
- Health checks come in two flavors: check-on-acquire (verify before use, adds latency) and periodic background ping (asynchronous, faster acquire, but stale connections may linger briefly between checks).
- Round-robin distributes load evenly by request count, least-connections distributes by actual load, and weighted round-robin accounts for different backend capacities — the right choice depends on whether your requests have uniform or variable processing times.
- When all connections are in use, the pool must choose between queuing (wait for a connection to be released), failing fast (reject immediately), or overflowing (create a temporary connection beyond the maximum) — each strategy trades latency predictability against resource safety.

---

## Next

Continue to [Lesson 05 — WebSocket Protocol](lesson-05-websocket-protocol.md) to implement the WebSocket protocol from scratch — the HTTP upgrade handshake, frame encoding with opcodes and masking, ping/pong heartbeats, and the close handshake.
