# Module 10 / Lesson 02 — Hashing

> A hash function takes input of any size and produces a fixed-size fingerprint. Change a single bit in the input and the output changes completely. You cannot reverse-engineer the input from the output. These two properties — the avalanche effect and one-wayness — make hashing the backbone of password storage, file integrity verification, digital signatures, and message authentication. Node.js gives you battle-tested hashing through `node:crypto`, from simple one-shot digests to streaming file checksums and keyed HMAC signatures.

## Learning Objectives

- Compute SHA-256, SHA-512, and SHA-3 digests using `crypto.createHash()` and the one-shot `crypto.hash()`
- Stream large files through a hash to compute checksums without loading the entire file into memory
- Create and verify HMAC signatures for API requests and webhook payloads
- Hash passwords safely using `crypto.scrypt()` and `crypto.pbkdf2()` with proper salting
- Explain why regular hash functions are unsuitable for passwords and when to choose scrypt over pbkdf2

---

## What Is a Hash Function?

A cryptographic hash function has four essential properties:

| Property | Meaning |
|----------|---------|
| **Deterministic** | Same input always produces the same output. |
| **Fixed output size** | SHA-256 always outputs 256 bits (32 bytes), regardless of input size. |
| **One-way (preimage resistant)** | Given a hash, it is computationally infeasible to find the original input. |
| **Avalanche effect** | A tiny change in input produces a drastically different hash. |

Two additional properties matter for security:

- **Second preimage resistance**: Given an input, you cannot find a different input with the same hash.
- **Collision resistance**: You cannot find any two different inputs that produce the same hash.

```javascript
'use strict';

const crypto = require('node:crypto');

// Avalanche effect demonstration
const hash1 = crypto.createHash('sha256').update('hello world').digest('hex');
const hash2 = crypto.createHash('sha256').update('hello worlD').digest('hex');

console.log('Input 1: "hello world"');
console.log('Hash  1:', hash1);
console.log('');
console.log('Input 2: "hello worlD" (one character changed)');
console.log('Hash  2:', hash2);
console.log('');
console.log('Same?', hash1 === hash2); // false — completely different hashes

// Fixed output size — regardless of input size
const tiny = crypto.createHash('sha256').update('a').digest('hex');
const large = crypto.createHash('sha256').update('a'.repeat(1000000)).digest('hex');
console.log('Hash of "a":', tiny, `(${tiny.length} hex chars)`);
console.log('Hash of 1M "a"s:', large, `(${large.length} hex chars)`);
// Both are exactly 64 hex characters (256 bits)
```

---

## Computing Hashes with `crypto.createHash()`

The `createHash()` function returns a `Hash` object, which is a Transform stream. You feed data in via `.update()` and extract the digest via `.digest()`.

```javascript
'use strict';

const crypto = require('node:crypto');

// Basic hashing flow: createHash → update → digest
const hash = crypto.createHash('sha256');
hash.update('Node.js');
hash.update(' crypto');   // You can call .update() multiple times
hash.update(' module');
const digest = hash.digest('hex'); // Finalize and get the result
console.log('SHA-256:', digest);

// Once you call .digest(), the Hash object is finalized.
// Calling .update() or .digest() again throws an error.
// You must create a new Hash for each computation.

// Equivalent one-liner
const oneShot = crypto.createHash('sha256').update('Node.js crypto module').digest('hex');
console.log('Same?', digest === oneShot); // true
```

### Digest Encodings

The `.digest()` method accepts an encoding parameter. If omitted, it returns a `Buffer`.

```javascript
'use strict';

const crypto = require('node:crypto');

const data = 'The quick brown fox jumps over the lazy dog';

// Different output encodings
const hexDigest = crypto.createHash('sha256').update(data).digest('hex');
const base64Digest = crypto.createHash('sha256').update(data).digest('base64');
const base64urlDigest = crypto.createHash('sha256').update(data).digest('base64url');
const bufferDigest = crypto.createHash('sha256').update(data).digest(); // Buffer

console.log('hex:       ', hexDigest);
console.log('base64:    ', base64Digest);
console.log('base64url: ', base64urlDigest);
console.log('buffer:    ', bufferDigest);
console.log('buffer len:', bufferDigest.length, 'bytes'); // 32 bytes = 256 bits
```

### Available Hash Algorithms

