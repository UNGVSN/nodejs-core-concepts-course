# Module 10 / Lesson 03 — Symmetric Encryption (AES)

> Hashing proves that data has not been tampered with, but it does not hide the data. When you need confidentiality — storing secrets in a database, encrypting files, protecting sensitive payloads — you need encryption. Symmetric encryption uses a single key to both encrypt and decrypt, and AES (Advanced Encryption Standard) is the algorithm that the entire industry trusts. Node.js gives you AES through `crypto.createCipheriv()` and `crypto.createDecipheriv()`, with support for every mode of operation from CBC to the gold-standard GCM.

## Learning Objectives

- Encrypt and decrypt data using AES-256-GCM with proper IV and authentication tag handling
- Explain the differences between ECB, CBC, CTR, and GCM modes and why GCM is the recommended default
- Generate cryptographically secure keys and IVs of the correct size for each algorithm and mode
- Build streaming encryption pipelines that encrypt and decrypt files without loading them into memory
- Avoid the catastrophic mistakes that break symmetric encryption: IV reuse, missing auth tag verification, wrong key lengths

---

## Symmetric Encryption: One Key, Two Operations

In symmetric encryption, the same key performs both encryption and decryption. If you encrypt a message with key `K`, anyone who possesses key `K` can decrypt it. No one else can.

```
Plaintext ──[ Key K + IV ]──▶ Ciphertext ──[ Key K + IV ]──▶ Plaintext
              Encrypt                         Decrypt
```

AES (Advanced Encryption Standard) is a **block cipher** — it operates on fixed-size blocks of 16 bytes (128 bits). The key determines the strength:

| Key Size | Algorithm Name | Security Level |
|----------|---------------|----------------|
| 128 bits (16 bytes) | AES-128 | Good — 2^128 brute-force resistance |
| 192 bits (24 bytes) | AES-192 | Better — rarely used in practice |
| 256 bits (32 bytes) | AES-256 | Best — government/military grade |

AES-256 is the standard recommendation. The 128-bit vs 256-bit debate is largely academic — both are secure against brute-force for the foreseeable future — but 256-bit provides a larger safety margin and is required by some compliance frameworks.

---

## Modes of Operation

A block cipher encrypts exactly one 16-byte block. Real data is larger than 16 bytes, so you need a **mode of operation** that defines how to handle multiple blocks. The mode you choose is critical to security.

### ECB (Electronic Codebook) — Never Use This

ECB encrypts each block independently with the same key. Identical plaintext blocks produce identical ciphertext blocks, which leaks patterns catastrophically.

```
Plaintext:   [Block 1] [Block 2] [Block 1] [Block 3]
ECB Output:  [AAAA]    [BBBB]    [AAAA]    [CCCC]
                                  ^^^^
                          Pattern leaked! An attacker sees Block 1 repeated.
```

The famous "ECB penguin" image demonstrates this — encrypting a bitmap with ECB preserves the visual outline of the image.

**Rule: Never use ECB for anything.** Node.js supports it (`aes-256-ecb`), but only for compatibility with legacy systems.

### CBC (Cipher Block Chaining) — Acceptable with Care

Each block is XORed with the previous ciphertext block before encryption, breaking the pattern. Requires an IV (initialization vector) for the first block.

```
Block 1: Encrypt(Plaintext_1 XOR IV)        = Ciphertext_1
Block 2: Encrypt(Plaintext_2 XOR Cipher_1)  = Ciphertext_2
Block 3: Encrypt(Plaintext_3 XOR Cipher_2)  = Ciphertext_3
```

- Requires padding (PKCS7) because plaintext must be a multiple of 16 bytes.
- Provides confidentiality but **not** integrity — an attacker can flip bits in the ciphertext without detection (padding oracle attacks).
- IV must be 16 bytes and unpredictable.

### CTR (Counter) — Stream-Like Behavior

Turns AES into a stream cipher by encrypting a counter value and XORing the result with plaintext. No padding needed.

- Allows random access (you can decrypt block N without decrypting blocks 1 through N-1).
- Does not provide integrity — requires a separate MAC.
- Nonce must never be reused with the same key.

