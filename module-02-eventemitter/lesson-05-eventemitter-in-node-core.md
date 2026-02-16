# Module 02 / Lesson 05 — EventEmitter in Node.js Core

> You have learned how to build custom EventEmitters. Now it is time to see where Node.js already uses them. The answer is: almost everywhere. HTTP servers, TCP sockets, readable streams, file watchers, child processes — they all extend EventEmitter. Understanding this inheritance chain turns the entire Node.js API from a collection of unrelated modules into a unified, event-driven system.

## Learning Objectives

- Trace the EventEmitter inheritance chain in Node.js core modules
- Identify which events `http.Server`, `net.Socket`, and `net.Server` emit
- Explain why all streams are EventEmitters and which events they rely on
- Describe how `fs.FSWatcher` and `child_process.ChildProcess` use events
- Apply EventEmitter debugging techniques to any core module

---

## The Inheritance Chain

Almost every important class in Node.js inherits from EventEmitter. Here is the hierarchy:

```
EventEmitter
├── Stream (base class)
│   ├── Readable
│   │   ├── net.Socket (also Writable — Duplex)
│   │   ├── http.IncomingMessage
│   │   └── fs.ReadStream
│   ├── Writable
│   │   ├── http.ServerResponse
│   │   └── fs.WriteStream
│   ├── Duplex
│   │   ├── net.Socket
│   │   └── tls.TLSSocket
│   └── Transform
├── net.Server
│   └── http.Server
│       └── https.Server
├── fs.FSWatcher
├── child_process.ChildProcess
└── process (the global)
```

Every one of these classes has `.on()`, `.emit()`, `.off()`, and the full EventEmitter API. You already know how they work from Lessons 01-04. This lesson connects those mechanics to the specific events each class emits.

---

## `net.Server` and `net.Socket`

The `net` module is the foundation of all networking in Node.js. Both `Server` and `Socket` extend EventEmitter.

### `net.Server` Events

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer();

// Verify the inheritance
console.log(server instanceof require('node:events').EventEmitter);
// true

// Key events:
server.on('listening', () => {
  const addr = server.address();
  console.log(`Server listening on ${addr.address}:${addr.port}`);
});

server.on('connection', (socket) => {
  // 'socket' is a net.Socket — also an EventEmitter
  console.log(`New connection from ${socket.remoteAddress}:${socket.remotePort}`);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error('Port already in use');
  } else {
    console.error('Server error:', err.message);
  }
});

server.on('close', () => {
  console.log('Server closed — no more connections accepted');
});

server.listen(0);  // Port 0 = OS assigns a random available port
```

### `net.Socket` Events

Every TCP connection gives you a `net.Socket` — a Duplex stream (both readable and writable) that also emits its own events:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  // Stream events (inherited from Readable/Writable)
  socket.on('data', (chunk) => {
    console.log('Received:', chunk.toString());
    socket.write('Echo: ' + chunk.toString());
  });

  socket.on('end', () => {
    console.log('Client finished sending');
  });

  // Socket-specific events
  socket.on('close', (hadError) => {
    console.log(`Socket closed (error: ${hadError})`);
  });

  socket.on('timeout', () => {
    console.log('Socket timed out');
    socket.end();
  });

  socket.on('error', (err) => {
    console.error('Socket error:', err.message);
  });

  socket.setTimeout(30_000);
});

server.listen(0, () => {
  const { port } = server.address();

  // Create a client connection
  const client = net.createConnection({ port }, () => {
    console.log('Connected to server');
    client.write('Hello');
  });

  client.on('data', (data) => {
    console.log('Server replied:', data.toString());
    client.end();
  });

  client.on('end', () => {
    server.close();
  });
});
```

Notice how many patterns you already know: `on('data')`, `on('error')`, `on('close')`. These are EventEmitter patterns applied consistently across the entire networking stack.

---

## `http.Server`

`http.Server` extends `net.Server`, which extends `EventEmitter`. It inherits all of `net.Server`'s events and adds HTTP-specific ones:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer();

// The most important event — fires for every HTTP request
server.on('request', (req, res) => {
  // req is http.IncomingMessage (extends Readable)
  // res is http.ServerResponse (extends Writable)
  console.log(`${req.method} ${req.url}`);

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Hello from EventEmitter\n');
});

// Inherited from net.Server
server.on('listening', () => {
  console.log(`HTTP server on port ${server.address().port}`);
});

