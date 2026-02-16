# Module 06 — Networking: Production Decisions

> Networking code runs 24/7 and faces hostile inputs, unreliable connections, and platform-specific surprises. These decisions address the trade-offs you encounter the moment your TCP server leaves localhost.

---

## Decision 1: TCP vs UDP Selection Criteria

**Context:**
TCP provides reliable, ordered, connection-oriented delivery. UDP provides fast, connectionless, best-effort delivery. The choice is not always obvious — some applications (DNS, gaming, video) deliberately choose UDP's speed over TCP's guarantees, while others (HTTP, database connections, file transfer) require TCP's reliability.

**Trade-offs:**

| Protocol | Pros | Cons |
|----------|------|------|
| TCP | Guaranteed delivery, ordering, flow control, congestion control | Connection setup overhead (3-way handshake), head-of-line blocking, higher latency |
| UDP | No handshake, no head-of-line blocking, lower latency, multicast support | No delivery guarantee, no ordering, no congestion control, packet loss is your problem |

**Recommendation:**
Use TCP unless you have a specific reason not to. The "specific reasons" for UDP are: (1) real-time data where stale packets are worthless — live video, gaming, VoIP; (2) simple request-response where you can retry at the application level — DNS lookups; (3) broadcast/multicast scenarios — service discovery; (4) when you need to implement your own reliability layer with less overhead than TCP's. If you are building an HTTP server, a database driver, a file transfer tool, or a chat system, TCP is the answer.

---

## Decision 2: `maxConnections` on `net.Server`

**Context:**
`net.Server` has a `maxConnections` property that, when set, causes the server to reject new connections once the limit is reached. Without it, the server accepts connections until the OS runs out of file descriptors (typically 1024 by default on Linux, 256 on macOS).

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| No limit (default) | Maximum throughput under normal load | One slow client can hold a connection; a connection flood exhausts fd limit and crashes the process |
| `maxConnections` set | Prevents fd exhaustion; server stays alive under attack | Legitimate clients get rejected once the limit is hit; must tune carefully |
| `maxConnections` + connection queue | Graceful degradation; excess connections wait | More complex; must implement the queue yourself with `server.getConnections()` |

**Recommendation:**
Always set `maxConnections` in production. Calculate it based on your available file descriptors (`ulimit -n`) minus a safety margin for internal fds (open files, pipes, timers). A conservative formula: `maxConnections = ulimit - 100`. Monitor `server.getConnections()` and alert at 80% capacity. For HTTP servers behind a reverse proxy, the limit can be lower (hundreds) because the proxy handles thousands of client connections. For direct-to-client TCP servers, plan for thousands and raise the OS fd limit accordingly.

---

## Decision 3: Nagle's Algorithm (`setNoDelay`)

**Context:**
Nagle's algorithm batches small TCP writes into larger segments to reduce the number of packets on the network. It is enabled by default. For bulk data transfer, this is efficient. For interactive or latency-sensitive protocols, it introduces up to 200ms of delay while waiting for enough data to fill a segment.

**Trade-offs:**

| Setting | Pros | Cons |
|---------|------|------|
| Nagle ON (default) | Fewer packets, less network overhead, efficient for bulk transfer | Adds latency to small writes; creates "stuck" feeling in interactive protocols |
| Nagle OFF (`socket.setNoDelay(true)`) | Every `write()` sends immediately; minimal latency | More packets on the wire; higher overhead for chatty protocols |

**Recommendation:**
Disable Nagle (`socket.setNoDelay(true)`) for: HTTP servers (you want responses sent immediately), interactive protocols (chat, telnet), and any application where latency matters more than bandwidth efficiency. Keep Nagle enabled for: bulk file transfers, database replication streams, and any scenario where you are writing large chunks and throughput matters more than latency. When in doubt, disable it — the bandwidth overhead of extra packet headers is negligible on modern networks, but 200ms of latency is noticeable to humans.

---

## Decision 4: Keepalive Configuration

**Context:**
TCP keepalive sends probe packets on idle connections to detect dead peers. Without it, a connection to a crashed client stays open indefinitely, consuming a file descriptor and memory. Node.js exposes `socket.setKeepAlive(enable, initialDelay)` to configure this. The OS-level defaults are often too conservative — Linux defaults to probing after 2 hours of inactivity.