### GCM (Galois/Counter Mode) — The Gold Standard

GCM combines CTR mode encryption with a Galois field MAC (GMAC), providing **authenticated encryption with associated data (AEAD)**:

```
┌─────────────────────────────────────────────────┐
│  AES-GCM provides:                              │
│  1. Confidentiality — data is encrypted          │
│  2. Integrity — any tampering is detected        │
│  3. Authenticity — proves the encryptor had key   │
│  4. Associated data — authenticates unencrypted   │
│     metadata (e.g., headers)                     │
└─────────────────────────────────────────────────┘
```

- IV/nonce: 12 bytes (96 bits) recommended for GCM.
- Produces an **authentication tag** (16 bytes by default) that must be verified during decryption.
- If the tag does not match, decryption throws — protecting against tampering.

**Use GCM unless you have a specific reason not to.**

---

## AES-256-GCM: The Recommended Implementation

This is the pattern you should use for most encryption needs:

```javascript
'use strict';

const crypto = require('node:crypto');

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;    // 96 bits — recommended for GCM
const TAG_LENGTH = 16;   // 128 bits — authentication tag
const KEY_LENGTH = 32;   // 256 bits — AES-256

// Generate a random encryption key
const key = crypto.randomBytes(KEY_LENGTH);

function encrypt(plaintext, key) {
  // Generate a unique IV for every encryption operation
  const iv = crypto.randomBytes(IV_LENGTH);

  const cipher = crypto.createCipheriv(ALGORITHM, key, iv, {
    authTagLength: TAG_LENGTH,
  });

  // Encrypt the data
  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);

  // Get the authentication tag
  const tag = cipher.getAuthTag();

  // Return IV + tag + ciphertext as a single buffer
  // This makes storage and transmission simple.
  return Buffer.concat([iv, tag, encrypted]);
}

function decrypt(encryptedBuffer, key) {
  // Parse the components
  const iv = encryptedBuffer.subarray(0, IV_LENGTH);
  const tag = encryptedBuffer.subarray(IV_LENGTH, IV_LENGTH + TAG_LENGTH);
  const ciphertext = encryptedBuffer.subarray(IV_LENGTH + TAG_LENGTH);

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv, {
    authTagLength: TAG_LENGTH,
  });

  // Set the authentication tag BEFORE calling update/final
  decipher.setAuthTag(tag);

  // Decrypt
  const decrypted = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(), // Throws if auth tag verification fails
  ]);

  return decrypted.toString('utf8');
}

// Usage
const message = 'This is a secret message that must be protected.';
console.log('Original:', message);

const encrypted = encrypt(message, key);
console.log('Encrypted (hex):', encrypted.toString('hex'));
console.log('Encrypted length:', encrypted.length, 'bytes');

const decrypted = decrypt(encrypted, key);
console.log('Decrypted:', decrypted);
console.log('Match:', message === decrypted); // true
```

### Tamper Detection

GCM's authentication tag catches any modification to the ciphertext:

```javascript
'use strict';

const crypto = require('node:crypto');

const ALGORITHM = 'aes-256-gcm';
const key = crypto.randomBytes(32);

function encrypt(text) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
  const encrypted = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]);
}

function decrypt(buf) {
  const iv = buf.subarray(0, 12);
  const tag = buf.subarray(12, 28);
  const ciphertext = buf.subarray(28);

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

const encrypted = encrypt('Top secret data');
console.log('Normal decrypt:', decrypt(encrypted)); // Works

// Tamper with one byte of the ciphertext
const tampered = Buffer.from(encrypted);
tampered[tampered.length - 1] ^= 0x01; // Flip one bit

try {
  decrypt(tampered);
  console.log('This should never print');
} catch (err) {
  console.log('Tamper detected:', err.message);
  // "Unsupported state or unable to authenticate data"
}
```

---

## Key Generation Strategies

### Random Key

The simplest approach — generate a random key and store it securely:

