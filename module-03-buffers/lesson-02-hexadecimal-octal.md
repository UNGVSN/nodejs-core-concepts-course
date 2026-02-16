# Module 03 / Lesson 02 — Hexadecimal & Octal

> Hexadecimal is the lingua franca of low-level computing. Every time you see a Buffer printed in Node.js, a color code in CSS, a MAC address on a network interface, or a UUID in a database, you are reading hexadecimal. Octal may seem obscure until you try to set Unix file permissions with `fs.chmod()`. This lesson gives you fluency in both number systems and connects them directly to everyday Node.js work.

## Learning Objectives

- Read and write hexadecimal values fluently, converting between hex, binary, and decimal by hand and with JavaScript APIs
- Explain why hexadecimal is the standard representation for binary data — one hex digit maps exactly to four bits
- Use `Buffer.toString('hex')` and `Buffer.from(hexString, 'hex')` to round-trip between Buffer and hex string representations
- Interpret and construct octal values for Unix file permissions using `fs.chmod()`, `fs.stat()`, and `fs.constants`
- Build a hex viewer that displays binary files in the same format as command-line tools like `xxd` and `hexdump`

---

## Hexadecimal: Base-16

Hexadecimal (hex) uses 16 digits: `0-9` for values 0-9, and `A-F` for values 10-15. Each hex digit represents exactly 4 bits (a nibble), which is why hex is the perfect shorthand for binary data.

### The Hex Digit Table

| Decimal | Hex | Binary |
|---------|-----|--------|
| 0 | 0 | 0000 |
| 1 | 1 | 0001 |
| 2 | 2 | 0010 |
| 3 | 3 | 0011 |
| 4 | 4 | 0100 |
| 5 | 5 | 0101 |
| 6 | 6 | 0110 |
| 7 | 7 | 0111 |
| 8 | 8 | 1000 |
| 9 | 9 | 1001 |
| 10 | A | 1010 |
| 11 | B | 1011 |
| 12 | C | 1100 |
| 13 | D | 1101 |
| 14 | E | 1110 |
| 15 | F | 1111 |

The critical insight: **one byte = two hex digits.** The byte value 255 (binary `11111111`) is `FF` in hex. The byte value 0 (binary `00000000`) is `00`. This 1:2 mapping is why hex is universally used to display binary data.

```javascript
'use strict';

// One byte has exactly two hex digits
// High nibble (4 bits) + Low nibble (4 bits) = 1 byte (8 bits)

const byte = 0xCA; // 202 in decimal

const highNibble = (byte >> 4) & 0x0F; // C = 12
const lowNibble  = byte & 0x0F;        // A = 10

console.log(`Byte: 0x${byte.toString(16).toUpperCase()}`);
console.log(`  High nibble: ${highNibble.toString(16).toUpperCase()} (${highNibble})`);
console.log(`  Low nibble:  ${lowNibble.toString(16).toUpperCase()} (${lowNibble})`);
console.log(`  Binary: ${byte.toString(2).padStart(8, '0')}`);
// Byte: 0xCA
//   High nibble: C (12)
//   Low nibble:  A (10)
//   Binary: 11001010
```

---

## Converting Between Hex, Binary, and Decimal

### Hex to Binary

Replace each hex digit with its 4-bit binary equivalent:

```
Hex:    C       A
Binary: 1100    1010
Result: 11001010 = 202 decimal
```

### Binary to Hex

Group binary digits into nibbles (4-bit groups) from right to left, then convert each nibble:

```
Binary: 0 1 1 0 1 0 0 1
Groups: 0110    1001
Hex:    6       9
Result: 0x69 = 105 decimal
```

### Hex to Decimal

Multiply each hex digit by its positional power of 16:

```
Hex: 1F4

1 × 16^2 = 1 × 256 = 256
F × 16^1 = 15 × 16 = 240
4 × 16^0 = 4 × 1   =   4
                      ─────
                       500
```

