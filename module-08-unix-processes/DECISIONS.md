# Module 08 — Unix, Processes & IPC: Production Decisions

> Getting processes right means the difference between a server that recovers from failures and one that silently corrupts data on its way down. These decisions affect reliability, scalability, and operational sanity.

---

## Decision 01: `fork` vs `spawn` vs `exec`

**Context:** Node.js provides three main ways to create child processes: `exec` (shell, buffered), `spawn` (no shell, streaming), and `fork` (Node.js-specific, IPC channel). Each has fundamentally different characteristics.

**Trade-offs:**

| Factor | `exec` / `execFile` | `spawn` | `fork` |
|--------|---------------------|---------|--------|
| Shell involved | `exec`: yes; `execFile`: no | No | No |
| Output handling | Buffered (maxBuffer limit) | Streaming via stdout/stderr pipes | Streaming + IPC channel |
| Memory | Entire output in memory | Constant memory (streaming) | Separate V8 heap per child |
| IPC built-in | No | No (unless `stdio: 'ipc'`) | Yes — `child.send()` / `process.send()` |
| Startup cost | High (shell + process) | Medium (process only) | High (new V8 instance) |
| Use case | Quick shell commands, small output | Long-running processes, large output | Node.js worker tasks needing IPC |
| Security | Shell injection risk with `exec` | No shell — safer | No shell — safer |

**Recommendation:** Use `execFile` for quick, bounded commands where you need the full output (e.g., `git rev-parse HEAD`). Use `spawn` for long-running processes or commands with large output (e.g., log tailing, video encoding). Use `fork` when you need a Node.js child that communicates structured data back to the parent via IPC. Never use `exec` with user-provided input — shell injection is trivially exploitable.

---

## Decision 02: `cluster` Module vs Reverse Proxy (nginx)

**Context:** To utilize multiple CPU cores, you can either use Node.js's built-in `cluster` module (one primary, N workers sharing a port) or run N independent Node.js processes behind an nginx reverse proxy.

**Trade-offs:**

| Factor | `cluster` module | nginx reverse proxy |
|--------|-----------------|-------------------|
| Setup complexity | One file, no external dependency | Separate process, config file, deployment |
| Load balancing | Round-robin (Linux) or OS-dependent | Configurable (round-robin, least-conn, ip-hash) |
| Port sharing | Workers share a single port | Each worker on different port |
| Static files | Handled by Node.js (slower) | nginx serves static files much faster |
| SSL termination | Node.js handles TLS (CPU cost) | nginx handles TLS efficiently (OpenSSL) |
| Health checks | Manual implementation required | Built-in with `proxy_pass` and `upstream` |
| Zero-downtime deploy | Requires manual rolling restart logic | Built-in with `reload` signal |
| Observability | Single process tree, easy to monitor | Separate processes, separate logs |

**Recommendation:** Use `cluster` for development and simple deployments where you want zero external dependencies. Use nginx (or HAProxy) in production — it handles SSL termination, static file serving, connection buffering, and load balancing far more efficiently than Node.js can. Many production setups use both: nginx in front for SSL and static assets, then `cluster` behind it for multi-core Node.js request handling.

---

## Decision 03: Graceful Shutdown Patterns

**Context:** When a process receives `SIGTERM` (from a process manager, Kubernetes, or manual kill), it must drain in-flight requests, close database connections, and flush logs before exiting. Getting this wrong causes dropped requests and data corruption.

**Trade-offs:**

| Strategy | Immediate exit | Graceful with timeout | Graceful with drain |
|----------|---------------|----------------------|-------------------|
| Dropped requests | All in-flight requests lost | Requests within timeout complete | All accepted requests complete |
| Shutdown speed | Instant | Bounded (e.g., 30s) | Unbounded (dangerous) |
| Complexity | None | Moderate | High |
| Data integrity | Risk of corruption | Good with timeout | Best, but may hang |
| K8s compatibility | Poor — fails readiness probes | Good — within `terminationGracePeriodSeconds` | Risk exceeding K8s kill timeout |

**Recommendation:** Implement graceful shutdown with a hard timeout. On `SIGTERM`: (1) stop accepting new connections via `server.close()`, (2) set a 30-second hard deadline with `setTimeout(() => process.exit(1), 30000).unref()`, (3) wait for in-flight requests to complete, (4) close database connections and flush logs, (5) call `process.exit(0)`. The `.unref()` on the timeout timer prevents it from keeping the event loop alive if everything drains cleanly before the deadline.

