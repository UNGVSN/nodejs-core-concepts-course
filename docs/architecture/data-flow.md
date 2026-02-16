# Data Flow — HTTP Request Lifecycle

> The journey of an HTTP request from TCP packet to response stream, traced through Node.js internals.

---

## Request Lifecycle Diagram

```mermaid
sequenceDiagram
    participant Client
    participant Kernel as OS Kernel
    participant libuv as libuv Event Loop
    participant TCP as net.Server (TCP)
    participant HTTP as http.Server (HTTP Parser)
    participant Router as Route Matcher
    participant MW as Middleware Chain
    participant Handler as Request Handler
    participant FS as fs / Stream
    participant Response as ServerResponse

    Client->>Kernel: TCP SYN (connect)
    Kernel->>Kernel: TCP handshake (SYN-ACK-ACK)
    Kernel->>libuv: Connection ready (poll phase)
    libuv->>TCP: 'connection' event
    TCP->>TCP: Create net.Socket (Duplex Stream)

    Client->>Kernel: HTTP request bytes
    Kernel->>libuv: Data available on socket
    libuv->>TCP: 'data' event on socket
    TCP->>HTTP: Feed bytes to HTTP parser (llhttp)
    HTTP->>HTTP: Parse request line + headers
    HTTP->>HTTP: Create IncomingMessage (Readable)
    HTTP->>HTTP: Create ServerResponse (Writable)
    HTTP->>Router: Emit 'request' event

    Router->>Router: Match method + pathname
    Router->>MW: Execute middleware chain

    MW->>MW: Middleware 1 (logging)
    MW->>MW: Middleware 2 (CORS headers)
    MW->>MW: Middleware 3 (body parsing)
    Note over MW: Body parsing reads request<br/>stream chunks into Buffer

    MW->>Handler: Call matched route handler

    alt Static File Response
        Handler->>FS: fs.createReadStream(filePath)
        FS->>Response: pipe(res) with backpressure
        Response->>TCP: Write to socket stream
        TCP->>Kernel: Send TCP segments
        Kernel->>Client: HTTP response bytes
    else JSON Response
        Handler->>Response: res.end(JSON.stringify(data))
        Response->>TCP: Write to socket
        TCP->>Kernel: Send TCP segments
        Kernel->>Client: HTTP response bytes
    else Streaming Response
        Handler->>Response: Write chunks over time
        loop For each chunk
            Response->>TCP: write(chunk)
            Note over Response,TCP: If write() returns false,<br/>wait for 'drain' event<br/>(backpressure)
            TCP->>Kernel: Send TCP segment
            Kernel->>Client: HTTP chunk
        end
        Handler->>Response: res.end()
    end

    Client->>Kernel: TCP FIN (close)
    Kernel->>libuv: Socket closed
    libuv->>TCP: 'close' event
    TCP->>TCP: Cleanup socket
```

---

## Phase-by-Phase Breakdown

### 1. TCP Connection (Kernel + libuv)
- Client sends TCP SYN packet
- OS kernel completes the three-way handshake (SYN → SYN-ACK → ACK)
- libuv detects the new connection during the **poll phase** of the event loop
- `net.Server` emits `'connection'` event with a new `net.Socket` (Duplex Stream)

### 2. HTTP Parsing (llhttp + http module)
- Raw bytes arrive on the TCP socket via `'data'` events
- Node.js feeds bytes to **llhttp** (the HTTP parser, written in C)
- llhttp parses the request line (`GET /api/users HTTP/1.1`) and headers
- `http.Server` creates:
  - `IncomingMessage` (Readable Stream) — the request
  - `ServerResponse` (Writable Stream) — the response
- Emits the `'request'` event with `(req, res)`

### 3. Routing
- The request handler matches `req.method` + `req.url` against registered routes
- Route parameters (`:id`) are extracted from the URL path
- Query parameters are parsed from the URL search string

### 4. Middleware Chain
- Each middleware receives `(req, res, next)`
- Middleware executes in registration order
- Common middleware: logging, CORS, body parsing, authentication
- Body parsing collects request body chunks (Buffers) and parses based on `Content-Type`

### 5. Handler Execution
- The matched route handler runs
- Can respond in three ways:
  - **Buffered:** `res.end(data)` — entire response in one call
  - **Piped:** `fs.createReadStream().pipe(res)` — stream a file
  - **Chunked:** Multiple `res.write()` calls followed by `res.end()`

### 6. Response Streaming
- `ServerResponse` is a Writable Stream wrapping the TCP socket
- Backpressure propagates: if the TCP send buffer is full, `write()` returns `false`
- Producer must pause and wait for `'drain'` before writing more
- Response headers include `Content-Type`, `Content-Length` (if known), or `Transfer-Encoding: chunked`

### 7. Connection Close
- Client or server initiates TCP FIN
- `'close'` event emitted on the socket
- Resources (file descriptors, buffers) are cleaned up

---

## Backpressure Flow

```mermaid
graph LR
    A["Source<br/>(fs.ReadStream)"] -->|"read()"| B["Internal Buffer<br/>(highWaterMark)"]
    B -->|"write(chunk)"| C["Destination<br/>(http.ServerResponse)"]
    C -->|"returns false"| D["PAUSE source"]
    C -->|"'drain' event"| E["RESUME source"]
    D -.->|"wait"| E
    E -->|"read()"| B
```

When the destination cannot keep up:
1. `write()` returns `false` (internal buffer exceeds `highWaterMark`)
2. The source **pauses** reading
3. The destination drains its buffer and emits `'drain'`
4. The source **resumes** reading
5. `pipeline()` handles this automatically; `pipe()` handles it mostly (but doesn't propagate errors)