```javascript
'use strict';

// JavaScript provides clean APIs for all conversions

// Hex to decimal
console.log('Hex to decimal:');
console.log('  parseInt("CA", 16) =', parseInt('CA', 16));   // 202
console.log('  parseInt("1F4", 16) =', parseInt('1F4', 16)); // 500
console.log('  0xFF =', 0xFF);                                // 255

// Decimal to hex
console.log('\nDecimal to hex:');
console.log('  (202).toString(16) =', (202).toString(16));    // 'ca'
console.log('  (500).toString(16) =', (500).toString(16));    // '1f4'
console.log('  (255).toString(16) =', (255).toString(16));    // 'ff'

// Binary to hex (via decimal)
console.log('\nBinary to hex:');
const decimal = parseInt('11001010', 2); // binary → decimal
console.log('  11001010 →', decimal.toString(16)); // 'ca'

// Hex to binary
console.log('\nHex to binary:');
console.log('  0xCA →', (0xCA).toString(2).padStart(8, '0')); // '11001010'
```

### Comprehensive Converter Function

```javascript
'use strict';

function convertNumber(value, fromBase) {
  const decimal = parseInt(String(value), fromBase);
  if (Number.isNaN(decimal)) {
    throw new Error(`Invalid value "${value}" for base ${fromBase}`);
  }
  return {
    decimal,
    binary:      decimal.toString(2),
    octal:       decimal.toString(8),
    hexadecimal: decimal.toString(16).toUpperCase(),
  };
}

console.log('From decimal 255:',   convertNumber(255, 10));
console.log('From hex FF:',        convertNumber('FF', 16));
console.log('From binary 11111111:', convertNumber('11111111', 2));
console.log('From octal 377:',     convertNumber('377', 8));

// All four produce:
// { decimal: 255, binary: '11111111', octal: '377', hexadecimal: 'FF' }
```

---

## Hex in Node.js Buffers

When Node.js prints a Buffer, it shows each byte as two hex digits. This is the most common place you will encounter hex in Node.js.

```javascript
'use strict';

// Buffer displays as hex by default
const buf = Buffer.from([202, 53, 255, 0, 129]);
console.log('Buffer:', buf);
// <Buffer ca 35 ff 00 81>

// Convert Buffer to hex string
const hexStr = buf.toString('hex');
console.log('Hex string:', hexStr);
// 'ca35ff0081'

// Convert hex string back to Buffer
const restored = Buffer.from(hexStr, 'hex');
console.log('Restored:', restored);
// <Buffer ca 35 ff 00 81>

// Verify they are identical
console.log('Equal:', Buffer.compare(buf, restored) === 0); // true
```

```javascript
'use strict';

// Reading a file as hex
const fs = require('node:fs');

// Create a small test file
const testData = Buffer.from('Hello, World!', 'utf8');
fs.writeFileSync('/tmp/hex-test.bin', testData);

// Read it back as a Buffer and display as hex
const raw = fs.readFileSync('/tmp/hex-test.bin');
console.log('Raw buffer:', raw);
console.log('Hex:',        raw.toString('hex'));
console.log('UTF-8:',      raw.toString('utf8'));

// Show byte-by-byte
console.log('\nByte table:');
console.log('Offset  Hex  Dec  Char');
console.log('------  ---  ---  ----');
for (let i = 0; i < raw.length; i++) {
  const byte = raw[i];
  const char = byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : '.';
  console.log(
    `  ${i.toString().padStart(4, '0')}   ${byte.toString(16).padStart(2, '0')}`
    + `  ${byte.toString().padStart(3)}   ${char}`
  );
}

// Clean up
fs.unlinkSync('/tmp/hex-test.bin');
```

---

## Building a Hex Viewer

A hex viewer (like `xxd` or `hexdump`) displays binary files in a structured format: offset, hex bytes, and ASCII representation. This is one of the most useful debugging tools for binary data.