```javascript
'use strict';

const crypto = require('node:crypto');

// AES-128: 16 bytes
const key128 = crypto.randomBytes(16);
console.log('AES-128 key:', key128.toString('hex'));

// AES-192: 24 bytes
const key192 = crypto.randomBytes(24);
console.log('AES-192 key:', key192.toString('hex'));

// AES-256: 32 bytes
const key256 = crypto.randomBytes(32);
console.log('AES-256 key:', key256.toString('hex'));
```

### Derived Key (from a Password)

When the encryption key must be derived from a human-memorable password, use a KDF:

```javascript
'use strict';

const crypto = require('node:crypto');

function deriveKey(password, salt) {
  return new Promise((resolve, reject) => {
    // scrypt: password → 32-byte AES-256 key
    crypto.scrypt(password, salt, 32, { N: 16384, r: 8, p: 1 }, (err, key) => {
      if (err) return reject(err);
      resolve(key);
    });
  });
}

async function encryptWithPassword(plaintext, password) {
  const salt = crypto.randomBytes(16);
  const key = await deriveKey(password, salt);
  const iv = crypto.randomBytes(12);

  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();

  // Store: salt + iv + tag + ciphertext
  return Buffer.concat([salt, iv, tag, encrypted]);
}

async function decryptWithPassword(encryptedBuffer, password) {
  const salt = encryptedBuffer.subarray(0, 16);
  const iv = encryptedBuffer.subarray(16, 28);
  const tag = encryptedBuffer.subarray(28, 44);
  const ciphertext = encryptedBuffer.subarray(44);

  const key = await deriveKey(password, salt);

  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

(async () => {
  const password = 'my-strong-passphrase';
  const secret = 'Database connection string: postgres://user:pass@host/db';

  const encrypted = await encryptWithPassword(secret, password);
  console.log('Encrypted:', encrypted.toString('base64'));

  const decrypted = await decryptWithPassword(encrypted, password);
  console.log('Decrypted:', decrypted);
})();
```

---

## Streaming Encryption

`Cipher` and `Decipher` are Transform streams. This means you can pipe data through them — encrypting or decrypting files of any size without loading them into memory:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const { pipeline } = require('node:stream/promises');
const path = require('node:path');

const ALGORITHM = 'aes-256-gcm';

async function encryptFile(inputPath, outputPath, key) {
  const iv = crypto.randomBytes(12);

  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);

  // Write IV to the beginning of the output file
  const output = fs.createWriteStream(outputPath);
  output.write(iv); // 12 bytes

  const input = fs.createReadStream(inputPath);

  await pipeline(input, cipher, output);

  // After pipeline completes, write the auth tag
  const tag = cipher.getAuthTag();

  // We need to append the tag to the file
  fs.appendFileSync(outputPath, tag); // 16 bytes at the end

  console.log(`Encrypted: ${inputPath} → ${outputPath}`);
  console.log(`IV: ${iv.toString('hex')}, Tag: ${tag.toString('hex')}`);

  return { iv, tag };
}

async function decryptFile(inputPath, outputPath, key) {
  // Read the entire encrypted file to extract IV and tag
  const data = fs.readFileSync(inputPath);

  const iv = data.subarray(0, 12);
  const tag = data.subarray(data.length - 16);
  const ciphertext = data.subarray(12, data.length - 16);

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(tag);

  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);

  fs.writeFileSync(outputPath, plaintext);
  console.log(`Decrypted: ${inputPath} → ${outputPath}`);
}

// Demo (encrypts this script file)
const key = crypto.randomBytes(32);
const inputFile = __filename;
const encryptedFile = path.join(path.dirname(__filename), 'encrypted.bin');
const decryptedFile = path.join(path.dirname(__filename), 'decrypted.js');