// HTTP-specific events
server.on('clientError', (err, socket) => {
  // Malformed HTTP requests — the client sent garbage
  console.error('Client error:', err.message);
  socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

server.on('upgrade', (req, socket, head) => {
  // WebSocket upgrade requests
  console.log('Upgrade requested for:', req.url);
});

server.on('connect', (req, socket, head) => {
  // HTTP CONNECT method (tunneling, proxies)
  console.log('CONNECT tunnel requested');
});

server.on('close', () => {
  console.log('HTTP server closed');
});

server.listen(0);
```

### `http.IncomingMessage` — A Readable Stream

The `req` object in your request handler is a Readable stream. It emits stream events:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // req extends Readable extends Stream extends EventEmitter
  const chunks = [];

  req.on('data', (chunk) => {
    chunks.push(chunk);
  });

  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    console.log('Request body:', body);
    res.end('Received');
  });

  req.on('error', (err) => {
    console.error('Request error:', err.message);
    res.writeHead(400);
    res.end('Bad request');
  });
});

server.listen(0, () => {
  const { port } = server.address();

  // Send a POST request with a body
  const postReq = http.request(
    { port, method: 'POST', path: '/' },
    (res) => {
      res.on('data', () => {});
      res.on('end', () => server.close());
    }
  );

  postReq.write('{"name":"Node"}');
  postReq.end();
});
```

### `http.ServerResponse` — Extends Writable

The `res` object is a writable stream:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Writable stream events
  res.on('close', () => {
    console.log('Response stream closed');
  });

  res.on('finish', () => {
    console.log('Response fully sent');
  });

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Done');
});

server.listen(0, () => {
  http.get(`http://localhost:${server.address().port}`, (res) => {
    res.on('data', () => {});
    res.on('end', () => server.close());
  });
});
```

---

## Streams — The EventEmitter Workhorses

Every stream in Node.js extends EventEmitter. The entire stream protocol is built on events.

### Readable Stream Events

```javascript
'use strict';

const { Readable } = require('node:stream');

// Custom readable that emits numbers
const counter = new Readable({
  read() {
    // Called when the consumer wants data
  }
});

// These are ALL EventEmitter events:
counter.on('data', (chunk) => {
  // Flowing mode — data pushed as fast as possible
  console.log('Data:', chunk.toString());
});

counter.on('end', () => {
  // No more data to read
  console.log('Stream ended');
});

counter.on('error', (err) => {
  console.error('Stream error:', err.message);
});

counter.on('close', () => {
  // Stream and underlying resources released
  console.log('Stream closed');
});

counter.on('readable', () => {
  // Non-flowing mode — data available to read manually
  let chunk;
  while ((chunk = counter.read()) !== null) {
    console.log('Read:', chunk.toString());
  }
});

// Push some data
counter.push('one');
counter.push('two');
counter.push(null);  // Signal end of stream
```

### Writable Stream Events

```javascript
'use strict';

const { Writable } = require('node:stream');

const sink = new Writable({
  write(chunk, encoding, callback) {
    console.log('Writing:', chunk.toString());
    callback();
  }
});

sink.on('finish', () => {
  // All data flushed to the underlying resource
  console.log('All writes complete');
});

sink.on('close', () => {
  console.log('Writable stream closed');
});

sink.on('drain', () => {
  // Internal buffer emptied — safe to write more
  console.log('Buffer drained');
});

sink.on('error', (err) => {
  console.error('Write error:', err.message);
});

sink.on('pipe', (src) => {
  // A readable stream was piped to this writable
  console.log('Something piped to this stream');
});

sink.on('unpipe', (src) => {
  console.log('Something unpiped from this stream');
});

sink.write('hello');
sink.write('world');
sink.end();
```

### The Event Flow in `pipe()`

When you call `readable.pipe(writable)`, Node.js wires up event listeners internally:

```javascript
'use strict';

const { Readable, Writable } = require('node:stream');

const source = new Readable({
  read() {}
});

const destination = new Writable({
  write(chunk, encoding, callback) {
    console.log('Piped data:', chunk.toString());
    callback();
  }
});

// pipe() internally does something like:
// source.on('data', (chunk) => destination.write(chunk));
// source.on('end', () => destination.end());
// destination.on('drain', () => source.resume());
// destination.on('error', () => source.unpipe(destination));

source.pipe(destination);

source.push('hello via pipe');
source.push(null);

destination.on('finish', () => {
  console.log('Pipe complete');
});
```

This is EventEmitter at its most powerful — complex data flow orchestrated entirely through event listeners.

---

## `fs.FSWatcher`

The `fs.watch()` function returns an `FSWatcher` object that extends EventEmitter:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

// Create a temp file to watch
const watchFile = path.join(os.tmpdir(), 'watch-test.txt');
fs.writeFileSync(watchFile, 'initial content');

const watcher = fs.watch(watchFile);

// FSWatcher extends EventEmitter
console.log(watcher instanceof require('node:events').EventEmitter);
// true

watcher.on('change', (eventType, filename) => {
  console.log(`File ${eventType}: ${filename}`);
});

watcher.on('error', (err) => {
  console.error('Watch error:', err.message);
});

watcher.on('close', () => {
  console.log('Watcher closed');
});

// Trigger a change
setTimeout(() => {
  fs.writeFileSync(watchFile, 'modified content');
}, 100);

// Clean up after 500ms
setTimeout(() => {
  watcher.close();
  fs.unlinkSync(watchFile);
}, 500);
```

The event-driven model is perfect for file watching — you don't know when a file will change, so you register a listener and the system notifies you.

---

## `child_process.ChildProcess`

