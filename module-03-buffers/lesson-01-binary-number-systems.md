# Module 03 / Lesson 01 — Binary Number Systems

> Every file you read, every network packet you send, every image you process is a sequence of ones and zeros. As a Node.js developer, you can get surprisingly far without thinking about binary — until you cannot. The moment you need to parse a protocol, manipulate pixel data, work with hardware, or understand why `Buffer.from([255])` holds the value it does, binary literacy becomes essential. This lesson builds that foundation from the ground up.

## Learning Objectives

- Convert numbers between decimal (base-10), binary (base-2), and back using both mental math and JavaScript APIs
- Explain why a byte ranges from 0 to 255 and how 8 bits compose a byte with place values from 128 down to 1
- Apply JavaScript's bitwise operators (`&`, `|`, `^`, `~`, `<<`, `>>`, `>>>`) to solve practical problems like permission flags and color extraction
- Distinguish between signed and unsigned integer representations, including two's complement for negative numbers
- Connect binary concepts to Node.js `Buffer` objects to understand what Buffer stores and why

---

## Why Binary Matters for Node.js Developers

Node.js is a server-side runtime built around I/O. Every I/O operation deals with binary data:

```javascript
'use strict';

const fs = require('node:fs');

// When you read a file without specifying an encoding,
// Node.js gives you raw binary data as a Buffer
const raw = fs.readFileSync(__filename);
console.log(typeof raw);    // 'object'
console.log(raw.constructor.name); // 'Buffer'
console.log(raw[0]);        // A number 0-255 (the first byte of this file)

// When you specify an encoding, Node.js decodes the bytes into a string
const text = fs.readFileSync(__filename, 'utf8');
console.log(typeof text);   // 'string'

// Under the hood, the string is still binary data that was decoded.
// Understanding binary helps you understand what happens between
// "raw bytes" and "readable text."
```

Binary is not just academic. You will encounter it when:

- Parsing binary file formats (images, PDFs, audio)
- Working with network protocols (TCP packets, WebSocket frames)
- Implementing cryptographic operations
- Interfacing with hardware or embedded systems
- Optimizing performance with bitwise operations
- Debugging encoding issues (mojibake, garbled text)

---

## Base-10 (Decimal) Refresher

Before diving into binary, let us review how decimal numbers work. This makes the leap to other bases intuitive.

In base-10, each digit position has a value that is a power of 10:

```
Number: 4,827

Position:  Thousands  Hundreds  Tens  Ones
Power:     10^3       10^2      10^1  10^0
Value:     1000       100       10    1

Calculation:
  4 × 1000 = 4000
  8 × 100  =  800
  2 × 10   =   20
  7 × 1    =    7
               ────
  Total:     4827
```

The key insight: **the base determines how many unique digits exist and the multiplier for each position**. Base-10 has 10 digits (0-9). Base-2 has 2 digits (0 and 1).

---

## Base-2 (Binary)

Binary uses only two digits: `0` and `1`. Each digit is called a **bit** (binary digit). Each position's value is a power of 2.

### Place Values

```
Bit position:  7    6    5    4    3    2    1    0
Power of 2:    2^7  2^6  2^5  2^4  2^3  2^2  2^1  2^0
Value:         128  64   32   16   8    4    2    1
```

### Converting Binary to Decimal

Add up the place values where the bit is `1`:

```
Binary: 1 1 0 0 1 0 1 0

Position: 7   6   5   4   3   2   1   0
Bit:      1   1   0   0   1   0   1   0
Value:    128 64  --  --  8   --  2   --

Sum: 128 + 64 + 8 + 2 = 202
```

```javascript
'use strict';

// JavaScript confirms our manual calculation
const binary = '11001010';
const decimal = parseInt(binary, 2);
console.log(`Binary ${binary} = Decimal ${decimal}`); // 202

// The 0b prefix denotes binary literals in JavaScript
const fromLiteral = 0b11001010;
console.log(`0b11001010 = ${fromLiteral}`); // 202
```

### Converting Decimal to Binary

Divide by 2 repeatedly, collecting remainders from bottom to top:

```
Decimal 202:

202 ÷ 2 = 101, remainder 0  ← least significant bit
101 ÷ 2 = 50,  remainder 1
 50 ÷ 2 = 25,  remainder 0
 25 ÷ 2 = 12,  remainder 1
 12 ÷ 2 = 6,   remainder 0
  6 ÷ 2 = 3,   remainder 0
  3 ÷ 2 = 1,   remainder 1
  1 ÷ 2 = 0,   remainder 1  ← most significant bit

Read bottom to top: 11001010
```

