# Module 10 / Lesson 01 — Cryptography Fundamentals

> Every application handles sensitive data — passwords, tokens, personal information, financial records. Cryptography is not an optional add-on bolted on at the end; it is a foundational requirement that touches authentication, data storage, network communication, and integrity verification. Node.js ships with a powerful `node:crypto` module built on top of OpenSSL, giving you production-grade cryptographic primitives without a single npm install.

## Learning Objectives

- Explain why cryptography matters for every Node.js application, not just "security" projects
- Navigate the `node:crypto` module and understand the categories of primitives it provides
- Distinguish between symmetric and asymmetric encryption at a conceptual level
- Generate cryptographically secure random values using `randomBytes()`, `randomUUID()`, and `randomInt()`
- Identify common cryptographic mistakes and deprecated algorithms that must never be used in production

---

## Why Every Node.js Developer Needs Crypto

Cryptography is not just for banks and government agencies. If your application does any of the following, you are already in crypto territory:

| Use Case | Crypto Primitive |
|----------|-----------------|
| Storing passwords | Hashing + salting (scrypt, pbkdf2) |
| API authentication tokens | HMAC signing, JWT verification |
| HTTPS / TLS connections | Asymmetric key exchange, symmetric bulk encryption |
| File integrity checks | SHA-256 checksums |
| Session IDs, CSRF tokens | Cryptographically secure random generation |
| Encrypting data at rest | AES-256-GCM symmetric encryption |
| Digital signatures | RSA or ECDSA signing/verification |
| Webhook verification | HMAC comparison with timing-safe equality |

If you have ever used `Math.random()` to generate a session token, stored a password in plain SHA-256, or skipped HTTPS because "it's just an internal service," this module will show you why those shortcuts are dangerous and what to do instead.

---

## The `node:crypto` Module Overview

The `node:crypto` module is one of the largest built-in modules in Node.js. It wraps OpenSSL (or BoringSSL in some builds) and exposes a broad surface area of cryptographic operations:

```javascript
'use strict';

const crypto = require('node:crypto');

// The module is available immediately — no installation needed.
// Let's see what version of OpenSSL is backing our crypto operations.
console.log('OpenSSL version:', process.versions.openssl);
// Example output: '3.0.13+quic'

// Node.js version determines which crypto APIs are available.
console.log('Node.js version:', process.version);
```

The module provides primitives in several categories:

| Category | Key APIs |
|----------|----------|
| **Hashing** | `createHash()`, `hash()`, `createHmac()` |
| **Symmetric Encryption** | `createCipheriv()`, `createDecipheriv()` |
| **Asymmetric Encryption** | `publicEncrypt()`, `privateDecrypt()`, `generateKeyPair()` |
| **Signing & Verification** | `createSign()`, `createVerify()` |
| **Key Derivation** | `scrypt()`, `pbkdf2()`, `hkdf()` |
| **Key Exchange** | `createDiffieHellman()`, `createECDH()`, `diffieHellman()` |
| **Random Generation** | `randomBytes()`, `randomUUID()`, `randomInt()`, `randomFillSync()` |
| **Certificates** | `X509Certificate`, `createCertificate()` |
| **Utilities** | `timingSafeEqual()`, `getHashes()`, `getCiphers()`, `getCurves()` |

You do not need to memorize every function. Think of `node:crypto` as a toolbox — you reach for the right tool when the problem demands it.

---

## Symmetric vs Asymmetric Encryption

Before diving into specific APIs, you need to understand the two fundamental approaches to encryption.

### Symmetric Encryption

One key does both jobs — encryption and decryption. If Alice encrypts a message with key `K`, Bob must have the exact same key `K` to decrypt it.

```
Plaintext ──[ Key K ]──▶ Ciphertext ──[ Key K ]──▶ Plaintext
              Encrypt                    Decrypt
```

- **Fast**: Hardware-accelerated AES can process gigabytes per second.
- **Problem**: How do Alice and Bob agree on key `K` without an eavesdropper intercepting it? This is the *key distribution problem*.
- **Examples**: AES-128, AES-256, ChaCha20.

### Asymmetric Encryption

