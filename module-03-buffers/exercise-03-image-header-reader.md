# E03: Image Header Reader

> Extract image dimensions from PNG, JPEG, and GIF files by reading only the first few hundred bytes. No image libraries, no full file loads — just raw Buffer parsing of binary file format headers.

## Objective

Build an `imginfo.js` CLI tool that reads the magic bytes of an image file to identify its format, then parses the format-specific header to extract width and height — all without loading the entire image into memory. This exercise teaches you to navigate real-world binary formats using offsets, marker scanning, and multi-byte integer reads.

## Prerequisites

- Module 03, Lesson 02 (Hexadecimal and Octal)
- Module 03, Lesson 04 (Buffer Creation and Allocation)
- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 03, Lesson 06 (Buffer Slicing and Copying)

## Instructions

1. **Create `imginfo.js`** with `'use strict';` and require `node:fs`. Accept a filename from `process.argv[2]`.

2. **Read the first 512 bytes** of the file using `fs.openSync()` and `fs.readSync()`. This is enough to find dimensions in all three formats. Close the fd immediately after reading.

3. **Detect format via magic bytes.** Check the first bytes of the buffer:
   - **PNG:** bytes `0-7` are `89 50 4E 47 0D 0A 1A 0A`
   - **JPEG:** bytes `0-1` are `FF D8`
   - **GIF:** bytes `0-5` are `47 49 46 38 39 61` (GIF89a) or `47 49 46 38 37 61` (GIF87a)
   - If none match, print "Unknown format" and exit.

4. **Parse PNG dimensions.** The IHDR chunk starts at byte 8. Bytes 8-11 are the chunk length (UInt32BE), bytes 12-15 are the chunk type (`IHDR` = `49 48 44 52`). Width is UInt32BE at offset 16, height is UInt32BE at offset 20.

5. **Parse GIF dimensions.** Width is UInt16LE at offset 6, height is UInt16LE at offset 8. Note: GIF uses little-endian, unlike PNG.

6. **Parse JPEG dimensions.** JPEG is the hardest because dimensions are not at a fixed offset. You must scan for a Start of Frame marker (SOF0 = `FF C0`). Walk through markers:
   - Start at offset 2.
   - Read 2 bytes: should be `FF xx` where `xx` is the marker type.
   - If `xx` is `C0` (SOF0), read height as UInt16BE at marker+3, width as UInt16BE at marker+5.
   - Otherwise, read the 2-byte segment length at marker+2, skip forward by that length, and continue scanning.

7. **Print results** in a clean format: filename, format, width, and height.

8. **Create test images programmatically.** You do not need an image editor. Build minimal valid image files with Buffers:

   ```javascript
   // Minimal 1x1 PNG (67 bytes)
   function createMinimalPNG() {
     // PNG signature + IHDR + IDAT + IEND
     // This is educational: you are building a valid file format from raw bytes
     const signature = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
     // IHDR: width=1, height=1, bitDepth=8, colorType=2 (RGB)
     const ihdr = Buffer.alloc(25);
     ihdr.writeUInt32BE(13, 0);           // chunk length
     ihdr.write('IHDR', 4, 'ascii');      // chunk type
     ihdr.writeUInt32BE(1, 8);            // width
     ihdr.writeUInt32BE(1, 12);           // height
     ihdr[16] = 8;                        // bit depth
     ihdr[17] = 2;                        // color type (RGB)
     // CRC would go at offset 21 (omitted for brevity)
     return Buffer.concat([signature, ihdr]);
   }
   ```

9. **Test with real images.** Download one PNG, one JPEG, and one GIF from the web. Verify your dimensions match what an image viewer or `file` command reports.

10. **Create a multi-format detector.** Accept multiple filenames on the CLI (`node imginfo.js *.png *.jpg`) and print a summary table with format, dimensions, and file size for each.

