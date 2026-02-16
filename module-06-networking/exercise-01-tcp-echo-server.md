# E01: TCP Echo Server

## Objective

Build a TCP echo server that accepts multiple concurrent client connections, echoes back every message it receives, and cleanly handles client disconnections and errors. You will track connected clients, broadcast join/leave notifications, and implement a graceful shutdown sequence. This is the foundational networking exercise — every concept here applies to every TCP server you will ever build.

## Prerequisites

- Module 06 / Lesson 01 — Network Fundamentals
- Module 06 / Lesson 03 — TCP Protocol Deep Dive
- Module 06 / Lesson 06 — The `net` Module
- Module 06 / Lesson 07 — TCP Servers and Clients

## Instructions

1. **Create `echo-server.js`.** Use `require('node:net').createServer()` to create a TCP server that listens on a configurable port (default 3000).

```js
'use strict';

const net = require('node:net');

const PORT = parseInt(process.argv[2] || '3000', 10);
const clients = new Map();
let clientIdCounter = 0;

const server = net.createServer((socket) => {
  const id = ++clientIdCounter;
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  clients.set(id, { socket, addr });

  console.log(`[+] Client #${id} connected from ${addr} (total: ${clients.size})`);
  socket.write(`Welcome, you are client #${id}\n`);

  // ... event handlers ...
});

server.listen(PORT, () => {
  console.log(`Echo server listening on port ${PORT}`);
});
```

2. **Echo data back.** On the `'data'` event, write the received data back to the same socket. Also log the message to the server console with the client ID.

3. **Track connected clients.** Maintain a `Map` of `{ id -> { socket, addr } }`. When a client connects, add it. When a client disconnects (via `'end'` or `'close'`), remove it. Print the current client count after each join/leave.

4. **Broadcast join/leave messages.** When a client connects, send `"Client #N has joined"` to all other connected clients. When a client disconnects, send `"Client #N has left"` to all remaining clients.

```js
function broadcast(message, excludeId) {
  for (const [id, client] of clients) {
    if (id !== excludeId) {
      client.socket.write(message);
    }
  }
}
```

5. **Handle errors per socket.** Attach an `'error'` handler to every socket. Log the error and clean up the client entry. Without this, a client that crashes (TCP RST) will throw an unhandled exception and kill your server.

6. **Implement graceful shutdown.** Listen for `SIGINT` (`Ctrl+C`). When received, send a `"Server shutting down"` message to all clients, destroy all sockets, close the server, and exit.

```js
process.on('SIGINT', () => {
  console.log('\nShutting down...');
  for (const [id, client] of clients) {
    client.socket.end('Server shutting down.\n');
  }
  server.close(() => {
    console.log('Server closed.');
    process.exit(0);
  });
});
```

7. **Create `echo-client.js`.** A simple client that connects to the server, reads from `process.stdin`, sends each line to the server, and prints the echoed response.

```js
'use strict';

const net = require('node:net');
const readline = require('node:readline');

const PORT = parseInt(process.argv[2] || '3000', 10);
const client = net.createConnection({ port: PORT }, () => {
  console.log('Connected to echo server. Type messages:');
});

client.on('data', (data) => {
  process.stdout.write(`[echo] ${data}`);
});

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  client.write(line + '\n');
});

client.on('end', () => {
  console.log('Disconnected from server.');
  process.exit(0);
});
```

8. **Test with multiple clients.** Open three terminal windows. Start the server in one. Connect two clients. Send messages from each and observe that echoes are independent, and join/leave broadcasts are delivered to the other client.

## Break-Then-Harden Challenge

1. **Remove the `'error'` handler on sockets.** Connect a client, then kill it with `kill -9` (or close the terminal window abruptly). The server crashes with `ECONNRESET`. Add the error handler back and verify the server survives the same scenario.

2. **Do not remove disconnected clients from the Map.** After a client disconnects, try broadcasting to all clients. The broadcast will attempt to write to a destroyed socket, throwing an error. Add proper cleanup in `'close'` or `'end'` and confirm the broadcast skips removed clients.

3. **Flood the server.** Write a script that opens 1,000 concurrent connections and sends data rapidly. Without per-connection error handling and proper cleanup, the server will leak sockets and eventually hit the file descriptor limit. Add `server.maxConnections` to limit concurrent clients and observe the behavior.

## Expected Output

```
=== Server Terminal ===
Echo server listening on port 3000
[+] Client #1 connected from 127.0.0.1:54321 (total: 1)
[+] Client #2 connected from 127.0.0.1:54322 (total: 2)
[echo #1] Hello from client 1
[echo #2] Hello from client 2
[-] Client #1 disconnected (total: 1)
^C
Shutting down...
Server closed.

=== Client 1 Terminal ===
Connected to echo server. Type messages:
Welcome, you are client #1
Client #2 has joined
Hello from client 1
[echo] Hello from client 1
Server shutting down.
Disconnected from server.

=== Client 2 Terminal ===
Connected to echo server. Type messages:
Welcome, you are client #2
Hello from client 2
[echo] Hello from client 2
Client #1 has left
Server shutting down.
Disconnected from server.
```

## Bonus

1. **Add a `/stats` command.** When a client sends `/stats`, respond with server uptime, total connections served, current connection count, and total bytes echoed.

2. **Add connection timeout.** If a client sends no data for 30 seconds, send a warning. If no data for 60 seconds, disconnect them. Use `socket.setTimeout()`.

## Hints

1. `net.createServer(callback)` calls the callback once per incoming connection. The `socket` argument is a Duplex stream — you can read from it and write to it.

2. The `'close'` event on a socket fires after the socket is fully closed (after `'end'`). Use `'close'` for cleanup rather than `'end'`, because `'close'` always fires, even on errors.

3. `socket.remoteAddress` and `socket.remotePort` give you the client's address. Log these for debugging — when something goes wrong, you need to know which client caused it.

4. `socket.destroy()` forcefully closes the connection (sends RST). `socket.end()` sends FIN for a graceful close. Prefer `end()` for normal shutdown and `destroy()` for error cases.

5. Always check `socket.destroyed` before writing to a socket. If the client disconnected between your check and your write, the socket may already be destroyed.