**Trade-offs:**

| Setting | Pros | Cons |
|---------|------|------|
| Keepalive OFF (default) | No extra traffic on idle connections | Dead connections are never cleaned up; fd leak over days/weeks |
| Keepalive ON, long interval (2h) | Detects dead peers eventually | 2 hours is too long for most server use cases; resources held unnecessarily |
| Keepalive ON, short interval (30-60s) | Detects dead peers quickly; frees resources | Extra packets on every idle connection; may trigger firewall idle-timeout resets |
| Application-level heartbeat | Full control; works across NAT/firewalls that strip TCP keepalive | Must implement in your protocol; both sides must cooperate |

**Recommendation:**
Enable TCP keepalive with a 60-second initial delay for all long-lived connections (WebSocket-like, chat, persistent API connections). For HTTP servers with short-lived connections, rely on the `timeout` event instead. Combine TCP keepalive with an application-level heartbeat if your connections traverse NAT gateways or cloud load balancers — these often have their own idle timeouts (AWS ALB: 60s, GCP: 10m) that will silently drop connections regardless of TCP keepalive. Always log when keepalive probes detect a dead peer so you have visibility into connection health.

---

## Decision 5: IPv4 vs IPv6 Dual-Stack

**Context:**
Node.js servers can listen on IPv4 (`0.0.0.0`), IPv6 (`::`) , or both. On most operating systems, listening on `::` with dual-stack enabled (the default) accepts both IPv4 and IPv6 connections. But this behavior varies by platform: some Linux configurations disable dual-stack, and Windows handles it differently.

**Trade-offs:**

| Approach | Pros | Cons |
|----------|------|------|
| Listen on `0.0.0.0` (IPv4 only) | Simple, predictable, works everywhere | No IPv6 support; increasingly a problem as IPv4 exhaustion continues |
| Listen on `::` (dual-stack) | Accepts both IPv4 and IPv6 on a single socket | Platform-dependent behavior; may not work on some Linux configs (`net.ipv6.bindv6only=1`) |
| Listen on both separately | Explicit, no platform surprises | Two sockets to manage; must handle both in your connection tracking |
| Listen on `::` with `ipv6Only: true` + separate IPv4 | Maximum control | Most complex; two server instances sharing a port |

**Recommendation:**
Listen on `::` (dual-stack) as the default. This works on macOS and most Linux distributions out of the box. Test your deployment environment — if `net.ipv6.bindv6only=1` is set on your Linux servers, dual-stack will not work and you need to listen on both addresses explicitly. For containerized deployments (Docker, Kubernetes), listening on `0.0.0.0` is often simpler because container networking handles the IPv4/IPv6 translation. Always log the actual bound address on startup so operators know what the server is listening on.

---

## Decision 6: Socket Timeout Strategies

**Context:**
Without timeouts, a slow or malicious client can hold a TCP connection open indefinitely, consuming server resources. Node.js provides `socket.setTimeout(ms)` which emits a `'timeout'` event but does not close the socket — you must close it yourself. Choosing the right timeout value depends on your protocol and traffic patterns.

**Trade-offs:**

| Strategy | Pros | Cons |
|----------|------|------|
| No timeout | Maximum tolerance for slow clients | Resource exhaustion under slowloris attacks or flaky networks |
| Short timeout (5-10s) | Fast cleanup of dead connections; protects against slowloris | May disconnect legitimate slow clients (large uploads, high-latency networks) |
| Long timeout (120-300s) | Tolerant of slow operations | Resources held for minutes; slow to recover from connection storms |
| Adaptive timeout (short idle, long active) | Best of both — generous for active transfers, aggressive for idle connections | More complex; must track connection state manually |

**Recommendation:**
Implement a two-tier timeout strategy. Set a short idle timeout (30-60 seconds) for connections that have completed their current request and are waiting for the next one. Set a longer active timeout (120-300 seconds) for connections actively transferring data. On the `'timeout'` event, always destroy the socket — do not just log it. For HTTP servers, align your timeout with your reverse proxy's timeout (slightly shorter, so the server closes the connection before the proxy does). Monitor timeout rates: a sudden spike in timeouts usually indicates a network issue or an attack, not a timeout misconfiguration.
