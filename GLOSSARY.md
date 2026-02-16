# Glossary

Key terms used throughout this course. Terms are grouped by domain.

---

## Runtime & Architecture

**Node.js** — A JavaScript runtime built on Chrome's V8 engine and libuv, designed for building scalable network applications with non-blocking I/O.

**V8** — Google's open-source JavaScript engine written in C++. Compiles JavaScript to machine code via JIT (Just-In-Time) compilation.

**libuv** — A C library that provides Node.js with its event loop, thread pool, and cross-platform asynchronous I/O (file system, networking, DNS).

**Event Loop** — The mechanism that allows Node.js to perform non-blocking I/O by offloading operations to the OS kernel or libuv thread pool, then processing callbacks when operations complete.

**Event Loop Phases** — The six phases the event loop cycles through: timers, pending callbacks, idle/prepare, poll, check, close callbacks.

**Call Stack** — The LIFO (Last-In-First-Out) data structure where JavaScript function calls are tracked. A single call stack means single-threaded execution.

**Callback Queue** — Where callbacks from completed async operations wait to be pushed onto the call stack by the event loop.

**Microtask Queue** — A higher-priority queue (Promises, `process.nextTick`, `queueMicrotask`) drained completely between each event loop phase.

**JIT Compilation** — Just-In-Time compilation: V8 compiles JavaScript to machine code at runtime rather than interpreting it.

**Hidden Classes** — V8's optimization for object property access. Objects with the same property order share hidden classes for faster lookups.

**Inline Caching** — V8 optimization that caches the result of property lookups to speed up repeated access patterns.

**Garbage Collection** — V8's automatic memory management. Uses generational collection: Scavenge (young generation) and Mark-Sweep/Mark-Compact (old generation).

---

## Events

**EventEmitter** — The foundational class in `node:events`. Objects that emit named events and register listener functions.

**Listener** — A function registered with `on()` or `addListener()` that executes when a specific event is emitted.

**Observer Pattern** — A design pattern where an object (subject) maintains a list of dependents (observers) and notifies them of state changes. EventEmitter implements this pattern.

---

## Binary Data

**Buffer** — A fixed-size chunk of memory allocated outside the V8 heap, used for handling binary data (TCP streams, file I/O, etc.).

**Binary** — Base-2 number system using only 0 and 1. The fundamental representation of all data in computers.

**Hexadecimal** — Base-16 number system (0-9, A-F). Commonly used to represent binary data compactly (two hex digits = one byte).

**Byte** — 8 bits. The fundamental unit of data storage. Range: 0–255 (unsigned) or -128–127 (signed).

**Endianness** — The order in which bytes are arranged in multi-byte values. Big-endian (BE): most significant byte first. Little-endian (LE): least significant byte first.

**Character Encoding** — A mapping between characters and byte sequences. Common encodings: ASCII (7-bit), UTF-8 (variable 1–4 bytes), UTF-16 (2 or 4 bytes), Latin-1 (1 byte).

**UTF-8** — Variable-length Unicode encoding. ASCII-compatible (1 byte for ASCII characters), up to 4 bytes for other characters. The dominant encoding on the web.

**ArrayBuffer** — A fixed-length raw binary data buffer in JavaScript. Buffers are built on top of ArrayBuffer.

**TypedArray** — A view into an ArrayBuffer (`Uint8Array`, `Int32Array`, `Float64Array`, etc.) providing typed access to binary data.

---

## File System

**File Descriptor (fd)** — An integer that the OS uses to identify an open file. Obtained via `fs.open()`, must be closed with `fs.close()`.

**Inode** — A data structure in Unix-like file systems storing metadata about a file (permissions, ownership, timestamps, block locations).

**Symlink** — A symbolic link: a file that points to another file or directory by path. Resolved by `fs.readlink()`.

**Atomic Write** — Writing to a temporary file then renaming it to the target, preventing partial/corrupt writes on crash.

---

## Streams

**Stream** — An abstract interface for working with streaming data in Node.js. Four types: Readable, Writable, Duplex, Transform.