```javascript
'use strict';

const fs = require('node:fs');

function hexDump(buffer, bytesPerLine = 16) {
  const lines = [];

  for (let offset = 0; offset < buffer.length; offset += bytesPerLine) {
    // Offset column
    const offsetStr = offset.toString(16).padStart(8, '0');

    // Hex bytes column
    const hexParts = [];
    const asciiParts = [];

    for (let i = 0; i < bytesPerLine; i++) {
      const idx = offset + i;
      if (idx < buffer.length) {
        hexParts.push(buffer[idx].toString(16).padStart(2, '0'));
        // Printable ASCII range: 32-126
        const byte = buffer[idx];
        asciiParts.push(byte >= 32 && byte <= 126 ? String.fromCharCode(byte) : '.');
      } else {
        hexParts.push('  '); // padding for incomplete last line
        asciiParts.push(' ');
      }
    }

    // Group hex bytes in pairs of 8 for readability
    const hexLeft  = hexParts.slice(0, 8).join(' ');
    const hexRight = hexParts.slice(8).join(' ');
    const ascii    = asciiParts.join('');

    lines.push(`${offsetStr}  ${hexLeft}  ${hexRight}  |${ascii}|`);
  }

  // Footer with total size
  lines.push(`${buffer.length.toString(16).padStart(8, '0')} (${buffer.length} bytes)`);

  return lines.join('\n');
}

// Test with this script's own source code
const source = fs.readFileSync(__filename);
console.log(hexDump(source.subarray(0, 128)));

// Output looks like:
// 00000000  27 75 73 65 20 73 74 72  69 63 74 27 3b 0a 0a 63  |'use strict';..c|
// 00000010  6f 6e 73 74 20 66 73 20  3d 20 72 65 71 75 69 72  |onst fs = requir|
// ...
```

```javascript
'use strict';

const fs = require('node:fs');

// Hex viewer for a file path provided as a CLI argument
function hexView(filePath, maxBytes) {
  const fd = fs.openSync(filePath, 'r');
  const stat = fs.fstatSync(fd);
  const readSize = maxBytes ? Math.min(maxBytes, stat.size) : stat.size;
  const buffer = Buffer.alloc(readSize);

  fs.readSync(fd, buffer, 0, readSize, 0);
  fs.closeSync(fd);

  console.log(`File: ${filePath}`);
  console.log(`Size: ${stat.size} bytes (showing first ${readSize})`);
  console.log('---');

  const bytesPerLine = 16;
  for (let offset = 0; offset < buffer.length; offset += bytesPerLine) {
    const slice = buffer.subarray(offset, Math.min(offset + bytesPerLine, buffer.length));

    const hex = Array.from(slice)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join(' ')
      .padEnd(bytesPerLine * 3 - 1);

    const ascii = Array.from(slice)
      .map((b) => (b >= 32 && b <= 126) ? String.fromCharCode(b) : '.')
      .join('');

    console.log(`${offset.toString(16).padStart(8, '0')}  ${hex}  |${ascii}|`);
  }
}

// Usage: node lesson-02.js /path/to/file [maxBytes]
const filePath = process.argv[2] || __filename;
const maxBytes = parseInt(process.argv[3], 10) || 256;
hexView(filePath, maxBytes);
```

---

## Color Codes: #FF5733

CSS hex color codes are three bytes packed into six hex digits: two for Red, two for Green, two for Blue.

```javascript
'use strict';

function parseHexColor(hex) {
  // Remove # prefix if present
  const clean = hex.replace(/^#/, '');

  if (clean.length === 3) {
    // Short form: #F53 → #FF5533
    const [r, g, b] = clean.split('').map((c) => parseInt(c + c, 16));
    return { r, g, b };
  }

  if (clean.length === 6) {
    const r = parseInt(clean.substring(0, 2), 16);
    const g = parseInt(clean.substring(2, 4), 16);
    const b = parseInt(clean.substring(4, 6), 16);
    return { r, g, b };
  }

  throw new Error(`Invalid hex color: ${hex}`);
}

function rgbToHex(r, g, b) {
  return '#' + [r, g, b]
    .map((c) => Math.max(0, Math.min(255, c)).toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase();
}

// Parse hex colors
console.log('Parse #FF5733:', parseHexColor('#FF5733'));
// { r: 255, g: 87, b: 51 }

console.log('Parse #F53:',    parseHexColor('#F53'));
// { r: 255, g: 85, b: 51 }

// Build hex colors
console.log('Build white:',    rgbToHex(255, 255, 255)); // '#FFFFFF'
console.log('Build black:',    rgbToHex(0, 0, 0));       // '#000000'
console.log('Build red:',      rgbToHex(255, 0, 0));     // '#FF0000'
console.log('Build sky blue:', rgbToHex(135, 206, 235));  // '#87CEEB'
```