Spawned child processes are EventEmitters that emit lifecycle events:

```javascript
'use strict';

const { spawn } = require('node:child_process');

const child = spawn('node', ['-e', 'console.log("hello from child"); process.exit(0)']);

// ChildProcess extends EventEmitter
console.log(child instanceof require('node:events').EventEmitter);
// true

// child.stdout is a Readable stream (EventEmitter)
child.stdout.on('data', (data) => {
  console.log('Child stdout:', data.toString().trim());
});

// child.stderr is a Readable stream (EventEmitter)
child.stderr.on('data', (data) => {
  console.error('Child stderr:', data.toString().trim());
});

// ChildProcess-specific events
child.on('spawn', () => {
  console.log('Child process spawned, PID:', child.pid);
});

child.on('exit', (code, signal) => {
  console.log(`Child exited with code ${code}, signal ${signal}`);
});

child.on('close', (code, signal) => {
  // All stdio streams closed (may fire after 'exit')
  console.log(`Child fully closed: code=${code}, signal=${signal}`);
});

child.on('error', (err) => {
  // Failed to spawn, kill, or communicate
  console.error('Child error:', err.message);
});

child.on('disconnect', () => {
  // IPC channel disconnected (only with fork)
  console.log('Child disconnected');
});
```

### The `exit` vs `close` Distinction

`exit` fires when the child process terminates. `close` fires when the stdio streams are closed. In most cases they fire in quick succession, but if the child's stdout/stderr are piped to other consumers, `close` may fire later than `exit`.

---

## The `process` Global

The `process` object itself is an EventEmitter — the most important one in any Node.js application:

```javascript
'use strict';

// process is an EventEmitter
console.log(process instanceof require('node:events').EventEmitter);
// true

// Process lifecycle events
process.on('exit', (code) => {
  // Synchronous only — cannot do async work here
  console.log(`Process exiting with code: ${code}`);
});

process.on('beforeExit', (code) => {
  // Fired when the event loop drains — chance to schedule more work
  console.log(`Event loop drained, code: ${code}`);
});

// Signal events
process.on('SIGINT', () => {
  console.log('Received SIGINT (Ctrl+C)');
  process.exit(0);
});

process.on('SIGTERM', () => {
  console.log('Received SIGTERM');
  process.exit(0);
});

// Error events
process.on('uncaughtException', (err, origin) => {
  console.error(`Uncaught exception (${origin}):`, err.message);
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection:', reason);
});

// Warning events
process.on('warning', (warning) => {
  console.warn(`Warning [${warning.name}]:`, warning.message);
});
```

Every signal handler, every crash handler, every cleanup hook is an EventEmitter listener on the `process` object.

---

## Debugging Any Core Module's Events

Since every core module is an EventEmitter, you can instrument any of them using the techniques from Lesson 01:

```javascript
'use strict';

const { EventEmitter } = require('node:events');
const http = require('node:http');

// Monkey-patch emit for debugging (development only!)
function traceEvents(emitter, label) {
  const originalEmit = emitter.emit.bind(emitter);

  emitter.emit = function (eventName, ...args) {
    if (eventName !== 'newListener' && eventName !== 'removeListener') {
      console.log(`[${label}] emit("${String(eventName)}")`,
        args.length > 0 ? `with ${args.length} arg(s)` : '');
    }
    return originalEmit(eventName, ...args);
  };
}

const server = http.createServer((req, res) => {
  res.end('OK');
});

traceEvents(server, 'http.Server');

server.listen(0, () => {
  const { port } = server.address();

  http.get(`http://localhost:${port}`, (res) => {
    res.on('data', () => {});
    res.on('end', () => server.close());
  });
});

// Output:
// [http.Server] emit("listening")
// [http.Server] emit("connection") with 1 arg(s)
// [http.Server] emit("request") with 2 arg(s)
// [http.Server] emit("close")
```

This technique works on any EventEmitter in Node.js because they all share the same `emit()` method.

---

## Key Takeaways

- **Almost every important Node.js class extends EventEmitter** — `http.Server`, `net.Socket`, all four stream types, `fs.FSWatcher`, `ChildProcess`, and the global `process` object
- **Streams are EventEmitters** — `data`, `end`, `error`, `close`, `drain`, `finish` are all standard event names used consistently across all stream types
- **`http.Server` extends `net.Server`** which extends EventEmitter — HTTP adds `request`, `upgrade`, `clientError` on top of the TCP events
- **`child_process.ChildProcess`** emits `spawn`, `exit`, `close`, `error`, and `disconnect` — and its `stdout`/`stderr` are Readable streams (more EventEmitters)
- **The debugging techniques from Lessons 01-04 apply to every core module** — `listenerCount()`, `eventNames()`, and emit tracing work on any object in the inheritance chain

## Next

[Lesson 06 — Observer Pattern & Pub/Sub](lesson-06-observer-pattern-pubsub.md) steps back from Node.js specifics to examine the design patterns behind EventEmitter — the Observer pattern and the Publish/Subscribe pattern — and builds both from scratch.
