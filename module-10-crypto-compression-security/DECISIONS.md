# Module 10 — Cryptography, Compression & Security: Production Decisions

> Security decisions are irreversible in production. Choose the wrong algorithm and you are stuck supporting it until every stored hash is migrated. Choose the wrong compression and you pay bandwidth costs forever. Get these right the first time.

---

## Decision 01: AES-GCM vs AES-CBC

**Context:** AES-256 is the standard symmetric encryption algorithm, but the mode of operation matters enormously. GCM (Galois/Counter Mode) provides authenticated encryption — the ciphertext includes a tag that proves the data has not been tampered with. CBC (Cipher Block Chaining) provides confidentiality only — no integrity check is built in.

**Trade-offs:**

| Factor | AES-256-GCM | AES-256-CBC |
|--------|-------------|-------------|
| Authentication | Built-in — auth tag detects tampering | None — must add HMAC separately |
| Padding | No padding needed (stream cipher mode) | Requires PKCS7 padding — padding oracle attacks possible |
| Parallelism | Counter mode can be parallelized | CBC is sequential — each block depends on the previous |
| IV reuse | Catastrophic — completely breaks security | Bad but recoverable — reveals block patterns |
| Output size | Ciphertext + 16-byte auth tag | Ciphertext + up to 16 bytes padding |
| Performance | ~20% faster on modern CPUs with AES-NI | Slower due to sequential chaining |
| Ecosystem | Modern standard, used by TLS 1.3 | Legacy, used by TLS 1.2 and older systems |

**Recommendation:** Always use AES-256-GCM. It is faster, more secure, and simpler (no separate HMAC step). The only valid reason to use CBC is interoperability with legacy systems that do not support GCM. If you must use CBC, always pair it with HMAC-SHA-256 in an encrypt-then-MAC construction — never use CBC without integrity verification. Always generate a fresh random IV for every encryption operation with `crypto.randomBytes(12)` for GCM (96-bit IV) or `crypto.randomBytes(16)` for CBC.

---

## Decision 02: `scrypt` vs `pbkdf2`

**Context:** Password hashing requires a deliberately slow algorithm to make brute-force attacks expensive. Node.js provides both `crypto.scrypt` and `crypto.pbkdf2` as built-in key derivation functions suitable for password hashing. Neither is "wrong," but they have different resistance profiles against hardware attacks.

**Trade-offs:**

| Factor | `scrypt` | `pbkdf2` |
|--------|---------|----------|
| Memory hardness | Yes — requires configurable RAM (default ~16 MiB) | No — CPU-only, ASIC/GPU-friendly |
| GPU resistance | High — memory bandwidth limits parallelism | Low — trivially parallelized on GPUs |
| CPU cost | Configurable via `cost` parameter (N) | Configurable via `iterations` |
| Node.js API | `crypto.scrypt(password, salt, keyLen, options, cb)` | `crypto.pbkdf2(password, salt, iterations, keyLen, digest, cb)` |
| Async support | Yes — runs in libuv thread pool | Yes — runs in libuv thread pool |
| Standards | RFC 7914 | RFC 2898, NIST SP 800-132 |
| Industry adoption | Growing — recommended by OWASP | Widely deployed, FIPS-compliant |
| Tuning complexity | Three params (N, r, p) — easy to misconfigure | One param (iterations) — straightforward |

**Recommendation:** Use `scrypt` with `cost: 16384` (N=2^14), `blockSize: 8`, `parallelization: 1`, and a 32-byte output for new applications. Its memory hardness makes GPU-based cracking 100-1000x more expensive than the equivalent `pbkdf2` configuration. Use `pbkdf2` only if you need FIPS 140-2 compliance or interoperability with systems that do not support scrypt. For `pbkdf2`, use at least 600,000 iterations with SHA-256 (OWASP 2023 recommendation). Always generate a 16-byte random salt per password with `crypto.randomBytes(16)`.

---

## Decision 03: Brotli vs Gzip

**Context:** HTTP response compression reduces bandwidth and improves load times. Node.js supports three algorithms via `node:zlib`: deflate (raw), gzip (deflate + headers), and brotli (modern, better compression). Servers negotiate the algorithm via the `Accept-Encoding` / `Content-Encoding` headers.

**Trade-offs:**

| Factor | Gzip | Brotli |
|--------|------|--------|
| Compression ratio (text) | Good — ~70% reduction | Better — ~80% reduction (15-20% smaller than gzip) |
| Compression speed | Fast at level 6 (default) | Slow at high levels, fast at level 4 |
| Decompression speed | Fast | Fast — comparable to gzip |
| Browser support | Universal — every browser | Modern browsers (95%+ global support) |
| CPU cost (compress) | Moderate | High at default level, moderate at level 4 |
| Static asset pre-compression | Good choice | Best choice — compress once, serve many times |
| Dynamic content | Good — fast enough for real-time | Use level 4 — higher levels too slow for real-time |
| Binary data (images, video) | Minimal gain — already compressed | Minimal gain — same limitation |