---

## Decision 04: IPC Serialization Overhead

**Context:** When you use `child.send(message)` or `process.send(message)`, Node.js serializes the message using the structured clone algorithm (similar to `JSON.stringify` but supports more types). For high-throughput worker pools, this serialization cost matters.

**Trade-offs:**

| Factor | JSON (structured clone) | SharedArrayBuffer | Unix domain sockets |
|--------|------------------------|-------------------|-------------------|
| Speed | ~50-100 microseconds per message | Near-zero (shared memory) | ~20-50 microseconds |
| Data types | Objects, arrays, Buffers, Maps | Only numeric/binary data | Arbitrary bytes |
| Complexity | Simple — `send()` and `on('message')` | Complex — manual Atomics coordination | Complex — custom protocol |
| Memory | Copied per message | Shared — no copy | Copied per message |
| Safety | Isolated — no data races | Race conditions possible | Isolated — no data races |
| Process boundary | Works across fork | Only `worker_threads` (not child_process) | Works across any process |

**Recommendation:** Use the built-in IPC channel (`child.send`) for most communication — it is simple and safe. If profiling reveals serialization as a bottleneck (rare below 10,000 messages/second), switch to a Unix domain socket with a length-prefixed binary protocol. Reserve `SharedArrayBuffer` for `worker_threads` where you genuinely need zero-copy shared state — it is not available across `child_process` boundaries.

---

## Decision 05: Detached vs Attached Child Processes

**Context:** By default, child processes are attached to the parent — they share stdio and die when the parent exits. Setting `detached: true` in `spawn` options creates a process that can outlive its parent, which is useful for daemon-style workers but dangerous if left unmanaged.

**Trade-offs:**

| Factor | Attached (default) | Detached |
|--------|-------------------|----------|
| Lifecycle | Dies when parent dies | Survives parent exit |
| stdio | Inherits or pipes to parent | Must redirect to file or `'ignore'` |
| Cleanup | Automatic on parent exit | Must track and kill manually |
| Use case | Worker pools, task execution | Daemons, background jobs, log rotation |
| Orphan risk | None | Process can become orphaned if parent crashes |
| Monitoring | Easy — parent tracks all children | Requires PID file or process manager |

**Recommendation:** Keep child processes attached for worker pools and request processing — you want them to die with the parent. Use detached processes only for true daemon scenarios (log rotation, scheduled maintenance tasks) where the child must outlive the parent. Always call `child.unref()` after detaching so the parent can exit cleanly. Write the detached child's PID to a file so you can find and kill it later.

---

## Decision 06: Signal Handling Strategies

**Context:** Node.js can listen for Unix signals via `process.on('SIGINT', handler)`, but not all signals behave the same way. `SIGKILL` and `SIGSTOP` cannot be caught. Overriding `SIGINT` changes Ctrl+C behavior. Some signals have default behaviors that your handlers replace.

**Trade-offs:**

| Signal | Default behavior | Should you override? | Risk |
|--------|-----------------|---------------------|------|
| `SIGINT` (Ctrl+C) | Exit immediately | Yes — for graceful shutdown | Infinite loop if handler never calls `process.exit()` |
| `SIGTERM` | Exit immediately | Yes — standard graceful shutdown signal | Same risk as SIGINT |
| `SIGHUP` | Exit (terminal hangup) | Maybe — for config reload | Process stays alive after terminal closes |
| `SIGUSR1` | Start debugger (Node.js default) | Rarely — breaks `--inspect` | Loses debugging capability |
| `SIGUSR2` | Exit | Yes — safe for custom signals | No default behavior lost |
| `SIGKILL` | Exit immediately | Cannot be caught | N/A |

**Recommendation:** Override `SIGTERM` and `SIGINT` for graceful shutdown — they are the standard signals sent by process managers and Kubernetes. Use `SIGUSR2` for custom purposes (heap dumps, config reload) since it has no default Node.js behavior to lose. Never override `SIGUSR1` unless you are certain you will never need the Node.js debugger. Always ensure your signal handlers eventually call `process.exit()` — a handler that never exits creates an unkillable process (until `SIGKILL`).
