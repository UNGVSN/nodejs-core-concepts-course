# E05: TCP File Transfer

## Objective

Build a TCP file transfer system with a custom binary framing protocol. The sender transmits files over a TCP connection using a length-prefixed frame format that includes a filename header and file data, and the receiver reconstructs the files and verifies integrity using SHA-256 checksums. This exercise ties together streams, buffers, TCP networking, and crypto into a cohesive protocol implementation — the closest thing to building a real network protocol from scratch.

## Prerequisites

- Module 06 / Lesson 03 — TCP Protocol Deep Dive
- Module 06 / Lesson 06 — The `net` Module
- Module 06 / Lesson 07 — TCP Servers and Clients
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 03 / Lesson 04 — Buffer Operations
- Module 10 / Lesson 01 — Crypto Fundamentals (for SHA-256)

## Instructions

1. **Define the wire protocol.** Each file transfer consists of a header frame followed by a data frame:

```
HEADER FRAME:
+--------------------+-------------------------+------------------+-----------------+
| Magic (2 bytes)    | Filename Len (2 bytes)  | Filename (N)     | File Size (8 B) |
| 0xFE 0xED          | uint16 BE               | UTF-8 string     | uint64 BE       |
+--------------------+-------------------------+------------------+-----------------+

DATA FRAME:
+--------------------+--------------------+-------------------+
| Chunk Len (4 B)    | Chunk Data (N)     | ... repeat ...    |
| uint32 BE          | raw bytes          |                   |
+--------------------+--------------------+-------------------+

EOF + CHECKSUM:
+--------------------+--------------------+
| 0x00000000 (4 B)   | SHA-256 (32 bytes) |
| signals end        | hash of file data  |
+--------------------+--------------------+
```

2. **Create `file-sender.js`.** Accept one or more file paths as CLI arguments. Connect to the receiver's TCP server and send each file using the protocol above.

```js
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const HOST = process.argv[2] || '127.0.0.1';
const PORT = parseInt(process.argv[3] || '6000', 10);
const files = process.argv.slice(4);

if (files.length === 0) {
  console.error('Usage: node file-sender.js <host> <port> <file1> [file2] ...');
  process.exit(1);
}
```

3. **Send the header frame.** For each file, stat it to get the size, then write the magic bytes, filename length, filename (basename only, not full path), and file size as a single buffer.

4. **Stream file data in chunks.** Read the file using `fs.createReadStream()` with a `highWaterMark` of 64 KB. For each chunk, write a 4-byte length prefix followed by the chunk data. Compute a running SHA-256 hash as you read.

5. **Send the EOF marker and checksum.** After the entire file is streamed, write a 4-byte zero (end-of-file signal) followed by the 32-byte SHA-256 digest.

6. **Create `file-receiver.js`.** A TCP server that accepts connections, parses the incoming byte stream according to the protocol, reconstructs files, and verifies checksums.

```js
'use strict';

const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PORT = parseInt(process.argv[2] || '6000', 10);
const OUTPUT_DIR = process.argv[3] || path.join(__dirname, 'received');

// Ensure output directory exists
fs.mkdirSync(OUTPUT_DIR, { recursive: true });
```

7. **Parse the byte stream.** TCP delivers a raw byte stream — frames will be split across `'data'` events. Implement a state machine with these states:

| State | Action |
|-------|--------|
| `HEADER_MAGIC` | Read 2 bytes, verify `0xFEED` |
| `HEADER_FILENAME_LEN` | Read 2 bytes, get filename length |
| `HEADER_FILENAME` | Read N bytes, decode as UTF-8 |
| `HEADER_FILESIZE` | Read 8 bytes, get file size |
| `DATA_CHUNK_LEN` | Read 4 bytes. If 0, move to `CHECKSUM` |
| `DATA_CHUNK` | Read N bytes, write to file, update hash |
| `CHECKSUM` | Read 32 bytes, compare with computed hash |