```javascript
'use strict';

const crypto = require('node:crypto');

// SHA-2 family (most common)
const sha256 = crypto.createHash('sha256').update('test').digest('hex');
const sha384 = crypto.createHash('sha384').update('test').digest('hex');
const sha512 = crypto.createHash('sha512').update('test').digest('hex');

console.log('SHA-256 (32 bytes):', sha256);
console.log('SHA-384 (48 bytes):', sha384);
console.log('SHA-512 (64 bytes):', sha512);

// SHA-3 family (newer, different internal structure)
const sha3_256 = crypto.createHash('sha3-256').update('test').digest('hex');
const sha3_512 = crypto.createHash('sha3-512').update('test').digest('hex');

console.log('SHA3-256 (32 bytes):', sha3_256);
console.log('SHA3-512 (64 bytes):', sha3_512);

// MD5 — BROKEN for security, still used for non-security checksums
const md5 = crypto.createHash('md5').update('test').digest('hex');
console.log('MD5 (16 bytes):', md5, '(DO NOT use for security)');

// BLAKE2 — fast and secure
const blake2b = crypto.createHash('blake2b512').update('test').digest('hex');
console.log('BLAKE2b (64 bytes):', blake2b);
```

| Algorithm | Output Size | Status | Typical Use |
|-----------|------------|--------|-------------|
| `md5` | 128 bits | **Broken** | Legacy checksums only |
| `sha1` | 160 bits | **Broken** | Git internals (legacy) |
| `sha256` | 256 bits | Secure | General purpose, file integrity, HMAC |
| `sha384` | 384 bits | Secure | TLS cipher suites |
| `sha512` | 512 bits | Secure | When you need more bits |
| `sha3-256` | 256 bits | Secure | SHA-2 alternative |
| `sha3-512` | 512 bits | Secure | SHA-2 alternative |
| `blake2b512` | 512 bits | Secure | High performance hashing |

---

## One-Shot Hashing with `crypto.hash()` (Node 21.7+)

Node.js 21.7 introduced a simpler one-shot API that avoids creating a `Hash` object:

```javascript
'use strict';

const crypto = require('node:crypto');

// crypto.hash(algorithm, data[, outputEncoding])
// Available in Node.js 21.7+ / Node.js 22+
if (typeof crypto.hash === 'function') {
  const digest = crypto.hash('sha256', 'Hello, World!', 'hex');
  console.log('One-shot SHA-256:', digest);

  // Accepts Buffer input too
  const bufDigest = crypto.hash('sha256', Buffer.from('Hello, World!'), 'hex');
  console.log('Same?', digest === bufDigest); // true

  // Returns Buffer when no encoding specified
  const rawDigest = crypto.hash('sha256', 'Hello, World!');
  console.log('Buffer:', rawDigest);
} else {
  console.log('crypto.hash() not available — use crypto.createHash() instead');
  const digest = crypto.createHash('sha256').update('Hello, World!').digest('hex');
  console.log('SHA-256:', digest);
}
```

---

## Streaming Hashes: File Checksum Verification

When you need to hash a large file, you do not want to read the entire file into memory. Since `Hash` is a Transform stream, you can pipe a file's ReadStream directly through it:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function computeFileChecksum(filePath, algorithm = 'sha256') {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash(algorithm);
    const stream = fs.createReadStream(filePath);

    stream.on('error', reject);
    hash.on('error', reject);

    stream.on('data', (chunk) => {
      hash.update(chunk);
    });

    stream.on('end', () => {
      const digest = hash.digest('hex');
      resolve(digest);
    });
  });
}

// Alternative: using pipe (Hash is a Transform stream)
function computeFileChecksumPipe(filePath, algorithm = 'sha256') {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash(algorithm);
    const stream = fs.createReadStream(filePath);

    stream.pipe(hash); // Pipe file data into the hash

    const chunks = [];
    hash.on('data', (chunk) => chunks.push(chunk));
    hash.on('end', () => {
      resolve(Buffer.concat(chunks).toString('hex'));
    });
    hash.on('error', reject);
    stream.on('error', reject);
  });
}

// Using the pipeline API (preferred for proper error handling)
const { pipeline } = require('node:stream/promises');

async function computeFileChecksumPipeline(filePath, algorithm = 'sha256') {
  const hash = crypto.createHash(algorithm);
  hash.setEncoding('hex');

  const input = fs.createReadStream(filePath);
  await pipeline(input, hash);

  return hash.read();
}

