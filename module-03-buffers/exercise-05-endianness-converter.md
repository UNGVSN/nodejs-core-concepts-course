# E05: Endianness Converter

> Build a utility that converts multi-byte values between big-endian and little-endian byte orders. This is the exercise where byte order stops being abstract theory and becomes a tool you can wield.

## Objective

Create an `endian.js` module that converts integers, floats, and doubles between big-endian (network byte order) and little-endian (x86 native order). Write a test harness that round-trips known values and verifies correctness. By the end, you will be able to look at raw hex bytes and know which endianness you are looking at.

## Prerequisites

- Module 03, Lesson 01 (Binary Number Systems)
- Module 03, Lesson 02 (Hexadecimal and Octal)
- Module 03, Lesson 05 (Buffer Reading and Writing)
- Module 03, Lesson 07 (TypedArrays and ArrayBuffer)

## Instructions

1. **Create `endian.js`** with `'use strict';` and require `node:buffer`.

2. **Implement `swapUInt16(value)`.** Write the value as UInt16BE into a 2-byte Buffer, then read it back as UInt16LE (and vice versa). Return both the swapped value and the hex representation of both byte orders.

   ```javascript
   function swapUInt16(value) {
     const buf = Buffer.alloc(2);
     buf.writeUInt16BE(value, 0);
     const swapped = buf.readUInt16LE(0);
     return {
       original: value,
       swapped,
       beBuf: buf.toString('hex'),
       leBuf: (() => { const b = Buffer.alloc(2); b.writeUInt16LE(value, 0); return b.toString('hex'); })()
     };
   }
   ```

3. **Implement `swapUInt32(value)`.** Same pattern with a 4-byte Buffer. Use `writeUInt32BE` / `readUInt32LE`.

4. **Implement `swapFloat(value)`.** Use `writeFloatBE` / `readFloatLE` with a 4-byte Buffer. Note: swapping endianness of a float does NOT give you a meaningful float value — the bits are reinterpreted. Show the raw hex in both orders.

5. **Implement `swapDouble(value)`.** Same pattern with an 8-byte Buffer using `writeDoubleBE` / `readDoubleLE`.

6. **Implement `swapBytes(buf)`.** A generic byte-reversal function that takes any Buffer and returns a new Buffer with bytes in reversed order. Use this for arbitrary-width values.

7. **Implement `detectEndianness()`.** Use a `Uint16Array` containing `[0x0102]` and check the underlying `ArrayBuffer` bytes to determine the system's native byte order. Print whether the platform is big-endian or little-endian.

   ```javascript
   function detectEndianness() {
     const u16 = new Uint16Array([0x0102]);
     const u8 = new Uint8Array(u16.buffer);
     return u8[0] === 0x02 ? 'little-endian' : 'big-endian';
   }
   ```

8. **Build a test harness.** Test with these known values:
   - `0xABCD` as UInt16: BE = `AB CD`, LE = `CD AB`
   - `0x12345678` as UInt32: BE = `12 34 56 78`, LE = `78 56 34 12`
   - `1.0` as Float: BE = `3F 80 00 00`, LE = `00 00 80 3F`
   - `Math.PI` as Double: verify hex representation in both orders

9. **Build a CLI interface.** Accept `node endian.js <type> <value>` where type is `u16`, `u32`, `f32`, or `f64`. Display the value in both byte orders with hex dumps.

10. **Test with DataView.** Rewrite the swap functions using `DataView` on an `ArrayBuffer` instead of Node.js Buffer methods. Verify identical results. Compare the API ergonomics.

Here is the DataView equivalent for comparison:

```javascript
function swapUInt32DataView(value) {
  const ab = new ArrayBuffer(4);
  const dv = new DataView(ab);
  dv.setUint32(0, value, false); // write as big-endian
  const swapped = dv.getUint32(0, true); // read as little-endian
  return {
    original: value,
    swapped,
    beBuf: Buffer.from(ab).toString('hex'),
  };
}
```

And a hex formatting helper used throughout:

```javascript
function formatHexBytes(buf) {
  return Array.from(buf)
    .map(b => b.toString(16).padStart(2, '0'))
    .join(' ');
}

function formatHexValue(value, width) {
  return '0x' + value.toString(16).toUpperCase().padStart(width, '0');
}
```

## Break-Then-Harden Challenge

### Scenario 1 — Signed vs Unsigned Confusion
Use `writeInt32BE` with a negative value like `-1` and read it back with `readUInt32LE`. Observe that the sign bit gets reinterpreted, producing a large positive number. Fix by keeping signed reads with signed writes. Add assertions that check `typeof` and value range before writing.

### Scenario 2 — Float Precision Trap
Write `0.1` as a Float (32-bit) and read it back. Observe that the value is NOT exactly `0.1` due to IEEE 754 single-precision rounding. Compare with writing `0.1` as a Double (64-bit). Document the precision difference and add a `tolerance` parameter to your float comparison function.

### Scenario 3 — Buffer Size Mismatch
Call `writeUInt32BE` on a 2-byte Buffer. Observe the `RangeError`. Fix by adding size validation at the top of each swap function: `if (buf.length < requiredSize) throw new RangeError(...)`.

## Expected Output

```
$ node endian.js
=== System Endianness ===
This platform is: little-endian

=== UInt16 Swap ===
Value:  0xABCD (43981)
  BE:   ab cd
  LE:   cd ab
  Swap: 0xCDAB (52651)

=== UInt32 Swap ===
Value:  0x12345678 (305419896)
  BE:   12 34 56 78
  LE:   78 56 34 12
  Swap: 0x78563412 (2018915346)

=== Float Swap ===
Value:  1.0
  BE:   3f 80 00 00
  LE:   00 00 80 3f

=== Double Swap ===
Value:  3.141592653589793 (Math.PI)
  BE:   40 09 21 fb 54 44 2d 18
  LE:   18 2d 44 54 fb 21 09 40

=== CLI Mode ===
$ node endian.js u32 305419896
Type:   UInt32
Value:  305419896 (0x12345678)
  BE:   12 34 56 78
  LE:   78 56 34 12
```

## Bonus

1. **Implement `hton` and `ntoh` functions** (host-to-network and network-to-host) that mirror the C standard library. Network byte order is always big-endian. These should be no-ops on big-endian systems and byte-swaps on little-endian systems.

2. **Build a hex editor mode.** Accept raw hex input (`node endian.js hex "12 34 56 78"`) and display interpreting it as UInt16BE, UInt16LE, UInt32BE, UInt32LE, FloatBE, FloatLE, DoubleBE, and DoubleLE — showing all possible interpretations of those bytes.

## Hints

1. `Buffer.alloc(4)` gives you a zeroed 4-byte buffer. Writing a value to it in one endianness and reading in the other performs the swap.

2. `value.toString(16).padStart(expectedHexChars, '0')` formats the value as hex. UInt16 needs 4 hex chars, UInt32 needs 8.

3. `DataView` methods accept a `littleEndian` boolean as the last parameter: `dv.getUint32(0, true)` reads little-endian, `dv.getUint32(0, false)` reads big-endian.

4. `Buffer.prototype.swap16()`, `.swap32()`, and `.swap64()` exist in Node.js and perform in-place byte swapping. Compare your manual implementation's output with these built-in methods.

5. IEEE 754 single-precision (Float32) has ~7 decimal digits of precision. Double-precision (Float64) has ~15. This is why `0.1` as Float32 round-trips to `0.10000000149011612`.