// Uncomment to run:
// (async () => {
//   await encryptFile(inputFile, encryptedFile, key);
//   await decryptFile(encryptedFile, decryptedFile, key);
//
//   // Verify
//   const original = fs.readFileSync(inputFile);
//   const restored = fs.readFileSync(decryptedFile);
//   console.log('Files match:', original.equals(restored));
// })();
```

### A Better Streaming Approach with Header

For robust streaming, write a structured header at the beginning of the encrypted file:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

// File format:
// [1 byte: version] [12 bytes: IV] [encrypted data] [16 bytes: auth tag]
const VERSION = 0x01;

function createEncryptedWriteStream(outputPath, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);

  const output = fs.createWriteStream(outputPath);

  // Write header
  const header = Buffer.alloc(1 + 12);
  header[0] = VERSION;
  iv.copy(header, 1);
  output.write(header);

  // Return a wrapper that appends the auth tag on finish
  cipher.on('end', () => {
    output.write(cipher.getAuthTag());
    output.end();
  });

  return { cipher, iv };
}

// Usage sketch:
// const key = crypto.randomBytes(32);
// const { cipher } = createEncryptedWriteStream('output.enc', key);
// fs.createReadStream('input.txt').pipe(cipher);
```

---

## AES-256-CBC: When You Need Compatibility

Some legacy systems and protocols require CBC mode. Here is how to use it correctly:

```javascript
'use strict';

const crypto = require('node:crypto');

const ALGORITHM = 'aes-256-cbc';
const IV_LENGTH = 16; // CBC requires a 16-byte IV

function encryptCBC(plaintext, key) {
  const iv = crypto.randomBytes(IV_LENGTH);

  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
  // CBC uses PKCS7 padding automatically
  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);

  return Buffer.concat([iv, encrypted]);
}

function decryptCBC(encryptedBuffer, key) {
  const iv = encryptedBuffer.subarray(0, IV_LENGTH);
  const ciphertext = encryptedBuffer.subarray(IV_LENGTH);

  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  const decrypted = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);

  return decrypted.toString('utf8');
}

const key = crypto.randomBytes(32);
const message = 'Hello from CBC mode!';

const encrypted = encryptCBC(message, key);
console.log('CBC encrypted (hex):', encrypted.toString('hex'));
console.log('CBC encrypted length:', encrypted.length, 'bytes');
// Note: CBC output is padded to a multiple of 16 bytes

const decrypted = decryptCBC(encrypted, key);
console.log('CBC decrypted:', decrypted);
```

### CBC vs GCM Side-by-Side

| Feature | AES-256-CBC | AES-256-GCM |
|---------|-------------|-------------|
| **Confidentiality** | Yes | Yes |
| **Integrity** | No (add HMAC manually) | Yes (built-in auth tag) |
| **IV size** | 16 bytes | 12 bytes (recommended) |
| **Padding** | PKCS7 required | No padding needed |
| **Output size** | Input + padding (up to +16 bytes) | Same as input |
| **Performance** | Good | Better (parallelizable + can use AES-NI fully) |
| **Padding oracle attacks** | Vulnerable if error messages differ | Not applicable |
| **Recommendation** | Legacy only | Default choice |

---

## Associated Data (AAD) in GCM

GCM can authenticate additional data that is not encrypted — headers, metadata, routing information:

```javascript
'use strict';

const crypto = require('node:crypto');

const key = crypto.randomBytes(32);
const iv = crypto.randomBytes(12);

// The associated data is authenticated but NOT encrypted.
// An attacker cannot modify it without invalidating the auth tag.
const aad = Buffer.from(JSON.stringify({
  version: 1,
  recipient: 'user@example.com',
  timestamp: Date.now(),
}));

// Encrypt with AAD
const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
cipher.setAAD(aad);

const encrypted = Buffer.concat([
  cipher.update('Confidential payload', 'utf8'),
  cipher.final(),
]);
const tag = cipher.getAuthTag();

console.log('AAD (plaintext):', aad.toString());
console.log('Ciphertext:', encrypted.toString('hex'));
console.log('Auth tag:', tag.toString('hex'));

// Decrypt — must provide the same AAD
const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
decipher.setAuthTag(tag);
decipher.setAAD(aad); // Must match exactly

const decrypted = Buffer.concat([
  decipher.update(encrypted),
  decipher.final(),
]);
console.log('Decrypted:', decrypted.toString('utf8'));

// If AAD is modified, authentication fails
const badAAD = Buffer.from('tampered metadata');
const decipher2 = crypto.createDecipheriv('aes-256-gcm', key, iv);
decipher2.setAuthTag(tag);
decipher2.setAAD(badAAD);

try {
  decipher2.update(encrypted);
  decipher2.final();
} catch (err) {
  console.log('AAD tamper detected:', err.message);
}
```