// Usage
const targetFile = process.argv[2] || __filename;
computeFileChecksum(targetFile).then((checksum) => {
  console.log(`SHA-256 of ${path.basename(targetFile)}:`);
  console.log(checksum);
});
```

### Verifying File Integrity

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

async function verifyFileIntegrity(filePath, expectedHash, algorithm = 'sha256') {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash(algorithm);
    const stream = fs.createReadStream(filePath);

    stream.on('error', reject);

    stream.on('data', (chunk) => hash.update(chunk));

    stream.on('end', () => {
      const actualHash = hash.digest('hex');
      const match = actualHash === expectedHash;
      resolve({
        match,
        actual: actualHash,
        expected: expectedHash,
      });
    });
  });
}

// Example: verify a downloaded file
// In production, the expected hash comes from a trusted source
// (e.g., a checksum file on the official website).
const knownHash = crypto.createHash('sha256').update('test content').digest('hex');
console.log('Expected hash:', knownHash);
```

---

## HMAC: Keyed Hashing for Message Authentication

A regular hash verifies that data has not been *accidentally* corrupted. An HMAC (Hash-based Message Authentication Code) verifies that data has not been *intentionally* tampered with — and that it came from someone who possesses the secret key.

```
HMAC(key, message) = Hash((key ⊕ opad) || Hash((key ⊕ ipad) || message))
```

The key is mixed into the hashing process in a way that prevents length-extension attacks (which afflict plain `Hash(key + message)`).

```javascript
'use strict';

const crypto = require('node:crypto');

// Create an HMAC
const secret = 'my-api-secret-key';
const message = 'amount=100&currency=USD&timestamp=1707000000';

const hmac = crypto.createHmac('sha256', secret);
hmac.update(message);
const signature = hmac.digest('hex');

console.log('Message:', message);
console.log('HMAC-SHA256:', signature);

// Verification: recompute HMAC with the same key and compare
const expectedHmac = crypto
  .createHmac('sha256', secret)
  .update(message)
  .digest('hex');

const isValid = crypto.timingSafeEqual(
  Buffer.from(signature, 'hex'),
  Buffer.from(expectedHmac, 'hex')
);
console.log('Valid:', isValid); // true
```

### HMAC Use Case: Webhook Verification

Many APIs (Stripe, GitHub, Slack) sign webhook payloads with HMAC so you can verify they are authentic:

```javascript
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

const WEBHOOK_SECRET = 'whsec_abcdef123456';

function verifyWebhook(rawBody, signatureHeader) {
  // Stripe-style: signature is in 'v1=<hex>' format
  const parts = signatureHeader.split(',');
  const sigPart = parts.find((p) => p.startsWith('v1='));
  if (!sigPart) return false;

  const receivedSig = sigPart.slice(3); // Remove 'v1='

  const expectedSig = crypto
    .createHmac('sha256', WEBHOOK_SECRET)
    .update(rawBody)
    .digest('hex');

  const expected = Buffer.from(expectedSig, 'hex');
  const received = Buffer.from(receivedSig, 'hex');

  if (expected.length !== received.length) return false;
  return crypto.timingSafeEqual(expected, received);
}

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/webhook') {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const rawBody = Buffer.concat(chunks).toString();
      const signature = req.headers['x-signature'] || '';

      if (verifyWebhook(rawBody, signature)) {
        console.log('Webhook verified:', rawBody);
        res.writeHead(200);
        res.end('OK');
      } else {
        console.log('Webhook verification FAILED');
        res.writeHead(401);
        res.end('Unauthorized');
      }
    });
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});

// Uncomment to start:
// server.listen(3000, () => console.log('Webhook server on :3000'));
```

---

## Password Hashing: Why Regular Hashes Fail

SHA-256 is fast — a modern GPU can compute billions of SHA-256 hashes per second. That speed, which is a virtue for file checksums, is a catastrophe for passwords:

```
Attack: brute-force all 8-character lowercase passwords
  26^8 = ~209 billion combinations
  At 10 billion SHA-256/sec (GPU) → ~21 seconds.
```

Password hashing functions are deliberately **slow** and **memory-intensive** to make brute-force attacks impractical.

### `crypto.scrypt()` — Memory-Hard Password Hashing

`scrypt` is designed to be both CPU-intensive and memory-intensive, making it resistant to GPU and ASIC attacks:

