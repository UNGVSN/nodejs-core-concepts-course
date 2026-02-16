# E01: Hex Dump Utility

> Build a command-line hex dump tool that displays file contents in offset + hex + ASCII format, just like the classic `xxd` utility. This exercise forces you to think about Buffers as raw byte sequences and practice reading fixed-size chunks.

## Objective

Build a `hexdump.js` CLI tool that reads any file and prints its contents in the classic hex dump format: an offset column, 16 hex bytes (grouped in pairs), and a printable ASCII column. This is the single most useful debugging tool for binary data, and building it yourself will cement your understanding of Buffer indexing, slicing, and character classification.

## Prerequisites

- Module 03, Lesson 01 (Binary Number Systems)
- Module 03, Lesson 02 (Hexadecimal and Octal)
- Module 03, Lesson 04 (Buffer Creation and Allocation)
- Module 03, Lesson 05 (Buffer Reading and Writing)

## Instructions

1. **Create `hexdump.js`** with `'use strict';` and require `node:fs` and `node:path`.

2. **Parse CLI arguments.** Accept a filename as `process.argv[2]`. If missing, print usage and exit with code 1.

3. **Open the file with `fs.openSync()`** to get a file descriptor. Allocate a 16-byte Buffer with `Buffer.alloc(16)` as your read buffer.

4. **Read in a loop.** Use `fs.readSync(fd, buf, 0, 16, offset)` to read 16 bytes at a time. The return value tells you how many bytes were actually read (may be less than 16 at end of file).

5. **Format the offset column.** Display the current byte offset as an 8-character zero-padded hex string (e.g., `00000000`, `00000010`, `00000020`).

6. **Format the hex column.** For each byte in the chunk, print its 2-digit hex value. Group bytes with a space between each. Insert an extra space after byte 8 to create the visual midpoint gap (matching `xxd` style).

7. **Format the ASCII column.** For each byte, print the character if it is printable ASCII (codes 0x20 through 0x7E). Print `.` for non-printable bytes.

8. **Handle the last line.** When the final chunk has fewer than 16 bytes, pad the hex column with spaces so the ASCII column aligns correctly.

9. **Close the file descriptor** with `fs.closeSync(fd)` when the loop ends.

10. **Test with multiple file types.** Run your tool against a plain text file, a PNG image, and your own `hexdump.js` source file. Verify the output matches `xxd` output for the same files.

```javascript
// Expected output format for each line:
// 00000000: 4865 6c6c 6f2c 2057 6f72 6c64 210a 0000  Hello, World!...
```

Here is a skeleton to get you started:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const filePath = process.argv[2];
if (!filePath) {
  console.error('Usage: node hexdump.js <filename>');
  process.exit(1);
}

const BYTES_PER_LINE = 16;
const buf = Buffer.alloc(BYTES_PER_LINE);
const fd = fs.openSync(filePath, 'r');
let offset = 0;

// TODO: Implement the read loop
// 1. Read BYTES_PER_LINE bytes at current offset
// 2. Format offset column
// 3. Format hex column (with midpoint gap after byte 8)
// 4. Format ASCII column (printable chars or '.')
// 5. Handle last-line padding
// 6. Print the assembled line
// 7. Advance offset by bytesRead

fs.closeSync(fd);
```

Key functions you will need:

```javascript
function formatHex(buf, bytesRead) {
  // Build hex string with spaces between bytes
  // Add extra space after byte 8 for midpoint gap
  // Pad with spaces if bytesRead < BYTES_PER_LINE
}