Two mathematically related keys — a **public key** and a **private key**. Data encrypted with the public key can only be decrypted with the private key, and vice versa.

```
Plaintext ──[ Public Key ]──▶ Ciphertext ──[ Private Key ]──▶ Plaintext
              Encrypt                         Decrypt
```

- **Solves key distribution**: You can publish your public key openly. Anyone can encrypt a message to you, but only you can decrypt it.
- **Slow**: Orders of magnitude slower than symmetric encryption.
- **Examples**: RSA, ECDSA, Ed25519.

### The Hybrid Approach (How TLS Works)

In practice, almost all systems use both:

1. Use asymmetric crypto to exchange a random symmetric key.
2. Use symmetric crypto (AES) for the actual data.

This gives you the best of both worlds — secure key exchange plus fast bulk encryption.

```
┌─────────────────────────────────────────────────────┐
│  TLS Handshake (asymmetric)                         │
│  ─ Exchange ephemeral keys via ECDHE                │
│  ─ Derive shared AES session key                    │
├─────────────────────────────────────────────────────┤
│  Data Transfer (symmetric)                          │
│  ─ Encrypt all application data with AES-256-GCM    │
│  ─ Fast, hardware-accelerated                       │
└─────────────────────────────────────────────────────┘
```

---

## Key Concepts and Vocabulary

Before you write any crypto code, you need to speak the language. These terms appear everywhere in the `node:crypto` documentation:

| Term | Definition |
|------|-----------|
| **Plaintext** | The original, unencrypted data (not necessarily text — could be binary). |
| **Ciphertext** | The encrypted output — looks like random bytes. |
| **Key** | A secret value used by an algorithm to encrypt or decrypt. |
| **IV (Initialization Vector)** | A random value used alongside the key to ensure identical plaintexts produce different ciphertexts. |
| **Nonce** | "Number used once" — similar to IV but emphasizes it must never be reused with the same key. |
| **Salt** | Random data added to a password before hashing, ensuring identical passwords produce different hashes. |
| **Digest** | The output of a hash function (e.g., a SHA-256 digest is 32 bytes). |
| **AEAD** | Authenticated Encryption with Associated Data — provides both confidentiality and integrity (e.g., AES-GCM). |
| **CSPRNG** | Cryptographically Secure Pseudo-Random Number Generator — produces unpredictable output suitable for security use. |
| **KDF** | Key Derivation Function — stretches a password or shared secret into a suitable encryption key. |

---

## Randomness: The Foundation of All Crypto

Every cryptographic operation depends on randomness. Keys, IVs, salts, nonces, tokens — they all need to be unpredictable. Node.js provides three CSPRNG functions that pull entropy from the operating system.

### `crypto.randomBytes(size)`

Generates a `Buffer` of cryptographically secure random bytes. This is your workhorse for generating keys, IVs, and salts.

```javascript
'use strict';

const crypto = require('node:crypto');

// Synchronous — blocks until bytes are available
const key = crypto.randomBytes(32); // 256-bit key for AES-256
console.log('Random key (hex):', key.toString('hex'));
console.log('Key length:', key.length, 'bytes');

const iv = crypto.randomBytes(16); // 128-bit IV for AES-CBC
console.log('Random IV (hex):', iv.toString('hex'));

const salt = crypto.randomBytes(16); // Salt for password hashing
console.log('Random salt (hex):', salt.toString('hex'));

// Asynchronous — non-blocking, preferred in servers
crypto.randomBytes(32, (err, buf) => {
  if (err) {
    console.error('Failed to generate random bytes:', err);
    return;
  }
  console.log('Async random bytes:', buf.toString('hex'));
});
```

### `crypto.randomUUID()`

Generates a RFC 4122 version 4 UUID — 122 bits of randomness formatted as `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.

```javascript
'use strict';

const crypto = require('node:crypto');

// Perfect for request IDs, correlation IDs, database primary keys
const requestId = crypto.randomUUID();
console.log('Request ID:', requestId);
// Example: '1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed'

// Generate 5 UUIDs — each is unique
for (let i = 0; i < 5; i++) {
  console.log(`UUID ${i + 1}: ${crypto.randomUUID()}`);
}
```

### `crypto.randomInt([min,] max)`

Generates a cryptographically secure random integer in the range `[min, max)`. Useful for OTP codes, verification codes, and random selection.

```javascript
'use strict';