```javascript
'use strict';

const crypto = require('node:crypto');

// --- Password Registration Flow ---

function hashPassword(password) {
  return new Promise((resolve, reject) => {
    // Generate a unique salt for every password
    const salt = crypto.randomBytes(16);

    // scrypt(password, salt, keylen, [options], callback)
    // keylen = 64 bytes (512 bits) — the derived key length
    const options = {
      N: 16384,  // CPU/memory cost parameter (must be power of 2)
      r: 8,      // Block size parameter
      p: 1,      // Parallelization parameter
      maxmem: 32 * 1024 * 1024, // Max memory (32 MB)
    };

    crypto.scrypt(password, salt, 64, options, (err, derivedKey) => {
      if (err) return reject(err);

      // Store: algorithm$N$r$p$salt$hash
      const stored = [
        'scrypt',
        options.N,
        options.r,
        options.p,
        salt.toString('hex'),
        derivedKey.toString('hex'),
      ].join('$');

      resolve(stored);
    });
  });
}

// --- Password Verification Flow ---

function verifyPassword(password, stored) {
  return new Promise((resolve, reject) => {
    const parts = stored.split('$');
    if (parts[0] !== 'scrypt' || parts.length !== 6) {
      return resolve(false);
    }

    const N = parseInt(parts[1], 10);
    const r = parseInt(parts[2], 10);
    const p = parseInt(parts[3], 10);
    const salt = Buffer.from(parts[4], 'hex');
    const storedHash = Buffer.from(parts[5], 'hex');

    crypto.scrypt(password, salt, storedHash.length, { N, r, p }, (err, derivedKey) => {
      if (err) return reject(err);

      // Constant-time comparison
      resolve(crypto.timingSafeEqual(derivedKey, storedHash));
    });
  });
}

// Demo
(async () => {
  const stored = await hashPassword('my-secure-password');
  console.log('Stored:', stored);

  const valid = await verifyPassword('my-secure-password', stored);
  console.log('Correct password?', valid); // true

  const invalid = await verifyPassword('wrong-password', stored);
  console.log('Wrong password?', invalid); // false
})();
```

### `crypto.pbkdf2()` — Standards-Based Alternative

PBKDF2 (Password-Based Key Derivation Function 2) is older and more widely standardized (NIST SP 800-132). It uses repeated HMAC iterations to slow down brute-force:

```javascript
'use strict';

const crypto = require('node:crypto');

function hashPasswordPbkdf2(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16);
    const iterations = 600000; // OWASP 2023 recommendation for SHA-256
    const keylen = 64;
    const digest = 'sha256';

    crypto.pbkdf2(password, salt, iterations, keylen, digest, (err, derivedKey) => {
      if (err) return reject(err);
      // Store: algorithm$digest$iterations$salt$hash
      const stored = `pbkdf2$${digest}$${iterations}$${salt.toString('hex')}$${derivedKey.toString('hex')}`;
      resolve(stored);
    });
  });
}

// Verification follows the same pattern as scrypt: parse the stored string,
// re-derive with the same parameters, and compare with timingSafeEqual().

(async () => {
  console.time('pbkdf2-hash');
  const stored = await hashPasswordPbkdf2('hunter2');
  console.timeEnd('pbkdf2-hash');
  console.log('Stored:', stored);
})();
```

### Choosing scrypt vs pbkdf2

| Factor | scrypt | pbkdf2 |
|--------|--------|--------|
| **Memory hardness** | Yes — requires large RAM | No — CPU only |
| **GPU resistance** | Strong (memory bottleneck) | Weak (GPU can run many iterations in parallel) |
| **Standardization** | RFC 7914 | NIST SP 800-132 |
| **Tuning** | N (cost), r (block size), p (parallelism) | Iterations count |
| **Compliance** | Less common in FIPS | FIPS-approved |
| **Recommendation** | Preferred for most applications | Required for FIPS compliance |

**Rule of thumb:** Use `scrypt` unless you need FIPS compliance, in which case use `pbkdf2` with at least 600,000 iterations (OWASP 2023). Both have synchronous variants (`scryptSync`, `pbkdf2Sync`) that block the event loop — use them only in scripts, CLIs, or startup code, never in request handlers.

---

## Complete Example: File Checksum Utility

A practical utility that computes and compares checksums for any file:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const ALGORITHMS = ['md5', 'sha1', 'sha256', 'sha512'];