```javascript
'use strict';

// JavaScript's toString(2) converts decimal to binary string
const decimal = 202;
const binary = decimal.toString(2);
console.log(`Decimal ${decimal} = Binary ${binary}`); // '11001010'

// Pad to 8 bits (a full byte)
const padded = binary.padStart(8, '0');
console.log(`Padded: ${padded}`); // '11001010'

// A function to convert and pad any number
function toBinary8(num) {
  return (num & 0xFF).toString(2).padStart(8, '0');
}

console.log(toBinary8(0));   // '00000000'
console.log(toBinary8(1));   // '00000001'
console.log(toBinary8(127)); // '01111111'
console.log(toBinary8(255)); // '11111111'
```

---

## Bytes: 8 Bits

A **byte** is a group of 8 bits. It is the fundamental unit of data storage and I/O in computing. One byte can represent 2^8 = 256 different values.

```
Minimum byte value:  0000 0000 = 0
Maximum byte value:  1111 1111 = 128 + 64 + 32 + 16 + 8 + 4 + 2 + 1 = 255

Total possible values: 256 (0 through 255)
```

```javascript
'use strict';

// A Buffer is an array of bytes — each element is 0-255
const buf = Buffer.alloc(4);
buf[0] = 0;     // minimum byte value
buf[1] = 127;   // midpoint
buf[2] = 255;   // maximum byte value
buf[3] = 256;   // wraps around! 256 % 256 = 0

console.log(buf);
// <Buffer 00 7f ff 00>
// Notice: 256 became 0 (overflow wraps around)

// Why 255? Because 2^8 - 1 = 255.
// With 8 bits, you have 2^8 = 256 combinations: 0 to 255.
console.log('Max unsigned byte:', 2 ** 8 - 1); // 255
console.log('Total values in a byte:', 2 ** 8); // 256
```

### Common Byte Sizes

| Name | Bits | Bytes | Range (unsigned) |
|------|------|-------|------------------|
| Byte | 8 | 1 | 0 to 255 |
| Word (16-bit) | 16 | 2 | 0 to 65,535 |
| Double Word (32-bit) | 32 | 4 | 0 to 4,294,967,295 |
| Quad Word (64-bit) | 64 | 8 | 0 to 18,446,744,073,709,551,615 |

```javascript
'use strict';

// Buffer methods for different integer sizes
const buf = Buffer.alloc(8);

// Write a 16-bit unsigned integer (2 bytes)
buf.writeUInt16BE(65535, 0); // max value for 16-bit
console.log('16-bit max:', buf.readUInt16BE(0)); // 65535

// Write a 32-bit unsigned integer (4 bytes)
buf.writeUInt32BE(4294967295, 4); // max value for 32-bit
console.log('32-bit max:', buf.readUInt32BE(4)); // 4294967295

console.log('Buffer:', buf);
// <Buffer ff ff 00 00 ff ff ff ff>
```

---

## Signed vs Unsigned Integers

So far we have only discussed unsigned integers (0 and positive). But how do computers represent negative numbers?

### Unsigned

All bits represent magnitude. An 8-bit unsigned integer ranges from 0 to 255.

### Signed: Two's Complement

In two's complement, the most significant bit (MSB) indicates the sign: `0` = positive, `1` = negative. An 8-bit signed integer ranges from -128 to +127.

```
Positive numbers (MSB = 0):
  0000 0000 =   0
  0000 0001 =   1
  0111 1111 = 127  (maximum positive value)

Negative numbers (MSB = 1):
  1111 1111 =  -1
  1111 1110 =  -2
  1000 0000 = -128 (minimum negative value)
```

To negate a number in two's complement: flip all bits, then add 1.

```
 5 in binary:  0000 0101
Flip all bits:  1111 1010
Add 1:          1111 1011  = -5

Check: 0000 0101 + 1111 1011 = 1 0000 0000
       (the carry overflows, leaving 0000 0000 = 0 ✓)
```

```javascript
'use strict';

// Buffer supports both signed and unsigned reads
const buf = Buffer.alloc(1);

// Store the byte value 200
buf[0] = 200;

// Read as unsigned: 200
console.log('Unsigned:', buf.readUInt8(0)); // 200

// Read as signed: -56 (because 200 > 127, MSB is 1)
console.log('Signed:',   buf.readInt8(0));  // -56

// Verify: 200 unsigned = -56 signed
// 200 = 1100 1000
// MSB is 1 → negative in two's complement
// Flip bits: 0011 0111 = 55
// Add 1:     0011 1000 = 56
// Result: -56 ✓

// Signed vs unsigned ranges for 8-bit integers
console.log('\n8-bit integer ranges:');
console.log('Unsigned: 0 to', 2 ** 8 - 1);           // 0 to 255
console.log('Signed:  ', -(2 ** 7), 'to', 2 ** 7 - 1); // -128 to 127
```