```javascript
'use strict';

// Store colors in a Buffer — each color is 3 bytes
const palette = Buffer.alloc(4 * 3); // 4 colors, 3 bytes each

const colors = [
  { name: 'Red',    r: 255, g: 0,   b: 0   },
  { name: 'Green',  r: 0,   g: 255, b: 0   },
  { name: 'Blue',   r: 0,   g: 0,   b: 255 },
  { name: 'Yellow', r: 255, g: 255, b: 0   },
];

colors.forEach((color, i) => {
  palette[i * 3]     = color.r;
  palette[i * 3 + 1] = color.g;
  palette[i * 3 + 2] = color.b;
});

console.log('Palette buffer:', palette.toString('hex'));
// 'ff0000 00ff00 0000ff ffff00' (without spaces)

// Read colors back
console.log('\nPalette:');
for (let i = 0; i < palette.length; i += 3) {
  const hex = palette.subarray(i, i + 3).toString('hex').toUpperCase();
  console.log(`  #${hex} → R:${palette[i]} G:${palette[i+1]} B:${palette[i+2]}`);
}
```

---

## MAC Addresses

A MAC (Media Access Control) address is 6 bytes (48 bits) written as hex pairs separated by colons or hyphens.

```javascript
'use strict';

const os = require('node:os');

// Parse a MAC address string into a Buffer
function parseMac(mac) {
  const bytes = mac.split(/[:\-]/).map((hex) => parseInt(hex, 16));
  if (bytes.length !== 6 || bytes.some((b) => Number.isNaN(b) || b < 0 || b > 255)) {
    throw new Error(`Invalid MAC address: ${mac}`);
  }
  return Buffer.from(bytes);
}

// Format a Buffer as a MAC address string
function formatMac(buf) {
  return Array.from(buf)
    .map((b) => b.toString(16).padStart(2, '0').toUpperCase())
    .join(':');
}

// Parse and round-trip
const mac = 'AA:BB:CC:DD:EE:FF';
const macBuf = parseMac(mac);
console.log('MAC buffer:', macBuf);
// <Buffer aa bb cc dd ee ff>
console.log('Formatted:', formatMac(macBuf));
// 'AA:BB:CC:DD:EE:FF'

// Get the real MAC addresses on this machine
const interfaces = os.networkInterfaces();
console.log('\nNetwork interfaces:');
for (const [name, addrs] of Object.entries(interfaces)) {
  for (const addr of addrs) {
    if (addr.mac && addr.mac !== '00:00:00:00:00:00') {
      console.log(`  ${name}: ${addr.mac} (${addr.family})`);
    }
  }
}
```

---

## UUID Format

A UUID (Universally Unique Identifier) is 128 bits (16 bytes) displayed as 32 hex digits with hyphens in a 8-4-4-4-12 pattern.

```javascript
'use strict';

const crypto = require('node:crypto');

// Generate a UUID v4 using Node.js built-in
const uuid = crypto.randomUUID();
console.log('UUID v4:', uuid);
// e.g., '550e8400-e29b-41d4-a716-446655440000'

// Parse a UUID into its raw bytes
function uuidToBytes(uuid) {
  const hex = uuid.replace(/-/g, '');
  return Buffer.from(hex, 'hex');
}

// Format raw bytes as a UUID string
function bytesToUuid(buf) {
  const hex = buf.toString('hex');
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20, 32),
  ].join('-');
}

// Round-trip
const bytes = uuidToBytes(uuid);
console.log('UUID as bytes:', bytes);
console.log('UUID length:',   bytes.length, 'bytes (128 bits)');
console.log('Restored:',      bytesToUuid(bytes));

