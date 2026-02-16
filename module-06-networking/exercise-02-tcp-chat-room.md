# E02: TCP Chat Room

## Objective

Build a multi-room TCP chat server with private messaging, room management, and user nicknames — all running on raw TCP sockets with zero external dependencies. This exercise extends the echo server pattern into a stateful, multi-tenant application that manages users, rooms, message routing, and command parsing. It is a miniature version of IRC built from scratch.

## Prerequisites

- Module 06 / Lesson 03 — TCP Protocol Deep Dive
- Module 06 / Lesson 06 — The `net` Module
- Module 06 / Lesson 07 — TCP Servers and Clients
- Module 06 / Exercise 01 — TCP Echo Server

## Instructions

1. **Define the data model.** Maintain three data structures:

```js
'use strict';

const net = require('node:net');

const users = new Map();    // socket -> { nick, room }
const rooms = new Map();    // roomName -> Set<socket>
const PORT = parseInt(process.argv[2] || '4000', 10);
```

2. **Handle new connections.** When a client connects, prompt them for a nickname. Until they set a nickname, do not allow any other commands. Store the user in the `users` Map with a default room of `null`.

```js
const server = net.createServer((socket) => {
  socket.write('Welcome to ChatRoom! Set your nick: /nick <name>\n');
  users.set(socket, { nick: null, room: null });

  socket.on('data', (data) => {
    const message = data.toString().trim();
    if (!message) return;
    handleMessage(socket, message);
  });

  // ... error and cleanup handlers ...
});
```

3. **Implement command parsing.** Parse incoming messages for these commands:

| Command | Description |
|---------|-------------|
| `/nick <name>` | Set or change nickname (must be unique) |
| `/join <room>` | Join a room (leave current room first) |
| `/leave` | Leave current room |
| `/rooms` | List all active rooms with user counts |
| `/who` | List all users in the current room |
| `/msg <nick> <text>` | Send a private message to a specific user |
| `/help` | Show available commands |
| Anything else | Broadcast as a chat message to the current room |

4. **Implement `/nick`.** Validate the nickname: 3-16 alphanumeric characters. Check uniqueness across all connected users. If valid, update `users` and confirm. If the user is in a room, broadcast the name change.

5. **Implement `/join` and `/leave`.** When joining a room, create it if it does not exist. Add the socket to the room's Set. Broadcast `"<nick> has joined <room>"` to all room members. When leaving, remove the socket from the room Set. If the room is empty, delete it from the Map.

6. **Implement room broadcasting.** When a user sends a regular message (not a command), broadcast `"[room] <nick>: message"` to all other sockets in the same room. Do not send to users in other rooms.

```js
function broadcastToRoom(room, message, excludeSocket) {
  const members = rooms.get(room);
  if (!members) return;
  for (const sock of members) {
    if (sock !== excludeSocket && !sock.destroyed) {
      sock.write(message + '\n');
    }
  }
}
```

7. **Implement `/msg` for private messages.** Find the target user by nickname. If found, deliver the message as `"[PM from <sender>]: <text>"`. Send a confirmation to the sender: `"[PM to <target>]: <text>"`. If not found, inform the sender.

8. **Handle disconnections.** When a socket closes, remove the user from their room (if any), broadcast a leave message, and delete them from the `users` Map. Handle `'error'` events to prevent server crashes.

9. **Create `chat-client.js`.** A simple client using `readline` that connects to the server and provides a clean terminal interface.

```js
'use strict';

const net = require('node:net');
const readline = require('node:readline');

const PORT = parseInt(process.argv[2] || '4000', 10);
const client = net.createConnection({ port: PORT });

client.on('data', (data) => process.stdout.write(data.toString()));
client.on('end', () => { console.log('Disconnected.'); process.exit(0); });
client.on('error', (err) => { console.error('Error:', err.message); process.exit(1); });

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
rl.on('line', (line) => client.write(line + '\n'));
rl.on('close', () => client.end());
```

## Break-Then-Harden Challenge

1. **Send a message without joining a room.** The server should respond with an error: `"You must /join a room first."` Without this check, messages sent to a `null` room will either crash or disappear silently. Add the guard and test it.

2. **Allow duplicate nicknames.** Remove the uniqueness check. Now `/msg Alice` delivers to whichever Alice the Map iteration finds first. Restore the uniqueness check and verify that `/nick` rejects duplicate names with a clear error message.

3. **Kill a client mid-broadcast.** While one client sends a message that triggers a broadcast to 10 others, kill one of the recipients with `kill -9`. Without `socket.destroyed` checks and error handlers, the server crashes. Add both safeguards and verify the server survives.

## Expected Output

```
=== Client A ===
Welcome to ChatRoom! Set your nick: /nick <name>
/nick Alice
Nick set to: Alice
/join general
Joined room: general (1 member)
/who
Users in #general: Alice
Bob has joined #general
Hello everyone!
[#general] Bob: Hey Alice!
/msg Bob secret message
[PM to Bob]: secret message
/rooms
  #general (2 users)

=== Client B ===
Welcome to ChatRoom! Set your nick: /nick <name>
/nick Bob
Nick set to: Bob
/join general
Joined room: general (2 members)
[#general] Alice: Hello everyone!
Hey Alice!
[PM from Alice]: secret message
/leave
Left room: general

=== Server Log ===
Chat server listening on port 4000
[+] New connection from 127.0.0.1:55001
[nick] 127.0.0.1:55001 → Alice
[+] New connection from 127.0.0.1:55002
[nick] 127.0.0.1:55002 → Bob
[join] Alice → #general
[join] Bob → #general
[chat] #general Alice: Hello everyone!
[chat] #general Bob: Hey Alice!
[pm] Alice → Bob: secret message
[leave] Bob ← #general
```

## Bonus

1. **Message history.** Store the last 20 messages per room. When a user joins, send them the recent history so they have context. Label these messages as `"[history]"`.

2. **Admin commands.** Implement `/kick <nick>` and `/ban <nick>`. Only the first user to create a room is the room admin. Kicked users are removed from the room. Banned users cannot rejoin.

## Hints

1. TCP is a byte stream, not a message stream. A single `'data'` event may contain multiple messages or a partial message. For a chat application, split incoming data by `'\n'` and handle each line separately. Buffer incomplete lines (same pattern as E01's remainder logic).

2. Use `Array.from(users.values()).find(u => u.nick === targetNick)` to look up a user by nickname. For better performance with many users, maintain a separate `nickToSocket` Map.

3. When a user changes rooms, you must leave the old room before joining the new one. If you skip the leave step, the user appears in two rooms simultaneously — a bug that causes duplicate messages.

4. Always send a `'\n'` at the end of messages. Without it, messages concatenate on the client's terminal: `"Hello"` + `"World"` displays as `"HelloWorld"` instead of two lines.

5. The `readline` module on the client side handles line editing (backspace, arrow keys) automatically. Use it instead of raw `process.stdin` for a better user experience.
