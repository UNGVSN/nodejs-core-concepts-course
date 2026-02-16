# E05: Stream Multiplexer

## Objective

Build a stream multiplexer that combines data from multiple source streams into a single output stream, and a demultiplexer that splits the combined stream back into the original individual streams. Each chunk in the multiplexed stream is prefixed with a header containing the source ID and payload length. This pattern is foundational for protocols that send multiple logical channels over a single transport (HTTP/2, SSH, WebSocket subprotocols).

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 02 — Readable Streams
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 05 / Lesson 07 — Custom Streams
- Module 03 / Lesson 04 — Buffer Operations (for binary framing)

## Instructions

1. **Define the frame format.** Each multiplexed frame consists of a header followed by a payload:

```
+-------------------+-------------------+------------------+
| Source ID (1 byte) | Payload Length (4 bytes, BE) | Payload (N bytes) |
+-------------------+-------------------+------------------+
```

- Source ID: `0x00` to `0xFF` (supports up to 256 channels)
- Payload Length: unsigned 32-bit big-endian integer
- Payload: raw bytes from the source stream

2. **Create `Multiplexer` class.** This is a Writable stream factory — not a stream itself. It exposes a method `addSource(id, readableStream)` that attaches a readable stream with a given ID. Whenever a source emits data, the multiplexer writes a framed chunk (header + payload) to a single shared output Writable stream.

```js
'use strict';

const { Writable } = require('node:stream');

class Multiplexer {
  constructor(outputStream) {
    this.output = outputStream;
    this.sources = new Map();
  }

  addSource(id, readable) {
    this.sources.set(id, readable);
    readable.on('data', (chunk) => {
      const header = Buffer.alloc(5);
      header.writeUInt8(id, 0);
      header.writeUInt32BE(chunk.length, 1);
      this.output.write(Buffer.concat([header, chunk]));
    });
    readable.on('end', () => {
      // Send a zero-length frame to signal EOF for this channel
      const header = Buffer.alloc(5);
      header.writeUInt8(id, 0);
      header.writeUInt32BE(0, 1);
      this.output.write(header);
    });
  }
}
```

3. **Create `Demultiplexer` class.** This is a Writable stream that accepts the multiplexed byte stream, parses frames using the header format, and routes each payload to the appropriate output stream by source ID. It must handle frames split across chunk boundaries.

4. **Handle partial frames.** The demultiplexer receives arbitrary-sized chunks from the transport. A single chunk may contain zero, one, or multiple complete frames, and a frame may be split across two chunks. Maintain an internal `Buffer` that accumulates incoming data. Parse frames only when enough bytes are available.

```js
class Demultiplexer extends Writable {
  constructor() {
    super();
    this.buffer = Buffer.alloc(0);
    this.outputs = new Map();
  }

  addOutput(id, writableStream) {
    this.outputs.set(id, writableStream);
  }

  _write(chunk, encoding, callback) {
    this.buffer = Buffer.concat([this.buffer, chunk]);

    while (this.buffer.length >= 5) {
      const payloadLength = this.buffer.readUInt32BE(1);
      const frameSize = 5 + payloadLength;
      if (this.buffer.length < frameSize) break;  // wait for more data

      const id = this.buffer.readUInt8(0);
      const payload = this.buffer.subarray(5, frameSize);
      this.buffer = this.buffer.subarray(frameSize);

      // Route to appropriate output
      const out = this.outputs.get(id);
      if (out && payloadLength > 0) out.write(payload);
      if (out && payloadLength === 0) out.end();  // EOF signal
    }
    callback();
  }
}
```

5. **Test with file streams.** Create three small text files (`source-a.txt`, `source-b.txt`, `source-c.txt`). Multiplex them into a single `multiplexed.bin` file. Then demultiplex `multiplexed.bin` back into three separate output files. Verify the outputs match the originals using a byte-by-byte comparison.

6. **Test with generated data.** Create three Readable streams that push random data at different rates (one fast, one medium, one slow using `setTimeout` in `_read`). Multiplex, then demultiplex, and verify integrity using SHA-256 checksums.

7. **Print a channel activity log.** As the demultiplexer processes frames, log each frame: `[CH 0x01] 4096 bytes | [CH 0x02] 2048 bytes | ...`. After completion, print total bytes and frame count per channel.

8. **Add backpressure to the multiplexer.** Check the return value of `this.output.write()`. If it returns `false`, pause all source streams and resume them on `'drain'`.

## Break-Then-Harden Challenge

1. **Corrupt a frame header.** Manually edit `multiplexed.bin` with a Buffer script to change one payload-length field to an incorrect value. The demultiplexer will either read too many or too few bytes, desynchronizing all subsequent frames. Add a checksum to each frame header (CRC-8 of source ID + length) and validate it in the demultiplexer.

2. **Set the transport `highWaterMark` to 3.** This guarantees every frame header is split across chunks (the header is 5 bytes). Verify the demultiplexer still correctly reconstructs all frames. If it fails, your partial-frame buffer logic has a bug.

3. **Send data from 256 channels simultaneously.** Create 256 tiny Readable streams and multiplex them. This stress-tests the ID space and the demultiplexer's routing map. Verify all 256 outputs are correct.

## Expected Output

```
=== Multiplexing 3 sources ===
  Source 0x00: source-a.txt (1,247 bytes)
  Source 0x01: source-b.txt (3,891 bytes)
  Source 0x02: source-c.txt (892 bytes)
  Written: multiplexed.bin (6,075 bytes with framing overhead)

=== Demultiplexing ===
  [CH 0x00] frame 1: 1,024 bytes
  [CH 0x01] frame 1: 1,024 bytes
  [CH 0x02] frame 1: 892 bytes
  [CH 0x00] frame 2: 223 bytes
  [CH 0x01] frame 2: 1,024 bytes
  [CH 0x01] frame 3: 1,024 bytes
  [CH 0x01] frame 4: 819 bytes

  Channel summary:
    0x00: 2 frames, 1,247 bytes — checksum OK ✓
    0x01: 4 frames, 3,891 bytes — checksum OK ✓
    0x02: 1 frame,  892 bytes   — checksum OK ✓

=== Verification ===
  output-a.txt matches source-a.txt ✓
  output-b.txt matches source-b.txt ✓
  output-c.txt matches source-c.txt ✓
```

## Bonus

1. **Add priority channels.** Modify the multiplexer to accept a priority level per source. Higher-priority sources get their frames written first when multiple sources have data ready. Implement a simple priority queue.

2. **Bidirectional multiplexing.** Use a Duplex stream as the transport. Both sides can multiplex and demultiplex simultaneously over the same stream — like a real protocol (SSH channels, HTTP/2 streams).

## Hints

1. `Buffer.concat([header, payload])` creates a new buffer containing both. This is fine for framing — the overhead is small compared to the payload.

2. `buffer.subarray(start, end)` returns a view without copying. Use it when slicing the internal accumulation buffer to avoid unnecessary allocations.

3. The zero-length frame is a simple EOF signaling mechanism. When the demultiplexer receives a frame with `payloadLength === 0`, it should call `.end()` on the corresponding output stream.

4. For checksum verification, use `require('node:crypto').createHash('sha256')`. Compute the hash of each original file and each demultiplexed output, then compare the hex digests.

5. The accumulation buffer pattern (`this.buffer = Buffer.concat([this.buffer, chunk])`) is simple but allocates on every write. For production code, consider a linked list of buffers or a ring buffer. For this exercise, the simple approach is fine.