**Recommendation:** Support both. Serve brotli (`br`) when the client supports it, fall back to gzip. For dynamic responses (API JSON), use brotli level 4 (`{ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 4 } }`) — it compresses better than gzip at comparable speed. For static assets, pre-compress at brotli level 11 at build time and serve the pre-compressed files. Do not compress images, video, or already-compressed formats — it wastes CPU for near-zero savings.

---

## Decision 04: TLS 1.2 vs TLS 1.3

**Context:** Node.js supports TLS 1.2 and TLS 1.3 via `node:tls` and `node:https`. TLS 1.3 is the current standard (RFC 8446), removing insecure cipher suites and reducing handshake round-trips. However, some older clients and corporate proxies only support TLS 1.2.

**Trade-offs:**

| Factor | TLS 1.2 | TLS 1.3 |
|--------|---------|---------|
| Handshake round-trips | 2 RTT (full), 1 RTT (session resumption) | 1 RTT (full), 0-RTT (early data) |
| Cipher suite control | Many suites, some insecure — must curate | Only 5 strong suites — no weak options |
| Forward secrecy | Optional (depends on cipher suite) | Mandatory — every connection uses ephemeral keys |
| 0-RTT early data | Not available | Available — but replay attack risk |
| Client compatibility | Universal — all clients | Most modern clients; some enterprise proxies fail |
| Performance | Slower handshake | Faster handshake, lower latency |
| Configuration complexity | Must disable weak ciphers manually | Secure by default — minimal configuration |

**Recommendation:** Set `minVersion: 'TLSv1.2'` and let Node.js negotiate TLS 1.3 when the client supports it. Do not disable TLS 1.2 entirely unless you are certain all clients support 1.3. For TLS 1.2, restrict cipher suites to those with ECDHE key exchange (forward secrecy) and AES-GCM (authenticated encryption). Do not enable 0-RTT early data in TLS 1.3 unless you understand the replay risk and your endpoints are idempotent.

---

## Decision 05: `randomBytes` vs `randomUUID`

**Context:** Node.js provides `crypto.randomBytes(n)` for generating cryptographically secure random buffers and `crypto.randomUUID()` for generating RFC 4122 v4 UUIDs. Both use the same underlying CSPRNG, but they serve different purposes.

**Trade-offs:**

| Factor | `randomBytes(n)` | `randomUUID()` |
|--------|------------------|----------------|
| Output format | Buffer (hex, base64, raw bytes) | String `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` |
| Entropy | Full — n * 8 bits | 122 bits (6 bits are fixed version/variant) |
| Use case | Tokens, keys, salts, IVs, nonces | Database IDs, correlation IDs, request IDs |
| Collision resistance | Configurable — use 32+ bytes for tokens | ~2^61 before 50% collision probability |
| Performance | Slightly slower (system call per invocation) | Faster (optimized in Node.js C++ layer) |
| Async version | `randomBytes` has async callback form | Sync only (but fast enough for hot paths) |
| URL-safe | Must encode (hex or base64url) | Contains hyphens — URL-safe but verbose |

**Recommendation:** Use `randomUUID()` for identifiers — request IDs, database primary keys, correlation IDs — where human readability and standard format matter. Use `randomBytes(32).toString('hex')` for security tokens (session IDs, CSRF tokens, API keys) where maximum entropy matters. Use `randomBytes(16)` for salts and `randomBytes(12)` for AES-GCM IVs. Never use `Math.random()` for anything security-sensitive — it is not cryptographically secure.

---

## Decision 06: Streaming vs Buffered Crypto

**Context:** Node.js crypto APIs offer both streaming (`createCipheriv` returns a `Transform` stream) and one-shot buffered operations (`cipher.update(data) + cipher.final()`). For large data — file encryption, log hashing — the choice affects memory usage and throughput.

**Trade-offs:**

| Factor | Streaming | Buffered |
|--------|-----------|---------|
| Memory | Constant — processes chunks | O(n) — entire input in memory |
| Latency | First output byte arrives early | Must wait for all input |
| Complexity | Pipeline setup, error handling | Simple — single function call |
| Backpressure | Handled by stream pipeline | Not applicable |
| Use case | File encryption, large payloads, piping | Small strings (passwords, tokens, short messages) |
| Error handling | Stream errors, premature close | Try/catch around sync call |
| Auth tag (GCM) | Available after `final()` event | Available after `cipher.final()` |

**Recommendation:** Use streaming for any data over 64 KiB — file encryption, response compression, log file hashing. Use `stream.pipeline(input, cipher, output, callback)` for proper error propagation and backpressure. Use buffered for small operations — hashing a password, encrypting a JWT payload, generating an HMAC for an API signature. For AES-GCM streaming, remember that the authentication tag is only available after calling `cipher.final()` — you must append it to the ciphertext stream or transmit it separately.
