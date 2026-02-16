# Project 02 — Real-Time Chat System

> Forget WebSocket libraries and Socket.io. You are going to build a multi-room chat system directly on raw TCP sockets with a custom binary protocol, encrypted messages, and file transfer — all using nothing but Node.js core modules.

---

## Overview

This capstone project takes your networking, buffer, and process management skills and combines them into a real-time chat system that runs on raw TCP. You will design a custom binary wire protocol, implement room management, support private messaging and file transfers, persist message history to disk, and scale the server across multiple processes with `node:cluster`.

Every byte that crosses the wire is one you designed. Every message that gets encrypted is one you encrypted yourself with `node:crypto`. There is no abstraction layer hiding the complexity — you own the entire stack from TCP socket to chat message.

---

## Prerequisite Modules

- **Module 02** — EventEmitter & Event-Driven Patterns
- **Module 03** — Buffers & Binary Data
- **Module 06** — Networking
- **Module 08** — Unix, Processes & IPC
- **Module 10** — Cryptography, Compression & Security

---

## Features to Build

- **Custom binary protocol** — message type byte, 4-byte length prefix, payload; supports text, system, file-transfer, and heartbeat message types
- **Room management** — create rooms, join/leave rooms, list active rooms and their member counts
- **Private messaging** — send direct messages between users by username
- **File transfer** — stream files between clients over TCP, chunked with progress reporting
- **Message history** — persist messages to disk as an append-only log file per room; replay history on room join
- **Heartbeat / keepalive** — server pings clients on a configurable interval; disconnects unresponsive clients after timeout
- **Cluster mode** — run multiple server workers sharing the same TCP port via `node:cluster`, with IPC for cross-worker message routing
- **AES-encrypted messages** — clients encrypt message payloads with AES-256-CBC using a shared room key derived from a passphrase via `node:crypto`

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│              chat-server.js (master)              │
│                                                  │
│  ┌──────────┐                                    │
│  │ Cluster  │──▶ Worker 1 ──▶ TCP Server         │
│  │ Manager  │──▶ Worker 2 ──▶ TCP Server         │
│  │          │──▶ Worker N ──▶ TCP Server         │
│  └──────────┘                                    │
│       │                                          │
│       │ IPC (cross-worker message routing)        │
│       ▼                                          │
│  ┌──────────────────────────────────────────┐    │
│  │            Per-Worker Internals           │    │
│  │                                          │    │
│  │  ┌────────────┐  ┌──────────────────┐   │    │
│  │  │  Protocol   │  │  Room Manager    │   │    │
│  │  │  Parser     │  │  (join/leave/    │   │    │
│  │  │  (binary)   │  │   broadcast)     │   │    │
│  │  └─────┬──────┘  └───────┬──────────┘   │    │
│  │        │                  │              │    │
│  │        ▼                  ▼              │    │
│  │  ┌────────────┐  ┌──────────────────┐   │    │
│  │  │  AES-256   │  │  History Writer  │   │    │
│  │  │  Encrypt/  │  │  (append-only    │   │    │
│  │  │  Decrypt   │  │   log per room)  │   │    │
│  │  └────────────┘  └──────────────────┘   │    │
│  │                                          │    │
│  │  ┌────────────┐  ┌──────────────────┐   │    │
│  │  │ Heartbeat  │  │  File Transfer   │   │    │
│  │  │ Monitor    │  │  (chunked)       │   │    │
│  │  └────────────┘  └──────────────────┘   │    │
│  └──────────────────────────────────────────┘    │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│              chat-client.js                       │
│                                                  │
│  ┌────────────┐  ┌──────────┐  ┌─────────────┐  │
│  │ TCP Socket │  │ Protocol │  │ AES Encrypt │  │
│  │ Connection │──▶│ Encoder  │──▶│ / Decrypt   │  │
│  └────────────┘  └──────────┘  └─────────────┘  │
│                                                  │
│  ┌────────────┐  ┌──────────┐                    │
│  │ readline   │  │  File    │                    │
│  │ Interface  │  │  Sender  │                    │
│  └────────────┘  └──────────┘                    │
└──────────────────────────────────────────────────┘
```

**Wire protocol format:**

```
┌──────┬──────────┬──────────┬──────────────────┐
│ Type │  Length   │  Flags   │     Payload      │
│ 1B   │  4B (BE) │  1B      │  Variable        │
└──────┴──────────┴──────────┴──────────────────┘

Type: 0x01=TEXT, 0x02=SYSTEM, 0x03=FILE, 0x04=HEARTBEAT, 0x05=PRIVATE
Flags: bit 0 = encrypted, bit 1 = compressed
```

---

## Deliverables

| File | Description |
|------|-------------|
| `chat-server.js` | TCP server with cluster support, room management, and message routing |
| `chat-client.js` | Interactive TCP client with `node:readline` interface |
| `lib/protocol.js` | Binary protocol encoder/decoder (serialize and parse wire messages) |
| `lib/rooms.js` | Room management — create, join, leave, broadcast, member tracking |
| `lib/encryption.js` | AES-256-CBC encrypt/decrypt with passphrase-derived keys via `node:crypto` |
| `lib/history.js` | Append-only message history writer/reader per room |
| `lib/file-transfer.js` | Chunked file transfer with progress events |
| `docs/protocol-spec.md` | Protocol specification document (message types, encoding, error codes) |
| `test/load-test.js` | Load test simulating 100 concurrent users sending messages across rooms |

---

## Acceptance Criteria

- [ ] Client connects to server over raw TCP and authenticates with a username
- [ ] Binary protocol correctly encodes and decodes all message types
- [ ] Users can create rooms, join rooms, leave rooms, and list rooms with member counts
- [ ] Messages broadcast to all room members arrive intact and in order
- [ ] Private messages route only to the intended recipient
- [ ] Files up to 10MB transfer between clients with chunked streaming and progress output
- [ ] Message history is persisted to disk; joining a room replays the last 50 messages
- [ ] Heartbeat detects and disconnects unresponsive clients within 2x the ping interval
- [ ] Cluster mode distributes connections across workers; cross-worker messages route via IPC
- [ ] Encrypted messages cannot be read by inspecting raw TCP traffic (verify with a packet dump)
- [ ] Load test: 100 concurrent clients across 10 rooms, sustained for 60 seconds, zero message loss
- [ ] Zero npm packages — only `require('node:...')` imports

---

## Estimated Effort

**12-15 hours** for a developer who has completed the prerequisite modules.

| Phase | Hours |
|-------|-------|
| Binary protocol design + encoder/decoder | 2-3 |
| TCP server + room management | 2-3 |
| Client with readline interface | 1-2 |
| Private messaging + file transfer | 2-3 |
| Message history (append-only log) | 1-2 |
| Heartbeat + cluster mode + IPC routing | 2-3 |
| AES encryption layer | 1-2 |
| Load testing + bug fixes | 1-2 |

---

## Hints

- Buffer your incoming TCP data — TCP is a stream protocol, so a single `data` event may contain partial messages or multiple messages concatenated together
- Use `Buffer.allocUnsafe()` for the protocol encoder (you are filling every byte anyway) and `Buffer.alloc()` for anything security-related
- Derive encryption keys from passphrases with `crypto.scryptSync(passphrase, salt, 32)` for AES-256
- For the load test, create 100 `net.Socket` instances that each join a random room and send messages on a timer
- Cross-worker message routing in cluster mode requires the master process to relay via `worker.send()` and `process.on('message')`