const crypto = require('node:crypto');

// Random integer between 0 (inclusive) and 1000000 (exclusive)
const otp = crypto.randomInt(100000, 1000000); // 6-digit OTP
console.log('OTP code:', otp);

// Random integer between 0 and 255
const byteValue = crypto.randomInt(256);
console.log('Random byte value:', byteValue);

// Async version with callback
crypto.randomInt(1, 7, (err, value) => {
  if (err) throw err;
  console.log('Dice roll:', value); // 1-6
});
```

### Why Not `Math.random()`?

`Math.random()` uses a PRNG (Pseudo-Random Number Generator) that is **not** cryptographically secure. Its output is predictable if you know the internal state. V8's `Math.random()` uses xorshift128+ — fast, but not suitable for security:

```javascript
'use strict';

const crypto = require('node:crypto');

// NEVER do this for security-sensitive values:
const insecureToken = Math.random().toString(36).slice(2);
console.log('INSECURE token:', insecureToken);
// An attacker who observes a few outputs can predict future values.

// ALWAYS do this instead:
const secureToken = crypto.randomBytes(24).toString('base64url');
console.log('SECURE token:', secureToken);
// 192 bits of entropy — computationally infeasible to predict.
```

---

## Listing Available Algorithms

Node.js exposes the algorithms available in the underlying OpenSSL build. These lists vary by platform and Node.js version.

```javascript
'use strict';

const crypto = require('node:crypto');

// All available hash algorithms
const hashes = crypto.getHashes();
console.log('Available hashes:', hashes.length);
console.log('Sample hashes:', hashes.slice(0, 10));
// ['RSA-MD5', 'RSA-RIPEMD160', 'RSA-SHA1', 'RSA-SHA1-2', ...]

// Check if a specific hash is available
console.log('SHA-256 available:', hashes.includes('sha256'));       // true
console.log('SHA3-256 available:', hashes.includes('sha3-256'));    // true
console.log('BLAKE2b512 available:', hashes.includes('blake2b512')); // true

// All available cipher algorithms
const ciphers = crypto.getCiphers();
console.log('\nAvailable ciphers:', ciphers.length);
console.log('Sample ciphers:', ciphers.slice(0, 10));
// ['aes-128-cbc', 'aes-128-ccm', 'aes-128-cfb', ...]

// Check for AES-256-GCM (the recommended symmetric cipher)
console.log('AES-256-GCM available:', ciphers.includes('aes-256-gcm'));

// All available elliptic curves
const curves = crypto.getCurves();
console.log('\nAvailable curves:', curves.length);
console.log('Sample curves:', curves.slice(0, 10));
// ['Oakley-EC2N-3', 'Oakley-EC2N-4', 'SM2', 'brainpoolP160r1', ...]

// The curves you'll actually use:
console.log('P-256 available:', curves.includes('prime256v1'));  // true
console.log('P-384 available:', curves.includes('secp384r1'));   // true
console.log('X25519 available:', curves.includes('X25519'));     // true (Node 12+)
```

---

## Timing-Safe Comparison

When comparing secrets (API keys, HMAC digests, tokens), you must use constant-time comparison. A naive `===` comparison leaks timing information — an attacker can determine how many bytes matched by measuring response time.

```javascript
'use strict';

const crypto = require('node:crypto');

// Simulating webhook signature verification
const SECRET = 'webhook-signing-secret';

function verifyWebhookSignature(payload, receivedSignature) {
  // Compute the expected signature
  const expectedSignature = crypto
    .createHmac('sha256', SECRET)
    .update(payload)
    .digest('hex');

  // Convert both to Buffers of equal length
  const expected = Buffer.from(expectedSignature, 'hex');
  const received = Buffer.from(receivedSignature, 'hex');

  // CRITICAL: Both buffers must be the same length
  if (expected.length !== received.length) {
    return false;
  }

  // Constant-time comparison — takes the same time
  // regardless of how many bytes match.
  return crypto.timingSafeEqual(expected, received);
}