Maintain an internal buffer and only advance the state machine when enough bytes are available.

8. **Verify integrity.** After receiving the complete file, compare the received SHA-256 checksum with the locally computed checksum. If they match, print success. If they differ, delete the corrupted file and report the mismatch.

9. **Handle multiple files.** After verifying one file's checksum, the state machine resets to `HEADER_MAGIC` and waits for the next file. The sender transmits files sequentially over the same connection.

10. **Print transfer statistics.** Both sender and receiver should log: filename, file size, transfer duration, throughput (MB/s), and checksum result.

## Break-Then-Harden Challenge

1. **Set `highWaterMark` to 7 on the receiver's socket.** Every protocol field will be split across multiple `'data'` events. If your state machine does not properly accumulate partial data, parsing will fail. This is the definitive test of your framing implementation.

2. **Corrupt one byte mid-transfer.** In the sender, after hashing, flip one bit in a random chunk before writing to the socket. The receiver's checksum will not match. Verify that the receiver detects the corruption, reports the mismatch, and deletes the corrupted file.

3. **Send a file with the same name twice.** The receiver should handle name collisions — either overwrite, rename (append a number), or reject. Implement the rename strategy: `photo.jpg`, `photo-1.jpg`, `photo-2.jpg`.

## Expected Output

```
=== Receiver ===
File receiver listening on port 6000
Waiting for connections...

[connection] 127.0.0.1:55123
  Receiving: report.pdf (2,458,624 bytes)
    Progress: 100% (2,458,624 / 2,458,624)
    SHA-256: a3f2b8c1...94e7 — MATCH
    Saved: received/report.pdf
    Duration: 0.24s | Throughput: 9.77 MB/s

  Receiving: data.csv (15,728,640 bytes)
    Progress: 100% (15,728,640 / 15,728,640)
    SHA-256: 7d2f91e4...b3a1 — MATCH
    Saved: received/data.csv
    Duration: 1.12s | Throughput: 13.39 MB/s

Transfer complete: 2 files, 18,187,264 bytes total

=== Sender ===
Connecting to 127.0.0.1:6000...
Connected.

Sending: report.pdf (2,458,624 bytes)
  [============================] 100% | 9.77 MB/s
  SHA-256: a3f2b8c1...94e7

Sending: data.csv (15,728,640 bytes)
  [============================] 100% | 13.39 MB/s
  SHA-256: 7d2f91e4...b3a1

All files sent. Closing connection.
```

## Bonus

1. **Compression.** Add an optional flag `--compress` that compresses each chunk with `require('node:zlib').gzipSync()` before sending. Add a single byte to the header indicating whether compression is enabled. The receiver decompresses before writing. Compare transfer time with and without compression for text vs binary files.

2. **Resume interrupted transfers.** If the connection drops mid-transfer, the receiver records how many bytes were received. When the sender reconnects, it checks with the receiver and resumes from the last confirmed byte offset. This requires a two-way handshake at the start of each file.

## Hints

1. TCP guarantees ordered delivery but not message boundaries. A single `socket.write()` call on the sender may arrive as multiple `'data'` events on the receiver, or multiple `write()` calls may arrive as a single `'data'` event. Your parser must handle both cases.

2. For 8-byte file sizes, use `Buffer.writeBigUInt64BE()` and `Buffer.readBigUInt64BE()`. This supports files up to 2^64 bytes (18.4 exabytes).

3. The magic bytes (`0xFEED`) serve as a frame synchronization marker. If the receiver ever reads bytes that do not start with the magic value when expected, the stream is desynchronized — abort and report the error.

4. `crypto.createHash('sha256').update(chunk).digest()` computes a one-shot hash. For streaming, call `.update(chunk)` for each chunk, then `.digest('hex')` once at the end. You can only call `.digest()` once per hash instance.

5. The state machine pattern (current state + internal buffer + advance when ready) is the same pattern used by HTTP parsers, WebSocket frames, and every binary protocol. Master it here and it applies everywhere.