---

## Bitwise Operators in JavaScript

JavaScript provides six bitwise operators. They work on 32-bit signed integers internally (numbers are converted to 32-bit ints, the operation is performed, then the result is converted back to a 64-bit float).

### AND (&) — Both Bits Must Be 1

```javascript
'use strict';

// AND: result bit is 1 only if BOTH input bits are 1
//   1010
// & 1100
// ------
//   1000

console.log((0b1010 & 0b1100).toString(2)); // '1000'
console.log(10 & 12); // 8

// Use case: Masking — extract specific bits
const value = 0b11010110; // 214
const lowNibble = value & 0x0F; // mask: 0000 1111
console.log('Low nibble:', lowNibble.toString(2).padStart(4, '0')); // '0110' = 6

const highNibble = (value >> 4) & 0x0F;
console.log('High nibble:', highNibble.toString(2).padStart(4, '0')); // '1101' = 13
```

### OR (|) — Either Bit Can Be 1

```javascript
'use strict';

// OR: result bit is 1 if EITHER input bit is 1
//   1010
// | 1100
// ------
//   1110

console.log((0b1010 | 0b1100).toString(2)); // '1110'
console.log(10 | 12); // 14

// Use case: Setting flags
const READ    = 0b001; // 1
const WRITE   = 0b010; // 2
const EXECUTE = 0b100; // 4

// Combine permissions with OR
const readWrite = READ | WRITE;
console.log('READ | WRITE:', readWrite.toString(2).padStart(3, '0')); // '011' = 3
```

### XOR (^) — Exactly One Bit Must Be 1

```javascript
'use strict';

// XOR: result bit is 1 if inputs DIFFER
//   1010
// ^ 1100
// ------
//   0110

console.log((0b1010 ^ 0b1100).toString(2)); // '110'
console.log(10 ^ 12); // 6

// Use case: Toggle a flag
let flags = 0b101; // read + execute
const WRITE = 0b010;

flags = flags ^ WRITE; // toggle write on
console.log('After toggle ON:', flags.toString(2).padStart(3, '0')); // '111'

flags = flags ^ WRITE; // toggle write off
console.log('After toggle OFF:', flags.toString(2).padStart(3, '0')); // '101'

// XOR property: A ^ B ^ B = A (XOR with same value cancels out)
console.log('Self-cancel:', (42 ^ 99 ^ 99)); // 42
```

### NOT (~) — Flip All Bits

```javascript
'use strict';

// NOT: flip every bit (bitwise complement)
// ~5 = ~(0000 0101) = 1111 1010 (as 32-bit signed int = -6)

console.log(~5);   // -6
console.log(~0);   // -1
console.log(~-1);  // 0

// The pattern: ~n = -(n + 1)
// This is because of two's complement: flipping all bits
// and the implicit +1 gives you -(n+1).

// Use case: checking indexOf (classic trick, now mostly replaced by includes())
const arr = [10, 20, 30];
const idx = arr.indexOf(20);
if (~idx) { // ~(-1) = 0 (falsy), ~(anything else) is truthy
  console.log('Found at index', idx);
}
```

### Left Shift (<<) — Multiply by Powers of 2

```javascript
'use strict';

// Left shift: move bits left, fill right with zeros
// Equivalent to multiplying by 2^n

console.log(1 << 0); //   1 (2^0)
console.log(1 << 1); //   2 (2^1)
console.log(1 << 2); //   4 (2^2)
console.log(1 << 3); //   8 (2^3)
console.log(1 << 7); // 128 (2^7)
console.log(1 << 8); // 256 (2^8)

// Use case: creating bit flags
const FLAG_A = 1 << 0; // 0001 = 1
const FLAG_B = 1 << 1; // 0010 = 2
const FLAG_C = 1 << 2; // 0100 = 4
const FLAG_D = 1 << 3; // 1000 = 8

console.log('Flags:', FLAG_A, FLAG_B, FLAG_C, FLAG_D);

// Combine flags
const combined = FLAG_A | FLAG_C; // 0101 = 5
console.log('A + C:', combined.toString(2)); // '101'
```

### Right Shift (>> and >>>) — Divide by Powers of 2