**Readable Stream** — A stream you can read data from (`fs.createReadStream`, `http.IncomingMessage`).

**Writable Stream** — A stream you can write data to (`fs.createWriteStream`, `http.ServerResponse`).

**Duplex Stream** — A stream that is both Readable and Writable (`net.Socket`, `crypto.Cipher`).

**Transform Stream** — A Duplex stream where the output is computed from the input (`zlib.createGzip`, `crypto.createCipheriv`).

**Backpressure** — A mechanism to prevent a fast producer from overwhelming a slow consumer. When `write()` returns `false`, the producer must wait for the `'drain'` event.

**highWaterMark** — The maximum number of bytes (or objects in object mode) a stream buffer will hold before stopping reads from the source.

**Piping** — Connecting a Readable to a Writable via `pipe()` or `stream.pipeline()`, automatically handling backpressure.

**Flowing Mode** — A Readable stream mode where data is read automatically and provided via `'data'` events as fast as possible.

**Paused Mode** — A Readable stream mode where data must be explicitly read by calling `stream.read()`.

**Object Mode** — A stream mode where the stream operates on JavaScript objects instead of Buffers/strings.

---

## Networking

**Socket** — An endpoint for communication between two machines. In Node.js, `net.Socket` represents a TCP socket.

**TCP (Transmission Control Protocol)** — A reliable, ordered, connection-oriented protocol. Ensures all packets arrive and in order.

**UDP (User Datagram Protocol)** — A connectionless, unreliable protocol. Fast but no delivery guarantee. Used for DNS, gaming, video streaming.

**Three-Way Handshake** — TCP connection establishment: SYN → SYN-ACK → ACK.

**Port** — A 16-bit number (0–65535) identifying a specific process or service on a host.

**IP Address** — A numerical label assigned to a device on a network. IPv4: 32-bit (e.g., 192.168.1.1). IPv6: 128-bit.

**MAC Address** — A hardware address uniquely identifying a network interface card (NIC). 48 bits, usually written as six hex pairs.

**DNS (Domain Name System)** — Translates domain names (example.com) to IP addresses (93.184.216.34).

**Nagle's Algorithm** — TCP optimization that buffers small packets before sending. Disabled with `socket.setNoDelay(true)`.

---

## HTTP

**HTTP (HyperText Transfer Protocol)** — An application-layer protocol for transmitting hypermedia documents. Request-response model over TCP.

**Request Line** — The first line of an HTTP request: `METHOD PATH HTTP/VERSION` (e.g., `GET /api/users HTTP/1.1`).

**Status Line** — The first line of an HTTP response: `HTTP/VERSION STATUS_CODE REASON_PHRASE` (e.g., `HTTP/1.1 200 OK`).

**MIME Type** — A label identifying the type of data in an HTTP body (e.g., `application/json`, `text/html`, `image/png`).

**CORS (Cross-Origin Resource Sharing)** — A mechanism allowing servers to indicate which origins can access their resources via HTTP headers.

**Keep-Alive** — An HTTP/1.1 feature that reuses TCP connections for multiple requests, avoiding the overhead of repeated handshakes.

**Chunked Transfer Encoding** — An HTTP mechanism where the response body is sent in chunks, each prefixed with its size. Allows streaming without knowing total size upfront.

**Idempotent** — An HTTP method is idempotent if making the same request multiple times has the same effect as making it once (GET, PUT, DELETE are idempotent; POST is not).

---

## Unix & Processes

**Process** — An instance of a running program. Has its own memory space, file descriptors, and PID (Process ID).

**PID (Process ID)** — A unique integer assigned by the OS to each running process.

**IPC (Inter-Process Communication)** — Mechanisms for processes to exchange data: pipes, sockets, message passing, shared memory.

**Signal** — An asynchronous notification sent to a process. Common signals: `SIGINT` (Ctrl+C), `SIGTERM` (termination request), `SIGHUP` (hangup).

**Graceful Shutdown** — Handling `SIGTERM`/`SIGINT` by finishing in-flight requests, closing connections, and releasing resources before exiting.