// Test it
const payload = '{"event":"payment.completed","amount":100}';
const validSig = crypto
  .createHmac('sha256', SECRET)
  .update(payload)
  .digest('hex');

console.log('Valid signature?', verifyWebhookSignature(payload, validSig));     // true
console.log('Invalid signature?', verifyWebhookSignature(payload, 'abcdef'));   // false
```

### Why Timing Attacks Matter

```
Naive comparison: "abcdef" === "abcxyz"
  Compare 'a' === 'a' → match, continue     (1 unit of time)
  Compare 'b' === 'b' → match, continue     (2 units)
  Compare 'c' === 'c' → match, continue     (3 units)
  Compare 'd' === 'x' → mismatch, return    (4 units — LEAKED that 3 bytes matched)

Timing-safe comparison:
  Always compares ALL bytes regardless of mismatches.
  Takes constant time no matter where the mismatch occurs.
```

An attacker can brute-force one byte at a time — try all 256 values for byte 1, pick the one with the longest response, then move to byte 2. With `timingSafeEqual()`, every comparison takes the same time, so there is nothing to measure.

---

## OpenSSL: The Engine Under the Hood

Node.js does not implement cryptographic algorithms in JavaScript. Instead, `node:crypto` is a binding to OpenSSL (or BoringSSL / LibreSSL depending on the build). This means:

- Algorithm availability depends on the OpenSSL version compiled into your Node.js binary.
- Performance benefits from OpenSSL's assembly-optimized implementations and hardware acceleration (AES-NI).
- Security patches to OpenSSL require updating your Node.js version.

```javascript
'use strict';

const crypto = require('node:crypto');

// What OpenSSL version is backing this Node.js build?
console.log('OpenSSL:', process.versions.openssl);

// All version info
console.log('All versions:', JSON.stringify(process.versions, null, 2));

// Check FIPS mode (Federal Information Processing Standards)
// FIPS restricts which algorithms can be used (no MD5, no RC4, etc.)
console.log('FIPS mode enabled:', crypto.getFips());
// 0 = disabled, 1 = enabled
```

### FIPS Mode

FIPS 140-2 (and its successor 140-3) is a U.S. government standard for cryptographic modules. In FIPS mode, only approved algorithms are allowed — MD5, DES, and RC4 are forbidden. Many enterprise and government deployments require FIPS compliance.

```javascript
'use strict';

const crypto = require('node:crypto');

// Attempting to check FIPS status
const fipsEnabled = crypto.getFips();
console.log('FIPS mode:', fipsEnabled ? 'ENABLED' : 'DISABLED');

// To enable FIPS mode, Node.js must be built with a FIPS-capable OpenSSL.
// You cannot enable it at runtime on a standard Node.js build.
// The --enable-fips and --force-fips flags control this at startup.

// In FIPS mode, these would throw:
// crypto.createHash('md5')     → Error: disabled for FIPS
// crypto.createCipher('des')   → Error: disabled for FIPS
```

---

## Common Cryptographic Mistakes

Crypto is one of those domains where "it works" does not mean "it is secure." Here are the mistakes that fill CVE databases:

### 1. Using `Math.random()` for Security

```javascript
'use strict';

const crypto = require('node:crypto');

// WRONG — predictable, not suitable for tokens/keys/IVs
const badToken = Math.random().toString(36).substring(2);

// RIGHT — cryptographically secure
const goodToken = crypto.randomBytes(32).toString('base64url');
```

### 2. Using Deprecated Algorithms

```javascript
'use strict';

const crypto = require('node:crypto');

// MD5 — broken for security since 2004 (collision attacks)
// Only acceptable for non-security checksums (e.g., cache keys).
const md5 = crypto.createHash('md5').update('hello').digest('hex');
console.log('MD5 (DO NOT use for security):', md5);

// SHA-1 — broken since 2017 (Google's SHAttered attack)
const sha1 = crypto.createHash('sha1').update('hello').digest('hex');
console.log('SHA-1 (DO NOT use for security):', sha1);