```javascript
// Magic byte constants
const PNG_MAGIC  = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
const JPEG_MAGIC = Buffer.from([0xFF, 0xD8]);
const GIF87_MAGIC = Buffer.from('GIF87a', 'ascii');
const GIF89_MAGIC = Buffer.from('GIF89a', 'ascii');
```

Here is the JPEG marker scanner skeleton:

```javascript
function parseJPEG(buf) {
  let offset = 2; // skip FF D8
  while (offset < buf.length - 1) {
    if (buf[offset] !== 0xFF) {
      offset++;
      continue;
    }
    const marker = buf[offset + 1];
    // SOF0 (0xC0) or SOF2 (0xC2) — baseline or progressive
    if (marker === 0xC0 || marker === 0xC2) {
      // height = UInt16BE at offset+3, width = UInt16BE at offset+5
      return {
        height: buf.readUInt16BE(offset + 5),
        width:  buf.readUInt16BE(offset + 7),
      };
    }
    // Skip segment: read length at offset+2, advance past it
    const segLen = buf.readUInt16BE(offset + 2);
    offset += 2 + segLen;
  }
  return null; // SOF not found in buffer
}
```

## Break-Then-Harden Challenge

### Scenario 1 — Read Too Few Bytes
Change the initial read from 512 bytes to 24 bytes. Run against a JPEG file where the SOF0 marker is at offset 300+. Observe that your scanner runs off the end of the buffer. Fix by detecting when you have exhausted the buffer and either reading more bytes from the file or reporting "dimensions not found in first N bytes."

### Scenario 2 — Endianness Confusion
Swap `readUInt16LE` with `readUInt16BE` in the GIF parser. Observe that a 640x480 GIF reports dimensions of 32770x57345 (byte-swapped). Fix and add a comment documenting which formats use which byte order: PNG=BE, GIF=LE, JPEG=BE.

### Scenario 3 — Truncated File
Create a file with only the first 4 bytes of a PNG header (`89 50 4E 47`) and nothing else. Run your tool against it. Observe an out-of-range read crash when trying to access offset 16. Fix by checking `buf.length >= requiredOffset + fieldSize` before every read.

## Expected Output

```
$ node imginfo.js photo.png
File:   photo.png
Format: PNG
Width:  1920
Height: 1080

$ node imginfo.js vacation.jpg
File:   vacation.jpg
Format: JPEG
Width:  4032
Height: 3024

$ node imginfo.js logo.gif
File:   logo.gif
Format: GIF89a
Width:  200
Height: 80

$ node imginfo.js README.md
File:   README.md
Format: Unknown
```

## Bonus

1. **Add BMP support.** BMP magic is `42 4D` ("BM"). Width is Int32LE at offset 18, height is Int32LE at offset 22 (can be negative for top-down bitmaps — use `Math.abs()`).

2. **Add bit depth reporting.** For PNG, bit depth is at IHDR offset+24 (1 byte) and color type at offset+25. Map color type to a human-readable string (grayscale, RGB, palette, grayscale+alpha, RGBA).

## Hints

1. Use `buf.compare(PNG_MAGIC, 0, PNG_MAGIC.length, 0, PNG_MAGIC.length) === 0` or compare byte-by-byte with a loop. The `Buffer.compare()` method is cleaner.

2. For JPEG marker scanning, every marker starts with `0xFF`. If you see `0xFF` followed by `0x00`, that is a stuffed byte inside data — skip it. Valid markers have values `0x01` through `0xFE`.

3. Some JPEG files use progressive encoding (SOF2 = `FF C2`) instead of baseline (SOF0 = `FF C0`). Check for both to handle more files. The dimension layout is identical.

4. `buf.subarray(0, PNG_MAGIC.length)` gives you a view of just the magic bytes for comparison.

5. JPEG segment length (the 2-byte value after the marker) includes the length field itself but not the marker bytes. So to skip to the next marker, advance by `segmentLength` from the position after the marker.
