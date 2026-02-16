# Module 07 — HTTP From Scratch: Production Decisions

> Every HTTP decision you make affects throughput, memory, and correctness under load. These are the trade-offs that separate toy servers from production ones.

---

## Decision 01: `http` Module vs Raw TCP Parsing

**Context:** Node.js gives you `http.createServer()` which handles HTTP parsing internally using llhttp (the C parser). Alternatively, you can build on `net.createServer()` and parse HTTP bytes yourself.

**Trade-offs:**

| Factor | `http` module | Raw TCP |
|--------|--------------|---------|
| Parsing correctness | Battle-tested llhttp parser handles edge cases | You own every bug in your parser |
| Performance | Optimized C code, handles keep-alive automatically | Potentially faster for narrow use cases, but likely slower overall |
| Learning value | Hides protocol details behind `req`/`res` objects | Forces you to understand every byte of HTTP |
| HTTP/2 support | Separate `node:http2` module available | You would have to implement h2 framing yourself |
| Maintenance | Node.js team maintains it | You maintain it forever |

**Recommendation:** Use `node:http` for anything that touches production traffic. Build a raw TCP parser once (Exercise 01) to internalize the protocol, then put it away. The `http` module's llhttp parser handles malformed requests, header injection attacks, and keep-alive edge cases that will take you months to get right.

---

## Decision 02: Keep-Alive Tuning

**Context:** HTTP/1.1 defaults to `Connection: keep-alive`, reusing TCP connections across multiple requests. The `http.Server` has `keepAliveTimeout` (default 5000ms) and `headersTimeout` (default 60000ms) that control how long idle connections survive.

**Trade-offs:**

| Setting | Short timeout (1-5s) | Long timeout (30-120s) |
|---------|---------------------|----------------------|
| Memory | Lower — connections freed quickly | Higher — idle sockets consume memory |
| Latency | Higher — more TCP handshakes | Lower — connection reuse avoids handshake |
| File descriptors | Fewer open at any time | Risk of fd exhaustion under load |
| Load balancer compat | May conflict with LB idle timeouts | Must be shorter than LB timeout to avoid resets |

**Recommendation:** Set `keepAliveTimeout` to 5-15 seconds for API servers (clients reconnect quickly) and 30-60 seconds for servers behind a reverse proxy. Always set your server's keep-alive timeout shorter than the load balancer's to prevent the LB from sending requests on a connection the server just closed. Use `server.maxRequestsPerSocket` (Node.js 16.10+) to cap requests per connection and prevent connection pinning.

---

## Decision 03: Chunked Transfer-Encoding vs Content-Length

**Context:** HTTP responses can declare their size upfront (`Content-Length: 4096`) or stream in chunks (`Transfer-Encoding: chunked`). When you call `res.write()` multiple times without setting `Content-Length`, Node.js automatically uses chunked encoding.

**Trade-offs:**

| Factor | Content-Length | Chunked |
|--------|---------------|---------|
| Client UX | Progress bars work, download size known | No progress percentage, size unknown |
| Memory | Must know full size upfront (buffer or `stat`) | Can stream without buffering |
| Caching | Proxies can cache reliably | Some older proxies struggle with chunked |
| Latency | First byte delayed until size known | First byte sent immediately |
| Error handling | Cannot change status code after headers sent | Same limitation, but partial data already sent |

**Recommendation:** Use `Content-Length` when you know the response size (static files via `fs.stat`, JSON payloads buffered in memory). Use chunked encoding for streaming responses (server-sent events, large generated content, proxied responses). For static files, always `stat` first and set `Content-Length` — it enables client progress bars and allows proxies to cache correctly.

---

## Decision 04: Header Size Limits

**Context:** Node.js's HTTP parser enforces `--max-http-header-size` (default 16 KiB since Node.js 14). Oversized headers — often caused by large cookies, JWTs in headers, or request smuggling attacks — trigger a `431 Request Header Fields Too Large` error.

**Trade-offs:**

| Limit | Lower (8 KiB) | Default (16 KiB) | Higher (32-64 KiB) |
|-------|---------------|-------------------|---------------------|
| Security | Blocks most header injection attacks | Reasonable protection | More attack surface |
| Compatibility | May reject legitimate auth tokens | Handles most JWTs | Handles oversized enterprise tokens |
| Memory | Less per-request overhead | Moderate | More memory per connection for header parsing |
| Cookie support | May reject sites with many cookies | Usually sufficient | Needed for cookie-heavy apps |

**Recommendation:** Keep the 16 KiB default unless you have a specific reason to change it. If your JWTs exceed 8 KiB, that is a sign you are putting too much data in the token — move claims to a server-side session. If you must increase, set it via `--max-http-header-size=32768` at startup, never in application code. Always validate `Content-Length` against a maximum body size to prevent memory exhaustion.

---

## Decision 05: `http.Agent` Connection Pooling

**Context:** When your Node.js server makes outbound HTTP requests (to microservices, APIs), `http.Agent` manages a pool of keep-alive TCP connections. The default global agent creates a new connection per request unless you configure pooling.

**Trade-offs:**

| Config | No pooling (default agent) | Custom agent with pooling |
|--------|---------------------------|--------------------------|
| Latency | TCP handshake per request | Reuse warm connections |
| File descriptors | Connections closed immediately | Pooled connections held open |
| Memory | Lower steady-state | Higher — idle sockets in pool |
| DNS changes | Always resolves fresh | Cached connections may hit stale IP |
| Error isolation | Connection failure affects one request | Bad connection can affect queued requests |

**Recommendation:** Create a dedicated `http.Agent` with `keepAlive: true` and `maxSockets` set to 50-100 per host for outbound API calls. Set `maxFreeSockets` to 10-25 so you keep warm connections without hoarding. Use `scheduling: 'lifo'` (Node.js 19+) to prefer recently-used sockets, which plays better with load balancers that track active connections. For services behind DNS round-robin, set `maxSockets` lower and `keepAlive` timeout shorter to pick up DNS changes.

---

## Decision 06: Request Timeout Strategies

**Context:** HTTP requests can hang indefinitely — slow clients, network partitions, or upstream services that never respond. Node.js provides `server.timeout`, `server.requestTimeout`, and `req.setTimeout()`, each controlling different phases.

**Trade-offs:**

| Timeout | `server.timeout` (socket idle) | `server.requestTimeout` (full request) | `req.setTimeout` (per-request) |
|---------|-------------------------------|---------------------------------------|-------------------------------|
| Scope | Entire socket lifetime | Time to receive complete request | Individual request handler |
| Default | 0 (no timeout) | 300000ms (5 min) | Inherits from server |
| Slowloris defense | Helps if set low | Best defense — limits total request time | Does not help, only fires once |
| File uploads | May kill large uploads | Will kill uploads that exceed timeout | Can be set per-route |
| Granularity | Coarse — all connections same | Coarse — all requests same | Fine — different per endpoint |

**Recommendation:** Set `server.requestTimeout` to 30-60 seconds to defend against Slowloris attacks. For routes that accept large file uploads, use `req.setTimeout(300000)` on those specific requests to allow longer transfers. Set `server.timeout` to 120 seconds as a backstop for truly stuck connections. Always implement `server.on('timeout', (socket) => socket.destroy())` to actually close timed-out sockets — the default only emits the event without destroying.