// CORRECT — use SHA-256 or stronger
const sha256 = crypto.createHash('sha256').update('hello').digest('hex');
console.log('SHA-256 (recommended):', sha256);
```

| Algorithm | Status | Use For |
|-----------|--------|---------|
| MD5 | **Broken** | Cache keys only, never security |
| SHA-1 | **Broken** | Git (legacy), never new security use |
| DES | **Broken** | Nothing — too short key (56 bits) |
| RC4 | **Broken** | Nothing — stream cipher with known biases |
| SHA-256 | Secure | General hashing, checksums, HMAC |
| SHA-512 | Secure | When you need more bits |
| SHA-3 | Secure | Alternative to SHA-2 family |
| AES-128/256 | Secure | Symmetric encryption |
| ChaCha20 | Secure | Symmetric encryption (alternative to AES) |

### 3. Rolling Your Own Crypto

Never invent your own encryption scheme, hash function, or key exchange protocol. Even experienced cryptographers get it wrong. Use established, audited implementations from `node:crypto`.

### 4. Storing Passwords with a Simple Hash

```javascript
'use strict';

const crypto = require('node:crypto');

// WRONG — fast hash with no salt. Rainbow table attack trivial.
const password = 'hunter2';
const badHash = crypto.createHash('sha256').update(password).digest('hex');
console.log('Bad password hash:', badHash);

// RIGHT — use scrypt with a unique salt per password
const salt = crypto.randomBytes(16);
crypto.scrypt(password, salt, 64, (err, derivedKey) => {
  if (err) throw err;
  // Store salt + derivedKey together
  const stored = salt.toString('hex') + ':' + derivedKey.toString('hex');
  console.log('Good password hash:', stored);
});
```

### 5. Reusing IVs or Nonces

An IV (initialization vector) or nonce must be unique for every encryption operation with the same key. Reusing a nonce with AES-GCM completely destroys the security of the cipher — an attacker can recover the authentication key.

---

## Security Mindset: Principles That Guide Every Decision

### Defense in Depth

Never rely on a single security mechanism. Layer your defenses:

```
┌──────────────────────────────────────────┐
│  Layer 1: Network (TLS, firewall)        │
│  ┌────────────────────────────────────┐  │
│  │  Layer 2: Authentication (tokens)  │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │  Layer 3: Authorization      │  │  │
│  │  │  ┌────────────────────────┐  │  │  │
│  │  │  │  Layer 4: Encryption   │  │  │  │
│  │  │  │  (data at rest)        │  │  │  │
│  │  │  └────────────────────────┘  │  │  │
│  │  └──────────────────────────────┘  │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

### Principle of Least Privilege

Crypto keys should have the minimum scope and lifetime necessary. A database encryption key should not double as an API signing key. Rotate keys regularly.

### Fail Securely

When a cryptographic operation fails — decryption error, signature mismatch, expired token — the application should deny access, not fall back to an insecure path.

```javascript
'use strict';

const crypto = require('node:crypto');

function verifyToken(token, secret) {
  try {
    const [payloadHex, signatureHex] = token.split('.');

    if (!payloadHex || !signatureHex) {
      // Fail securely: reject malformed tokens
      return { valid: false, reason: 'malformed token' };
    }

    const expectedSig = crypto
      .createHmac('sha256', secret)
      .update(payloadHex)
      .digest('hex');

    const expected = Buffer.from(expectedSig, 'hex');
    const received = Buffer.from(signatureHex, 'hex');

    if (expected.length !== received.length) {
      return { valid: false, reason: 'signature length mismatch' };
    }

    if (!crypto.timingSafeEqual(expected, received)) {
      return { valid: false, reason: 'invalid signature' };
    }

    const payload = JSON.parse(Buffer.from(payloadHex, 'hex').toString());
    return { valid: true, payload };
  } catch (err) {
    // Fail securely: any exception means rejection
    return { valid: false, reason: 'verification error' };
  }
}

// Create a test token
const secret = 'my-server-secret';
const payload = Buffer.from(JSON.stringify({ userId: 42, exp: Date.now() + 3600000 })).toString('hex');
const signature = crypto.createHmac('sha256', secret).update(payload).digest('hex');
const token = `${payload}.${signature}`;

console.log('Token:', token);
console.log('Verification:', verifyToken(token, secret));
console.log('Tampered:', verifyToken(token + 'x', secret));
```