// Anatomy of a UUID v4:
// xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
//                ^    ^
//                |    └ variant bits (8, 9, a, or b)
//                └ version (4 = random)

const versionNibble = bytes[6] >> 4;
const variantNibble = bytes[8] >> 4;
console.log('\nUUID analysis:');
console.log('  Version:', versionNibble, '(4 = random)');
console.log('  Variant:', variantNibble.toString(16), '(8-b = RFC 4122)');
```

---

## Octal: Base-8

Octal uses 8 digits: `0-7`. Each octal digit represents exactly 3 bits. In modern JavaScript, octal literals use the `0o` prefix.

```javascript
'use strict';

// Octal literals in JavaScript
console.log('Octal values:');
console.log('  0o0   =', 0o0);    // 0
console.log('  0o7   =', 0o7);    // 7
console.log('  0o10  =', 0o10);   // 8  (1×8 + 0×1)
console.log('  0o77  =', 0o77);   // 63 (7×8 + 7×1)
console.log('  0o100 =', 0o100);  // 64 (1×64 + 0×8 + 0×1)
console.log('  0o377 =', 0o377);  // 255 (3×64 + 7×8 + 7×1)
console.log('  0o755 =', 0o755);  // 493

// Converting to and from octal
console.log('\nConversions:');
console.log('  255 in octal:', (255).toString(8));       // '377'
console.log('  Octal 755 in decimal:', parseInt('755', 8)); // 493

// Octal to binary: replace each octal digit with 3 bits
// 7 = 111, 5 = 101, 5 = 101
// 755 = 111 101 101
console.log('  755 in binary:', (0o755).toString(2)); // '111101101'
```

### Legacy Octal Notation

In older JavaScript (and still in sloppy mode), a leading `0` denoted octal. This is a major source of bugs and is forbidden in strict mode.

```javascript
'use strict';

// In strict mode, legacy octal is a SyntaxError:
// const x = 0755; // SyntaxError: Octal literals are not allowed in strict mode

// Always use the 0o prefix:
const x = 0o755; // correct
console.log('0o755 =', x); // 493

// parseInt treats strings carefully:
console.log(parseInt('0755', 10)); // 755 (decimal)
console.log(parseInt('0755', 8));  // 493 (octal)
console.log(parseInt('755', 8));   // 493 (octal)

// The 0o prefix is parsed correctly by Number():
console.log(Number('0o755')); // 493
```

---

## Octal in Unix: File Permissions

The most common use of octal in everyday programming is Unix file permissions. Each permission set (owner, group, others) is a 3-bit value, mapping perfectly to one octal digit.

```
Permission bits:  r w x
                  4 2 1

Owner:  rwx = 4+2+1 = 7
Group:  r-x = 4+0+1 = 5
Others: r-x = 4+0+1 = 5

Combined: 755 (octal)
```

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Interpret a permission octal value
function describePermissions(mode) {
  const octal = (mode & 0o777).toString(8).padStart(3, '0');
  const rwx = (bits) => {
    return (bits & 4 ? 'r' : '-')
         + (bits & 2 ? 'w' : '-')
         + (bits & 1 ? 'x' : '-');
  };

  const owner = (mode >> 6) & 7;
  const group = (mode >> 3) & 7;
  const other = mode & 7;

  return {
    octal,
    symbolic: rwx(owner) + rwx(group) + rwx(other),
    owner: rwx(owner),
    group: rwx(group),
    other: rwx(other),
  };
}

// Common permission values
const examples = [0o755, 0o644, 0o700, 0o777, 0o600, 0o444];
console.log('Permission  Symbolic    Owner  Group  Other');
console.log('----------  ----------  -----  -----  -----');
for (const perm of examples) {
  const d = describePermissions(perm);
  console.log(
    `  ${d.octal}       ${d.symbolic}   ${d.owner}    ${d.group}    ${d.other}`
  );
}

// Read permissions of this file
const stat = fs.statSync(__filename);
const filePerms = describePermissions(stat.mode);
console.log(`\nThis file: ${filePerms.octal} (${filePerms.symbolic})`);
```

