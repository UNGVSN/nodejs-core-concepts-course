# Module Dependencies

> How the 10 course modules build on each other. Complete modules in order for the best learning experience.

---

## Dependency Diagram

```mermaid
graph TD
    M01["Module 01<br/>Architecture & Event Loop"]
    M02["Module 02<br/>EventEmitter"]
    M03["Module 03<br/>Buffers & Binary Data"]
    M04["Module 04<br/>File System"]
    M05["Module 05<br/>Streams"]
    M06["Module 06<br/>Networking"]
    M07["Module 07<br/>HTTP From Scratch"]
    M08["Module 08<br/>Unix, Processes & IPC"]
    M09["Module 09<br/>Multi-Threading"]
    M10["Module 10<br/>Crypto, Compression & Security"]

    M01 --> M02
    M01 --> M03
    M02 --> M05
    M03 --> M05
    M03 --> M04
    M04 --> M05
    M05 --> M06
    M05 --> M10
    M06 --> M07
    M01 --> M08
    M08 --> M09
    M07 --> M10
    M09 --> M10

    %% Capstone Projects
    P01["Project 01<br/>Production HTTP Server"]
    P02["Project 02<br/>Real-Time Chat"]
    P03["Project 03<br/>File Processing Pipeline"]
    P04["Project 04<br/>Mini Process Manager"]

    M10 --> P01
    M06 --> P02
    M10 --> P02
    M09 --> P03
    M10 --> P03
    M09 --> P04

    %% Specialized Tracks
    T1["Track 01<br/>Performance"]
    T2["Track 02<br/>Security"]
    T3["Track 03<br/>Systems Programming"]
    T4["Track 04<br/>Network Protocols"]

    M09 --> T1
    M10 --> T2
    M08 --> T3
    M07 --> T4

    style M01 fill:#4a9eff,color:#fff
    style M02 fill:#4a9eff,color:#fff
    style M03 fill:#4a9eff,color:#fff
    style M04 fill:#6abf69,color:#fff
    style M05 fill:#6abf69,color:#fff
    style M06 fill:#f5a623,color:#fff
    style M07 fill:#f5a623,color:#fff
    style M08 fill:#e74c3c,color:#fff
    style M09 fill:#e74c3c,color:#fff
    style M10 fill:#9b59b6,color:#fff
    style P01 fill:#2c3e50,color:#fff
    style P02 fill:#2c3e50,color:#fff
    style P03 fill:#2c3e50,color:#fff
    style P04 fill:#2c3e50,color:#fff
    style T1 fill:#1abc9c,color:#fff
    style T2 fill:#1abc9c,color:#fff
    style T3 fill:#1abc9c,color:#fff
    style T4 fill:#1abc9c,color:#fff
```

---

## Module Progression Tiers

### Tier 1 — Foundations (Modules 01–03)
These three modules establish the core primitives everything else is built on.

| Module | Concepts | Why First |
|--------|----------|-----------|
| 01 Architecture | Event loop, V8, libuv, module system | You can't understand Node.js without understanding how it executes code |
| 02 EventEmitter | Events, listeners, observer pattern | Every I/O object in Node.js is an EventEmitter |
| 03 Buffers | Binary data, encodings, memory | All I/O operations pass through Buffers |

### Tier 2 — I/O Primitives (Modules 04–05)
File system and streams use everything from Tier 1.

| Module | Depends On | Why This Order |
|--------|-----------|----------------|
| 04 File System | 01 (async model), 03 (Buffers) | File operations return/accept Buffers, rely on the event loop |
| 05 Streams | 02 (EventEmitter), 03 (Buffers), 04 (fs) | Streams extend EventEmitter, process Buffers, and wrap fs operations |

### Tier 3 — Network (Modules 06–07)
Networking and HTTP build on streams and binary data.

| Module | Depends On | Why This Order |
|--------|-----------|----------------|
| 06 Networking | 03 (Buffers), 05 (Streams) | TCP sockets are Duplex Streams carrying binary data |
| 07 HTTP | 06 (TCP), 05 (Streams) | HTTP is a protocol on top of TCP; req/res are Streams |

### Tier 4 — System (Modules 08–09)
Process management and threading are advanced topics requiring solid foundations.

| Module | Depends On | Why This Order |
|--------|-----------|----------------|
| 08 Unix & Processes | 01 (event loop), 05 (Streams) | Child process stdio are Streams; understanding the event loop is critical for IPC |
| 09 Multi-Threading | 01 (event loop), 03 (Buffers), 08 (processes) | Need to understand single-threaded model before adding threads; SharedArrayBuffer relates to Buffers |

### Tier 5 — Security & Production (Module 10)
The capstone module that ties everything together.

| Module | Depends On | Why Last |
|--------|-----------|----------|
| 10 Crypto/Compression/Security | 05 (Streams), 07 (HTTP), 09 (threads) | Crypto operations are Transform Streams; TLS wraps HTTP; some crypto benefits from worker threads |

---

## Progressive Project Dependencies

Each step of "Build Your Own HTTP Framework" requires the corresponding module:

```
Step 01 (Event Dispatcher)     ← Module 01
Step 02 (Middleware Chain)     ← Module 02 + Step 01
Step 03 (Body Parsing)         ← Module 03 + Step 02
Step 04 (Static Files)         ← Module 04 + Step 03
Step 05 (Streaming Responses)  ← Module 05 + Step 04
Step 06 (TCP Foundation)       ← Module 06 + Step 05
Step 07 (HTTP Protocol)        ← Module 07 + Step 06
Step 08 (Process Workers)      ← Module 08 + Step 07
Step 09 (Thread Workers)       ← Module 09 + Step 08
Step 10 (HTTPS + Compression)  ← Module 10 + Step 09
```