function formatAscii(buf, bytesRead) {
  // For each byte 0..bytesRead-1:
  //   printable (0x20-0x7E) -> String.fromCharCode(byte)
  //   non-printable -> '.'
}
```

## Break-Then-Harden Challenge

### Scenario 1 — Buffer Reuse Bug
Remove the `Buffer.alloc(16)` and replace it with `Buffer.allocUnsafe(16)`. Run against a file whose size is not a multiple of 16. Observe that the last line shows garbage bytes beyond the actual data. Fix it by using only the `bytesRead` return value to limit your hex and ASCII formatting loops.

### Scenario 2 — Encoding Mismatch
Replace your byte-by-byte ASCII check with `buf.toString('utf8')` for the entire 16-byte chunk. Run against a binary file containing multi-byte UTF-8 sequences (e.g., a file with emoji). Observe broken replacement characters. Fix it by never using string decoding for the ASCII column — always inspect raw byte values individually.

### Scenario 3 — Empty File
Run your tool against a zero-byte file (`touch empty.txt`). Ensure it exits cleanly without printing any hex lines and without crashing on the first `readSync` returning 0.

## Expected Output

```
$ node hexdump.js hexdump.js
00000000: 27 75 73 65 20 73 74 72  69 63 74 27 3b 0a 0a 63  'use str ict';..c
00000010: 6f 6e 73 74 20 66 73 20  3d 20 72 65 71 75 69 72  onst fs  = requir
00000020: 65 28 27 6e 6f 64 65 3a  66 73 27 29 3b 0a 63 6f  e('node: fs');.co
00000030: 6e 73 74 20 70 61 74 68  20 3d 20 72 65 71 75 69  nst path  = requi
00000040: 72 65 28 27 6e 6f 64 65  3a 70 61 74 68 27 29 3b  re('node :path');
...

$ node hexdump.js /bin/ls | head -5
00000000: cf fa ed fe 07 00 00 01  03 00 00 00 02 00 00 00  ........ ........
00000010: 12 00 00 00 a8 05 00 00  85 00 20 00 00 00 00 00  ........ .. .....
00000020: 19 00 00 00 48 00 00 00  5f 5f 50 41 47 45 5a 45  ....H... __PAGEZE
00000030: 52 4f 00 00 00 00 00 00  00 00 00 00 00 00 00 00  RO...... ........
00000040: 00 00 00 01 00 00 00 00  00 00 00 00 00 00 00 00  ........ ........

$ node hexdump.js empty.txt
(no output — clean exit)

$ node hexdump.js
Usage: node hexdump.js <filename>

$ echo -n "Short" | node hexdump.js /dev/stdin
00000000: 53 68 6f 72 74                                    Short
```

## Bonus

1. **Add a `-n <count>` flag** that limits output to the first N bytes (like `xxd -l`). Parse it from `process.argv` before the filename.

2. **Add color output.** Use ANSI escape codes to highlight null bytes (`\x00`) in red and printable ASCII in green within the hex column. The escape codes are:
   - Red: `\x1b[31m` ... `\x1b[0m`
   - Green: `\x1b[32m` ... `\x1b[0m`

3. **Add reverse mode.** Accept hex input on stdin and convert it back to binary, like `xxd -r`. Parse the hex column, ignore the offset and ASCII columns, and write raw bytes to stdout.

## Hints

1. `byte.toString(16).padStart(2, '0')` converts a single byte to its two-character hex representation.

2. `offset.toString(16).padStart(8, '0')` gives you the zero-padded offset column.

3. A byte is printable ASCII if `byte >= 0x20 && byte <= 0x7E`.

4. When the last chunk is shorter than 16 bytes, you need `(16 - bytesRead) * 3` spaces to pad the hex column (3 characters per missing byte: two hex digits plus a space), plus 1 extra space if `bytesRead <= 8` (for the missing midpoint gap).

5. `fs.readSync()` returns `0` when you have reached the end of the file — use this as your loop termination condition.

6. Structure your main loop as `while (true)`. Read bytes, check if `bytesRead === 0`, and break if so. Otherwise format and print the line, then increment offset by `bytesRead`.

7. To verify your output, run `xxd yourfile | head` and compare it side-by-side with `node hexdump.js yourfile | head`. The only difference should be formatting style (xxd groups bytes in pairs without spaces between pairs).