async function computeChecksums(filePath) {
  const hashes = {};
  for (const algo of ALGORITHMS) {
    hashes[algo] = crypto.createHash(algo);
  }

  return new Promise((resolve, reject) => {
    const stream = fs.createReadStream(filePath, { highWaterMark: 64 * 1024 });
    let bytesRead = 0;

    stream.on('data', (chunk) => {
      bytesRead += chunk.length;
      for (const algo of ALGORITHMS) {
        hashes[algo].update(chunk);
      }
    });

    stream.on('end', () => {
      const result = { file: filePath, size: bytesRead };
      for (const algo of ALGORITHMS) {
        result[algo] = hashes[algo].digest('hex');
      }
      resolve(result);
    });

    stream.on('error', reject);
  });
}

// Usage
const targetFile = process.argv[2] || __filename;
computeChecksums(targetFile).then((result) => {
  console.log(`Checksums for: ${path.basename(result.file)}`);
  console.log(`Size: ${result.size} bytes`);
  console.log('');
  for (const algo of ALGORITHMS) {
    const label = algo.toUpperCase().padEnd(8);
    console.log(`${label} ${result[algo]}`);
  }
});
```

---

## HMAC in a Request-Signing Flow

Here is a practical pattern where a client signs API requests so the server can verify authenticity:

```javascript
'use strict';

const crypto = require('node:crypto');

// --- Client side ---

function signRequest(method, path, body, apiKey, apiSecret) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const payload = [method.toUpperCase(), path, timestamp, body].join('\n');

  const signature = crypto
    .createHmac('sha256', apiSecret)
    .update(payload)
    .digest('hex');

  return {
    'X-API-Key': apiKey,
    'X-Timestamp': timestamp,
    'X-Signature': signature,
  };
}

// --- Server side ---

function verifyRequest(method, path, body, headers, lookupSecret) {
  const apiKey = headers['X-API-Key'];
  const timestamp = headers['X-Timestamp'];
  const receivedSig = headers['X-Signature'];

  if (!apiKey || !timestamp || !receivedSig) {
    return { valid: false, reason: 'missing headers' };
  }

  // Reject requests older than 5 minutes (replay protection)
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp, 10)) > 300) {
    return { valid: false, reason: 'request expired' };
  }

  // Look up the secret for this API key
  const secret = lookupSecret(apiKey);
  if (!secret) {
    return { valid: false, reason: 'unknown API key' };
  }

  const payload = [method.toUpperCase(), path, timestamp, body].join('\n');
  const expectedSig = crypto
    .createHmac('sha256', secret)
    .update(payload)
    .digest('hex');

  const expected = Buffer.from(expectedSig, 'hex');
  const received = Buffer.from(receivedSig, 'hex');

  if (expected.length !== received.length) {
    return { valid: false, reason: 'invalid signature' };
  }

  if (!crypto.timingSafeEqual(expected, received)) {
    return { valid: false, reason: 'signature mismatch' };
  }

  return { valid: true, apiKey };
}

// Demo
const API_KEY = 'app_123';
const API_SECRET = crypto.randomBytes(32).toString('hex');

const headers = signRequest('POST', '/api/orders', '{"item":"widget"}', API_KEY, API_SECRET);
console.log('Request headers:', headers);

const result = verifyRequest(
  'POST',
  '/api/orders',
  '{"item":"widget"}',
  headers,
  (key) => (key === API_KEY ? API_SECRET : null)
);
console.log('Verification:', result);
```

---

## Key Takeaways

- `crypto.createHash(algorithm)` produces a `Hash` transform stream — call `.update()` one or more times, then `.digest(encoding)` to finalize; use SHA-256 or stronger for anything security-related.
- Streaming hashes let you checksum multi-gigabyte files without loading them into memory — pipe a `ReadStream` through a `Hash` or use the `pipeline()` API.
- HMAC (`crypto.createHmac()`) adds a secret key to the hashing process, providing both integrity and authentication — use it for API signing, webhook verification, and anywhere you need to prove a message was not tampered with.
- Never store passwords with a regular hash — use `crypto.scrypt()` (memory-hard, GPU-resistant) or `crypto.pbkdf2()` (FIPS-approved, iteration-based) with a unique random salt per password.
- Always compare HMAC digests and password hashes with `crypto.timingSafeEqual()` to prevent timing attacks that leak information byte by byte.

## Next

Continue to [Lesson 03 — Symmetric Encryption](lesson-03-symmetric-encryption.md), where you will encrypt and decrypt data with AES-256-GCM, handle IVs and authentication tags, and stream encrypted data through Transform streams.