---

## Putting It All Together: A Crypto Capabilities Audit

Here is a utility that reports on the cryptographic capabilities of the current Node.js runtime:

```javascript
'use strict';

const crypto = require('node:crypto');

function auditCryptoCapabilities() {
  const report = {
    nodeVersion: process.version,
    opensslVersion: process.versions.openssl,
    fipsMode: crypto.getFips() === 1,
    hashAlgorithms: crypto.getHashes().length,
    cipherAlgorithms: crypto.getCiphers().length,
    curves: crypto.getCurves().length,
    recommended: {
      hashAvailable: crypto.getHashes().includes('sha256'),
      gcmAvailable: crypto.getCiphers().includes('aes-256-gcm'),
      chacha20Available: crypto.getCiphers().includes('chacha20-poly1305'),
      p256Available: crypto.getCurves().includes('prime256v1'),
      x25519Available: crypto.getCurves().includes('X25519'),
    },
    deprecated: {
      md5Available: crypto.getHashes().includes('md5'),
      sha1Available: crypto.getHashes().includes('sha1'),
      desAvailable: crypto.getCiphers().includes('des'),
      rc4Available: crypto.getCiphers().includes('rc4'),
    },
  };

  console.log('=== Crypto Capabilities Audit ===');
  console.log(`Node.js: ${report.nodeVersion}`);
  console.log(`OpenSSL: ${report.opensslVersion}`);
  console.log(`FIPS mode: ${report.fipsMode ? 'ENABLED' : 'disabled'}`);
  console.log(`Hash algorithms: ${report.hashAlgorithms}`);
  console.log(`Cipher algorithms: ${report.cipherAlgorithms}`);
  console.log(`Elliptic curves: ${report.curves}`);
  console.log('');
  console.log('Recommended algorithms:');
  for (const [name, available] of Object.entries(report.recommended)) {
    console.log(`  ${name}: ${available ? 'YES' : 'NO'}`);
  }
  console.log('');
  console.log('Deprecated algorithms (should avoid):');
  for (const [name, available] of Object.entries(report.deprecated)) {
    console.log(`  ${name}: ${available ? 'present (avoid)' : 'not present (good)'}`);
  }

  return report;
}

auditCryptoCapabilities();
```

---

## Quick Reference: Which Primitive for Which Job

```
Need to...                          Use...
──────────────────────────────────  ─────────────────────────
Generate a session token            crypto.randomBytes(32)
Generate a database ID              crypto.randomUUID()
Generate a 6-digit OTP              crypto.randomInt(100000, 1000000)
Hash a file for integrity            crypto.createHash('sha256')
Hash a password for storage          crypto.scrypt() with random salt
Sign an API request                  crypto.createHmac('sha256', key)
Encrypt data at rest                 AES-256-GCM via createCipheriv()
Encrypt data in transit              TLS (handled by node:tls / HTTPS)
Sign a document                      RSA/ECDSA via crypto.createSign()
Exchange keys over insecure channel  ECDH / X25519
Compare secrets safely               crypto.timingSafeEqual()
```

---

## Key Takeaways

- The `node:crypto` module provides production-grade cryptographic primitives backed by OpenSSL — never roll your own crypto or reach for `Math.random()` for security-sensitive values.
- Symmetric encryption (one key, fast) and asymmetric encryption (two keys, slow) serve different purposes and are typically combined in a hybrid approach.
- `crypto.randomBytes()`, `crypto.randomUUID()`, and `crypto.randomInt()` are your three CSPRNG functions — use them for all keys, IVs, salts, tokens, and nonces.
- Always use `crypto.timingSafeEqual()` when comparing secrets to prevent timing attacks that leak information byte by byte.
- Avoid deprecated algorithms (MD5, SHA-1 for security, DES, RC4), never reuse IVs/nonces, and always fail securely when crypto operations encounter errors.

## Next

Continue to [Lesson 02 — Hashing](lesson-02-hashing.md), where you will compute digests with SHA-256 and SHA-3, build streaming file checksums, sign messages with HMAC, and hash passwords safely with scrypt.
