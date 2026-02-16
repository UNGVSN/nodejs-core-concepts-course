# Track 04 — Network Protocol Design

> HTTP is just one protocol. This track teaches you to design your own. You will learn framing, versioning, binary encoding, multiplexing, connection pooling, and the WebSocket handshake — implementing everything from scratch on raw TCP sockets.

---

## Overview

Every networked application speaks a protocol. Most developers never think about protocol design because HTTP and JSON handle the common case. But when you need custom binary protocols for performance, multiplexed streams for concurrency, connection pools for efficiency, or WebSocket for real-time communication, you need to understand how protocols are built from the ground up.

This track takes you through the full spectrum of protocol engineering. You will start with design principles — framing, versioning, extensibility — then implement a binary protocol with length-prefixed messages and checksums. You will build request-response and streaming patterns on raw TCP, implement a connection pool with health checks and load balancing, and finally implement the WebSocket protocol by hand: the HTTP upgrade handshake, frame encoding, masking, and close semantics.

All of it runs on `node:net`, `node:crypto`, and `node:http`. No `ws` package. No protocol buffers library. Just TCP sockets and your understanding of how bytes become communication.

---

## Prerequisite Modules

- **Module 03** — Buffers & Binary Data
- **Module 06** — Networking
- **Module 07** — HTTP From Scratch

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Protocol Design Principles](lesson-01-protocol-design.md) | Framing strategies, versioning schemes, extensibility, backward/forward compatibility, error signaling, idempotency |
| 02 | [Binary Protocol Implementation](lesson-02-binary-protocols.md) | Length-prefixed messages, TLV (Type-Length-Value) encoding, magic bytes, CRC checksums, building an encoder/decoder from scratch |
| 03 | [Request-Response & Streaming Protocols](lesson-03-request-response-streaming.md) | Correlation IDs, multiplexing on a single connection, pipelining, bidirectional streaming, flow control on TCP |
| 04 | [Connection Pooling & Load Balancing](lesson-04-connection-pooling.md) | Reusing TCP connections, pool sizing, round-robin and least-connections strategies, health checks, idle timeout management |
| 05 | [WebSocket Protocol](lesson-05-websocket-protocol.md) | HTTP upgrade handshake (`Sec-WebSocket-Key`), frame encoding (opcode, masking, payload length), ping/pong, close handshake — all from scratch |

---

## Who This Track Is For

- Backend engineers building custom communication layers between services (RPC, message queues, real-time feeds) that need more control than HTTP provides
- Developers working with IoT, gaming, or financial systems where binary protocols and low-latency communication are standard
- Anyone who has used WebSocket libraries but never understood the wire protocol beneath them
- Engineers who want to understand how protocols like HTTP/2, gRPC, MQTT, and Redis RESP are designed under the hood

---

## What You Will Learn

- How to design a wire protocol from scratch — choosing framing strategies, versioning schemes, and error codes that will not paint you into a corner
- How to implement a binary protocol with `Buffer` operations — writing and reading integers, encoding TLV structures, computing checksums
- How to build request-response patterns with correlation IDs and multiplexing so a single TCP connection can handle concurrent conversations
- How to implement a connection pool that manages idle connections, performs health checks, and distributes load across backend servers
- How to implement the WebSocket protocol from the ground up — the HTTP upgrade handshake, frame parsing, masking/unmasking, and the close handshake
- The design trade-offs between text protocols (simplicity, debuggability) and binary protocols (performance, compactness)