```javascript
'use strict';

// >> (signed right shift): preserves the sign bit
console.log(16 >> 1);  //  8  (16 / 2)
console.log(16 >> 2);  //  4  (16 / 4)
console.log(-16 >> 1); // -8  (sign preserved)

// >>> (unsigned right shift): fills with zeros, ignores sign
console.log(16 >>> 1);  //  8
console.log(-1 >>> 0);  //  4294967295 (all 32 bits set to 1, unsigned)

// Use case: fast integer division by power of 2
const pixels = 1920;
const halfWidth = pixels >> 1;
console.log('Half width:', halfWidth); // 960

// Use case: convert to unsigned 32-bit integer
const signed = -1;
const unsigned = signed >>> 0;
console.log('Signed:', signed);     // -1
console.log('Unsigned:', unsigned); // 4294967295
```

---

## Practical Examples

### Example 1: IP Address Octets

An IPv4 address is 4 bytes (32 bits), often written as four decimal numbers separated by dots.

```javascript
'use strict';

// An IP address like 192.168.1.100 is 4 bytes
function ipToUint32(ip) {
  const parts = ip.split('.').map(Number);
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

function uint32ToIp(num) {
  return [
    (num >>> 24) & 0xFF,
    (num >>> 16) & 0xFF,
    (num >>> 8)  & 0xFF,
    num          & 0xFF,
  ].join('.');
}

const ip = '192.168.1.100';
const packed = ipToUint32(ip);
console.log(`IP ${ip} → ${packed} (0x${packed.toString(16)})`);
// IP 192.168.1.100 → 3232235876 (0xc0a80164)

const unpacked = uint32ToIp(packed);
console.log(`${packed} → ${unpacked}`);
// 3232235876 → 192.168.1.100

// Each octet is one byte (0-255):
console.log('Octets in binary:');
ip.split('.').forEach((octet) => {
  console.log(`  ${octet.padStart(3)} = ${Number(octet).toString(2).padStart(8, '0')}`);
});
```

### Example 2: RGB Colors

Each color channel (Red, Green, Blue) is one byte (0-255). A 24-bit color packs three bytes into one number.

```javascript
'use strict';

// Pack RGB into a single 24-bit integer
function rgbToInt(r, g, b) {
  return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
}

// Extract channels from a 24-bit color
function intToRgb(color) {
  return {
    r: (color >> 16) & 0xFF,
    g: (color >> 8)  & 0xFF,
    b: color         & 0xFF,
  };
}

const orange = rgbToInt(255, 165, 0);
console.log(`Orange: 0x${orange.toString(16).padStart(6, '0')}`);
// Orange: 0xffa500

const channels = intToRgb(orange);
console.log('Channels:', channels);
// { r: 255, g: 165, b: 0 }

// Show the binary breakdown
console.log('\nBinary breakdown of orange (0xFFA500):');
console.log('  R:', (255).toString(2).padStart(8, '0'), '= 255');
console.log('  G:', (165).toString(2).padStart(8, '0'), '= 165');
console.log('  B:', (0).toString(2).padStart(8, '0'),   '=   0');
```

### Example 3: Permission Flags

Unix-style permissions use bitwise flags — a pattern you will see in `fs.constants`.

```javascript
'use strict';

const fs = require('node:fs');

// Define permission flags using bit shifts
const PERM_READ    = 1 << 2; // 4 = 100
const PERM_WRITE   = 1 << 1; // 2 = 010
const PERM_EXECUTE = 1 << 0; // 1 = 001

// Grant permissions using OR
let userPerms = PERM_READ | PERM_WRITE; // 6 = 110
console.log('User permissions:', userPerms.toString(2).padStart(3, '0')); // '110'

// Check a specific permission using AND
function hasPermission(perms, flag) {
  return (perms & flag) !== 0;
}

console.log('Has read?',    hasPermission(userPerms, PERM_READ));    // true
console.log('Has write?',   hasPermission(userPerms, PERM_WRITE));   // true
console.log('Has execute?', hasPermission(userPerms, PERM_EXECUTE)); // false

// Revoke a permission using AND with NOT
userPerms = userPerms & ~PERM_WRITE; // clear the write bit
console.log('After revoking write:', userPerms.toString(2).padStart(3, '0')); // '100'
console.log('Has write?', hasPermission(userPerms, PERM_WRITE)); // false

// Node.js fs.constants uses the same pattern:
console.log('\nNode.js file permission constants:');
console.log('  S_IRUSR (owner read): ', fs.constants.S_IRUSR?.toString(8));
console.log('  S_IWUSR (owner write):', fs.constants.S_IWUSR?.toString(8));
console.log('  S_IXUSR (owner exec): ', fs.constants.S_IXUSR?.toString(8));
```