### Using fs.chmod()

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Create a temporary file
const tmpFile = path.join('/tmp', 'perm-test.txt');
fs.writeFileSync(tmpFile, 'test content');

// Check current permissions
const before = fs.statSync(tmpFile);
console.log('Before chmod:', (before.mode & 0o777).toString(8));

// Change permissions to 755 (owner: rwx, group: r-x, others: r-x)
fs.chmodSync(tmpFile, 0o755);
const after = fs.statSync(tmpFile);
console.log('After chmod 755:', (after.mode & 0o777).toString(8));

// Change to 644 (owner: rw-, group: r--, others: r--)
fs.chmodSync(tmpFile, 0o644);
const final = fs.statSync(tmpFile);
console.log('After chmod 644:', (final.mode & 0o777).toString(8));

// Use fs.constants for readable permission flags
console.log('\nfs.constants permission flags:');
console.log('  S_IRWXU (owner rwx):', fs.constants.S_IRWXU?.toString(8)); // '700'
console.log('  S_IRUSR (owner r):',   fs.constants.S_IRUSR?.toString(8)); // '400'
console.log('  S_IWUSR (owner w):',   fs.constants.S_IWUSR?.toString(8)); // '200'
console.log('  S_IXUSR (owner x):',   fs.constants.S_IXUSR?.toString(8)); // '100'

// Clean up
fs.unlinkSync(tmpFile);
```

---

## Parsing Hex Strings

Working with hex strings is a common task when dealing with protocols, hashes, and binary formats.

```javascript
'use strict';

const crypto = require('node:crypto');

// SHA-256 hash produces 32 bytes = 64 hex characters
const hash = crypto.createHash('sha256').update('hello').digest('hex');
console.log('SHA-256 hash:', hash);
console.log('Hash length:', hash.length, 'hex chars =', hash.length / 2, 'bytes');

// Convert hex string to byte array for inspection
const hashBuf = Buffer.from(hash, 'hex');
console.log('Hash as Buffer:', hashBuf);
console.log('Buffer length:', hashBuf.length, 'bytes');

// Compare two hex strings (constant-time to prevent timing attacks)
const hash2 = crypto.createHash('sha256').update('hello').digest('hex');
const hash3 = crypto.createHash('sha256').update('world').digest('hex');

console.log('\nComparing hashes:');
console.log('  hello == hello:', crypto.timingSafeEqual(
  Buffer.from(hash, 'hex'),
  Buffer.from(hash2, 'hex')
)); // true

// timingSafeEqual requires same-length buffers
console.log('  hello == world:', crypto.timingSafeEqual(
  Buffer.from(hash, 'hex'),
  Buffer.from(hash3, 'hex')
)); // false
```

```javascript
'use strict';

// Validate hex strings
function isValidHex(str) {
  return /^[0-9a-fA-F]*$/.test(str) && str.length % 2 === 0;
}

console.log('Valid hex strings:');
console.log('  "48656c6c6f":', isValidHex('48656c6c6f'));   // true (odd length!) — false
console.log('  "48656c6c6f00":', isValidHex('48656c6c6f00')); // true
console.log('  "DEADBEEF":', isValidHex('DEADBEEF'));       // true
console.log('  "0xDEAD":', isValidHex('0xDEAD'));           // false (0x prefix)
console.log('  "GHIJKL":', isValidHex('GHIJKL'));           // false (invalid digits)
console.log('  "":', isValidHex(''));                         // true (empty is valid)

// Hex encode/decode strings
function hexEncode(str) {
  return Buffer.from(str, 'utf8').toString('hex');
}

function hexDecode(hex) {
  return Buffer.from(hex, 'hex').toString('utf8');
}

const encoded = hexEncode('Hello, World!');
console.log('\nEncoded:', encoded); // '48656c6c6f2c20576f726c6421'

