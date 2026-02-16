# Module 03 — Buffer Decisions

> Production trade-offs for working with binary data in Node.js. Buffers sit at the boundary between JavaScript's string-centric world and the byte-centric world of operating systems and network protocols. Getting these decisions right affects security, performance, and correctness.

---

## Decision 1: Buffer.alloc vs Buffer.allocUnsafe

**Decision:** Whether to use `Buffer.alloc(size)` (zero-filled) or `Buffer.allocUnsafe(size)` (uninitialized) when creating new Buffers.

**Context:** `Buffer.alloc(size)` fills the allocated memory with zeros before returning it. `Buffer.allocUnsafe(size)` returns memory from the internal pool without zeroing it — the Buffer may contain data from previous allocations, including sensitive information like passwords, encryption keys, or other users' data.

**Trade-offs:**
- `Buffer.alloc`: safe by default; small performance cost for zeroing (~2-5% slower for large allocations); no risk of data leakage
- `Buffer.allocUnsafe`: faster for large allocations where you will immediately overwrite every byte; dangerous if any byte position is read before being written; the "unsafe" name is a clear warning
- `Buffer.allocUnsafeSlow`: bypasses the internal pool entirely; useful for long-lived Buffers that should not prevent pool memory from being reclaimed; same data-leakage risk as `allocUnsafe`
- The deprecated `new Buffer(size)` is equivalent to `allocUnsafe` — never use it

**Recommendation:** Default to `Buffer.alloc` everywhere. Use `Buffer.allocUnsafe` only in hot paths where you can prove that every byte will be written before any byte is read — and document that proof with a comment. In code review, treat every `allocUnsafe` call as a security-sensitive line that requires justification.

---

## Decision 2: Buffer Pooling Strategy

**Decision:** Whether to rely on Node.js's internal Buffer pool or implement your own pooling for high-throughput scenarios.

**Context:** Node.js maintains an internal 8KB pool for small Buffer allocations (< 4KB by default). When you call `Buffer.allocUnsafe(size)` for a small size, it slices from this pool rather than making a separate memory allocation. This is fast but means small Buffers share an underlying `ArrayBuffer`.

**Trade-offs:**
- Internal pool (default): fast allocation for small Buffers; no additional code; shared `ArrayBuffer` means slices keep the entire 8KB pool page alive if any slice is retained
- Custom pool: full control over allocation size, lifetime, and reuse patterns; eliminates GC pressure for known workloads (e.g., fixed-size protocol frames); significant implementation complexity
- Pre-allocated ring buffer: ideal for fixed-size messages in network servers; zero allocation after startup; fixed memory footprint; requires careful index management
- No pooling (`Buffer.allocUnsafeSlow` or `Buffer.alloc`): each Buffer gets its own `ArrayBuffer`; GC can reclaim each independently; slower allocation

**Recommendation:** Rely on the internal pool for most applications. Implement a custom pre-allocated pool only when profiling shows Buffer allocation as a bottleneck — typically in protocol parsers handling 100K+ messages/second. When building a custom pool, use a ring buffer with fixed-size slots and track allocation/deallocation explicitly.

---

## Decision 3: String Encoding Defaults

**Decision:** Which encoding to use as the default when converting between Buffers and strings.

**Context:** `buffer.toString()` defaults to `'utf8'`. Node.js supports `utf8`, `utf16le`, `latin1`, `base64`, `base64url`, `hex`, and `ascii`. Choosing the wrong encoding produces garbled data silently — there is no error thrown for an encoding mismatch.

**Trade-offs:**
- UTF-8: universal default; handles all Unicode; variable-width (1-4 bytes per character); safe for JSON, HTML, most text
- Latin-1 (ISO-8859-1): single-byte; lossless round-trip for arbitrary binary data stored as strings; cannot represent characters beyond U+00FF
- ASCII: 7-bit; bytes above 127 are mangled; only appropriate for strict ASCII protocols
- Base64: safe for embedding binary in text (JSON, URLs, data URIs); ~33% size overhead; no encoding ambiguity
- Hex: 2 characters per byte; useful for debugging and checksums; 100% size overhead

**Recommendation:** Use `'utf8'` for all text content. Use `'base64'` or `'base64url'` for embedding binary data in JSON or URLs. Use `'hex'` for checksums, hashes, and debugging. Never use `'ascii'` unless the protocol specification explicitly requires 7-bit ASCII. When in doubt, always pass the encoding explicitly rather than relying on the default — future readers of your code should not have to guess.

---

## Decision 4: Buffer.from(string) vs Buffer.from(array)

**Decision:** Understanding when `Buffer.from` creates a copy vs when it shares memory.

**Context:** `Buffer.from` is overloaded. `Buffer.from(string, encoding)` always creates a new allocation. `Buffer.from(arrayBuffer, offset, length)` creates a **view** over the same memory — mutations to the Buffer mutate the original `ArrayBuffer` and vice versa. `Buffer.from(array)` copies the values into a new allocation.

**Trade-offs:**
- `Buffer.from(string)`: always copies; safe; encoding conversion happens here; no shared-memory surprises
- `Buffer.from(buffer)`: copies the data; safe; the two Buffers are independent after creation
- `Buffer.from(arrayBuffer)`: **shares memory**; zero-copy; mutations propagate both ways; can cause hard-to-trace bugs if the original ArrayBuffer is modified elsewhere
- `Buffer.from(array)`: copies values; each element is coerced to a byte (0-255); values outside this range are truncated silently

**Recommendation:** Be explicit about whether you want a copy or a view. When receiving an `ArrayBuffer` from a WebSocket, `crypto` operation, or `Worker` message, use `Buffer.from(arrayBuffer)` for zero-copy performance — but document the shared-memory relationship. When you need an independent copy, use `Buffer.from(Buffer.from(arrayBuffer))` or call `buffer.slice()` followed by copying. Add comments at every `Buffer.from(arrayBuffer)` call site explaining the ownership model.

---

## Decision 5: When to Use TypedArrays vs Buffers

**Decision:** Whether to use Node.js `Buffer` or Web-standard `TypedArray` (e.g., `Uint8Array`) for binary data manipulation.

**Context:** `Buffer` is a subclass of `Uint8Array` — every Buffer is a `Uint8Array`, but not every `Uint8Array` is a Buffer. Node.js APIs accept both. TypedArrays are part of the JavaScript standard and work in browsers. Buffer adds convenience methods (`toString` with encodings, `readInt32BE`, `writeFloatLE`, `compare`, `concat`).

**Trade-offs:**
- Buffer: richer API for network/file I/O; `toString(encoding)` is essential for protocol work; Node.js-only; carries the legacy of the deprecated `new Buffer()` API
- TypedArray (`Uint8Array`, `Int32Array`, `Float64Array`): Web standard; portable between Node.js and browser; no encoding-aware `toString`; works with `DataView` for mixed-type binary parsing
- `DataView`: reads/writes any type at any offset with explicit endianness; slower than typed array access; perfect for parsing heterogeneous binary protocols
- Using TypedArrays in Node.js code that will never run in a browser adds no benefit and loses Buffer convenience

**Recommendation:** Use `Buffer` for Node.js server-side code — it is a `Uint8Array` with better ergonomics for I/O. Use `Uint8Array` and `DataView` when writing isomorphic libraries that must work in browsers. When parsing complex binary protocols with mixed types (uint16 headers, float64 payloads, variable-length strings), prefer `DataView` for clarity — the explicit endianness parameter prevents byte-order bugs.