---

## Common Pitfalls and How to Avoid Them

### Pitfall 1: Reusing IVs

Reusing an IV with the same key in GCM mode is catastrophic — it allows an attacker to recover the authentication key and forge messages:

```javascript
'use strict';

const crypto = require('node:crypto');

// WRONG — hardcoded IV
// const iv = Buffer.alloc(12, 0); // Same IV every time = BROKEN

// WRONG — counter that overflows or resets
// let counter = 0;
// const iv = Buffer.alloc(12);
// iv.writeUInt32BE(counter++, 8); // Resets on restart = BROKEN

// RIGHT — random IV for every encryption
const iv = crypto.randomBytes(12); // Unique every time
```

### Pitfall 2: Wrong Key Length

AES key length must exactly match the algorithm:

```javascript
'use strict';

const crypto = require('node:crypto');

// aes-256-gcm requires exactly 32 bytes
try {
  const shortKey = crypto.randomBytes(16); // Only 16 bytes!
  crypto.createCipheriv('aes-256-gcm', shortKey, crypto.randomBytes(12));
} catch (err) {
  console.log('Wrong key length:', err.message);
  // "Invalid key length"
}

// Correct key lengths:
// aes-128-*: 16 bytes
// aes-192-*: 24 bytes
// aes-256-*: 32 bytes
```

### Pitfall 3: Not Verifying the Auth Tag

```javascript
'use strict';

const crypto = require('node:crypto');

// WRONG — skipping setAuthTag
// const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
// decipher.update(ciphertext);  // Works but data is NOT authenticated
// decipher.final();             // Throws because tag was not set

// RIGHT — always set the auth tag before update/final
// decipher.setAuthTag(tag);
// decipher.update(ciphertext);
// decipher.final(); // Verifies tag during finalization
```

### Pitfall 4: Using `createCipher()` Instead of `createCipheriv()`

The old `crypto.createCipher()` (without "iv") is deprecated. It derives the key and IV from a password using a weak MD5-based method. Always use `createCipheriv()`:

```javascript
'use strict';

const crypto = require('node:crypto');

// DEPRECATED — do not use
// crypto.createCipher('aes-256-cbc', 'password');

// CORRECT — explicit key and IV
const key = crypto.randomBytes(32);
const iv = crypto.randomBytes(12);
const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
```

---

## Quick Reference: AES-256-GCM Encrypt/Decrypt

```javascript
'use strict';

const crypto = require('node:crypto');

// === Encrypt ===
function encrypt(plaintext, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const enc = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), enc]);
}

// === Decrypt ===
function decrypt(data, key) {
  const iv = data.subarray(0, 12);
  const tag = data.subarray(12, 28);
  const ct = data.subarray(28);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]).toString('utf8');
}

// === Usage ===
const key = crypto.randomBytes(32);
const encrypted = encrypt('Secret message', key);
const decrypted = decrypt(encrypted, key);
console.log(decrypted); // 'Secret message'
```

---

## Key Takeaways

- AES-256-GCM is the recommended symmetric encryption algorithm — it provides both confidentiality and integrity (AEAD) in a single operation, with built-in tamper detection via the authentication tag.
- Always generate a fresh random IV (`crypto.randomBytes(12)` for GCM, `crypto.randomBytes(16)` for CBC) for every encryption operation — reusing an IV with the same key in GCM mode is a catastrophic security failure.
- Store encrypted data as `iv + authTag + ciphertext` in a single buffer so decryption can parse out each component; for password-derived keys, prepend the salt as well.
- `Cipher` and `Decipher` are Transform streams — you can pipe files through them for streaming encryption without loading the entire file into memory.
- Never use ECB mode, never use the deprecated `createCipher()`, and always call `decipher.setAuthTag()` before `.update()` and `.final()` to ensure the authentication tag is verified.

## Next

Continue to [Lesson 04 — Asymmetric Encryption](lesson-04-asymmetric-encryption.md), where you will generate RSA key pairs, encrypt data with public keys, implement the hybrid encryption pattern, and manage key formats and storage.