**Child Process** — A process spawned by another process (`child_process.spawn`, `fork`, `exec`).

**Cluster** — Node.js module that forks multiple worker processes sharing the same server port for load distribution.

**Fork** — Creating a child process that is a copy of the parent. In Node.js, `cluster.fork()` or `child_process.fork()`.

**stdin/stdout/stderr** — Standard input, standard output, and standard error. File descriptors 0, 1, and 2.

**Exit Code** — A number returned by a process when it terminates. 0 = success, non-zero = error.

---

## Multi-Threading

**Thread** — The smallest unit of execution within a process. Threads share the process's memory space.

**Worker Thread** — A Node.js thread created via `worker_threads.Worker`. Runs JavaScript in parallel with the main thread.

**SharedArrayBuffer** — An ArrayBuffer that can be shared between threads without copying data.

**Atomics** — A JavaScript object providing atomic operations on `SharedArrayBuffer` for safe concurrent access.

**Race Condition** — A bug where the behavior depends on the timing/order of thread execution. Occurs when threads access shared data without synchronization.

**Deadlock** — A state where two or more threads are waiting for each other to release resources, resulting in all threads being permanently blocked.

**Mutex (Mutual Exclusion)** — A synchronization primitive ensuring only one thread can access a critical section at a time.

**Semaphore** — A synchronization primitive that controls access to a shared resource by maintaining a counter.

**Thread Pool** — A fixed set of pre-created threads that execute queued tasks, avoiding the overhead of creating/destroying threads.

**Transferable Object** — An object that can be transferred (not copied) between threads, making the source thread lose access. Applies to `ArrayBuffer`, `MessagePort`.

---

## Cryptography

**Symmetric Encryption** — Encryption where the same key is used to encrypt and decrypt (e.g., AES).

**Asymmetric Encryption** — Encryption using a key pair: public key encrypts, private key decrypts (e.g., RSA).

**AES (Advanced Encryption Standard)** — A symmetric block cipher. AES-256-GCM is the recommended mode in Node.js.

**RSA** — An asymmetric encryption algorithm based on the difficulty of factoring large prime numbers.

**Diffie-Hellman** — A key exchange protocol allowing two parties to establish a shared secret over an insecure channel.

**ECDH (Elliptic Curve Diffie-Hellman)** — Diffie-Hellman using elliptic curve cryptography. Smaller keys, same security level.

**Hash Function** — A one-way function that maps input to a fixed-size output (digest). SHA-256, SHA-512, MD5.

**HMAC (Hash-based Message Authentication Code)** — A hash combined with a secret key, providing both integrity and authenticity.

**Salt** — Random data added to a password before hashing, preventing rainbow table attacks.

**TLS (Transport Layer Security)** — A cryptographic protocol providing secure communication over a network. HTTPS = HTTP over TLS.

**Digital Signature** — A cryptographic proof that a message was created by a specific sender and wasn't altered.

**X.509 Certificate** — A standard format for public key certificates, used in TLS/HTTPS.

**IV (Initialization Vector)** — A random value used with encryption to ensure identical plaintexts produce different ciphertexts.

**Key Derivation** — Generating a cryptographic key from a password or other input (`scrypt`, `pbkdf2`).

---

## Compression

**Gzip** — A compression format based on DEFLATE. Widely used in HTTP (`Content-Encoding: gzip`).

**Deflate** — A compression algorithm combining LZ77 and Huffman coding.

**Brotli** — A compression algorithm by Google. Better compression ratio than gzip, supported by modern browsers.

**Zlib** — The Node.js module providing gzip, deflate, and brotli compression/decompression.

---

## General

**CommonJS (CJS)** — Node.js module system using `require()` and `module.exports`.

**ESM (ECMAScript Modules)** — Standard JavaScript module system using `import` and `export`.

**REPL (Read-Eval-Print Loop)** — An interactive programming environment. Node.js provides a built-in REPL via the `node` command.

**Backoff** — A strategy for retrying failed operations with increasing delays (e.g., exponential backoff).

**Idempotent** — An operation that produces the same result whether executed once or multiple times.