---

## Connecting Binary to Node.js Buffers

A `Buffer` is simply an array of bytes. Each byte is a number from 0 to 255. You can construct Buffers from binary literals to see the connection directly.

```javascript
'use strict';

// Create a Buffer from binary values
const buf = Buffer.from([
  0b11001010, // 202
  0b00110101, // 53
  0b11111111, // 255
  0b00000000, // 0
  0b10000001, // 129
]);

console.log('Buffer:', buf);
// <Buffer ca 35 ff 00 81>

// Each byte displayed in hex — we will explore hex in Lesson 02
console.log('\nByte-by-byte:');
for (let i = 0; i < buf.length; i++) {
  const byte = buf[i];
  console.log(
    `  [${i}] decimal: ${byte.toString().padStart(3)}`
    + `  binary: ${byte.toString(2).padStart(8, '0')}`
    + `  hex: ${byte.toString(16).padStart(2, '0')}`
  );
}
// [0] decimal: 202  binary: 11001010  hex: ca
// [1] decimal:  53  binary: 00110101  hex: 35
// [2] decimal: 255  binary: 11111111  hex: ff
// [3] decimal:   0  binary: 00000000  hex: 00
// [4] decimal: 129  binary: 10000001  hex: 81
```

```javascript
'use strict';

// The string "Hi" in binary
const greeting = Buffer.from('Hi', 'utf8');

console.log('String "Hi" as bytes:');
for (let i = 0; i < greeting.length; i++) {
  const byte = greeting[i];
  const char = String.fromCharCode(byte);
  console.log(
    `  '${char}' → decimal: ${byte}`
    + `  binary: ${byte.toString(2).padStart(8, '0')}`
  );
}
// 'H' → decimal: 72  binary: 01001000
// 'i' → decimal: 105 binary: 01101001

// Every character in a text file is stored as one or more bytes.
// ASCII characters (0-127) are one byte each.
// UTF-8 characters beyond ASCII use 2-4 bytes (covered in Lesson 03).
```

---

## Quick Reference: Powers of 2

These values come up constantly when working with binary data:

| Power | Value | Common Use |
|-------|-------|------------|
| 2^0 | 1 | Single bit flag |
| 2^1 | 2 | |
| 2^2 | 4 | |
| 2^3 | 8 | Bits in a byte |
| 2^4 | 16 | Hex digit range (0-F) |
| 2^7 | 128 | MSB of a byte |
| 2^8 | 256 | Values in a byte (0-255) |
| 2^10 | 1,024 | 1 KiB (kibibyte) |
| 2^16 | 65,536 | Values in 2 bytes |
| 2^20 | 1,048,576 | 1 MiB (mebibyte) |
| 2^24 | 16,777,216 | RGB color space (256^3) |
| 2^32 | 4,294,967,296 | IPv4 address space, 32-bit int |

```javascript
'use strict';

// Verify the table
const powers = [0, 1, 2, 3, 4, 7, 8, 10, 16, 20, 24, 32];
console.log('Power of 2 | Value');
console.log('-----------|-----------------');
for (const p of powers) {
  console.log(`  2^${p.toString().padStart(2)}     | ${(2 ** p).toLocaleString()}`);
}
```

---

## Key Takeaways

- Binary (base-2) uses only two digits (0 and 1); each position is a power of 2, and a byte is 8 bits with place values 128, 64, 32, 16, 8, 4, 2, 1 — giving a range of 0 to 255 for unsigned values
- Converting between binary and decimal is straightforward: sum the place values of set bits (binary to decimal) or repeatedly divide by 2 collecting remainders (decimal to binary) — JavaScript's `parseInt(str, 2)` and `toString(2)` do this for you
- JavaScript's bitwise operators (`&`, `|`, `^`, `~`, `<<`, `>>`, `>>>`) operate on 32-bit signed integers and are essential for permission flags, color extraction, IP address packing, and protocol parsing
- Two's complement representation allows signed integers: the most significant bit indicates sign, and the range for an 8-bit signed integer is -128 to +127 — which is why `Buffer.readInt8()` and `Buffer.readUInt8()` return different values for the same byte
- A Node.js `Buffer` is an array of bytes (each 0-255), and understanding binary is the key to understanding what `Buffer.from([0b11001010, 0b00110101])` actually stores and how to manipulate it

## Next

Continue to [Lesson 02 — Hexadecimal & Octal](lesson-02-hexadecimal-octal.md) to learn why hexadecimal is the preferred notation for binary data and how octal drives Unix file permissions.