const decoded = hexDecode(encoded);
console.log('Decoded:', decoded);   // 'Hello, World!'
```

---

## Hex in Binary File Signatures (Magic Numbers)

Many file formats start with a fixed sequence of bytes called a "magic number" or file signature. These are always documented in hex.

```javascript
'use strict';

const fs = require('node:fs');

// Common file signatures (magic numbers)
const SIGNATURES = {
  'ffd8ff':           'JPEG image',
  '89504e47':         'PNG image',
  '47494638':         'GIF image',
  '25504446':         'PDF document',
  '504b0304':         'ZIP archive (or DOCX/XLSX/JAR)',
  '1f8b':             'Gzip compressed',
  '7f454c46':         'ELF executable (Linux)',
  'cafebabe':         'Java class file',
  '4d5a':             'Windows executable (MZ)',
  '52617221':         'RAR archive',
};

function identifyFile(filePath) {
  const fd = fs.openSync(filePath, 'r');
  const header = Buffer.alloc(8);
  fs.readSync(fd, header, 0, 8, 0);
  fs.closeSync(fd);

  const hex = header.toString('hex');

  for (const [sig, type] of Object.entries(SIGNATURES)) {
    if (hex.startsWith(sig)) {
      return { type, signature: sig, header: hex };
    }
  }

  return { type: 'Unknown', signature: null, header: hex };
}

// Try identifying the Node.js binary itself
const nodePath = process.execPath;
const result = identifyFile(nodePath);
console.log(`File: ${nodePath}`);
console.log(`Type: ${result.type}`);
console.log(`Signature: ${result.signature}`);
console.log(`First 8 bytes: ${result.header}`);
```

---

## Converting Between All Bases: A Cheat Sheet

```javascript
'use strict';

// One function to demonstrate all conversions
function showAllBases(label, decimal) {
  console.log(`${label}:`);
  console.log(`  Decimal:     ${decimal}`);
  console.log(`  Binary:      0b${decimal.toString(2).padStart(8, '0')}`);
  console.log(`  Octal:       0o${decimal.toString(8)}`);
  console.log(`  Hexadecimal: 0x${decimal.toString(16).toUpperCase()}`);
  console.log();
}

showAllBases('Byte min', 0);
showAllBases('Byte max', 255);
showAllBases('ASCII "A"', 65);
showAllBases('Newline', 10);
showAllBases('Permission 755', 493);
showAllBases('Color #FF', 255);
showAllBases('Port 8080', 8080);

// Summary of JavaScript prefix conventions:
console.log('JavaScript numeric literal prefixes:');
console.log('  0b...  Binary       (0b1010 = 10)');
console.log('  0o...  Octal        (0o12 = 10)');
console.log('  0x...  Hexadecimal  (0xA = 10)');
console.log('  (none) Decimal      (10 = 10)');
```

---

## Key Takeaways

- Hexadecimal (base-16) is the standard representation for binary data because one hex digit maps exactly to 4 bits — two hex digits represent one byte, making `FF` = 255 and `00` = 0 the easy bounds to remember
- Node.js Buffers display in hex by default, and you can convert between Buffer and hex strings with `buf.toString('hex')` and `Buffer.from(hexStr, 'hex')` — a round-trip you will use constantly when working with binary protocols, hashes, and file formats
- Octal (base-8) maps one digit to 3 bits, and its primary use in Node.js is Unix file permissions: `0o755` means owner has full access (7=rwx), group and others have read+execute (5=r-x) — pass these values directly to `fs.chmodSync()`
- Hex appears everywhere in practice: CSS color codes (`#FF5733`), MAC addresses (`AA:BB:CC:DD:EE:FF`), UUIDs (`550e8400-e29b-...`), cryptographic hashes, and file signatures (magic numbers like `89504e47` for PNG)
- Building a hex viewer (hex dump) is one of the most practical debugging tools for binary data — reading offset, hex bytes, and ASCII representation side by side reveals structure that is invisible when looking at raw bytes

## Next

Continue to [Lesson 03 — Character Encodings](lesson-03-character-encodings.md) to understand how bytes become text — ASCII, UTF-8, UTF-16, Latin-1 — and why encoding mismatches produce garbled output.
