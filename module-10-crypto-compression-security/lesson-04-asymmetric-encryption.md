# Module 10 / Lesson 04 — Asymmetric Encryption (RSA)

> Symmetric encryption has one fundamental problem: both parties need the same key, and sharing that key securely is itself a security challenge. Asymmetric encryption solves this with a key pair — a public key that anyone can have and a private key that only you possess. RSA is the most widely deployed asymmetric algorithm in the world, underpinning TLS certificates, SSH authentication, package signing, and encrypted email. Node.js provides comprehensive RSA support through `node:crypto`, from key generation to encryption, decryption, and the hybrid pattern that powers modern secure communication.

## Learning Objectives

- Generate RSA key pairs with `crypto.generateKeyPairSync()` and `crypto.generateKeyPair()` in PEM, DER, and JWK formats
- Encrypt data with a public key and decrypt it with the corresponding private key using OAEP padding
- Explain RSA's size limitation and implement the hybrid encryption pattern (RSA + AES) used by TLS
- Load, parse, and manage keys using the `KeyObject` API (`createPublicKey()`, `createPrivateKey()`)
- Choose appropriate RSA key sizes and key encoding formats for different deployment scenarios

---

## How Asymmetric Encryption Works

Asymmetric encryption uses two mathematically linked keys:

- **Public key**: Shared openly. Used to encrypt data or verify signatures.
- **Private key**: Kept secret. Used to decrypt data or create signatures.

```
┌─────────────────────────────────────────────────┐
│  Encryption flow:                               │
│  Plaintext ──[ Public Key ]──▶ Ciphertext       │
│  Ciphertext ──[ Private Key ]──▶ Plaintext      │
│                                                 │
│  Signing flow (reversed):                       │
│  Message ──[ Private Key ]──▶ Signature         │
│  Signature ──[ Public Key ]──▶ Verified / Not   │
└─────────────────────────────────────────────────┘
```

RSA's security rests on the mathematical difficulty of factoring the product of two large prime numbers. Given `n = p * q` where `p` and `q` are each 1024+ bits, no known algorithm can factor `n` in reasonable time.

---

## Generating RSA Key Pairs

### Synchronous Generation

```javascript
'use strict';

const crypto = require('node:crypto');

// Generate a 2048-bit RSA key pair
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048, // Key size in bits

  publicKeyEncoding: {
    type: 'spki',       // SubjectPublicKeyInfo — standard format
    format: 'pem',      // PEM: Base64-encoded, human-readable
  },

  privateKeyEncoding: {
    type: 'pkcs8',      // PKCS#8 — standard private key format
    format: 'pem',
  },
});

console.log('Public Key:');
console.log(publicKey.substring(0, 100) + '...');
// -----BEGIN PUBLIC KEY-----
// MIIBIjANBgkqhkiG9w...

console.log('\nPrivate Key:');
console.log(privateKey.substring(0, 100) + '...');
// -----BEGIN PRIVATE KEY-----
// MIIEvQIBADANBgkqhki...
```

### Asynchronous Generation (Preferred in Servers)

Key generation is CPU-intensive. In a server context, use the async version to avoid blocking the event loop:

```javascript
'use strict';

const crypto = require('node:crypto');

crypto.generateKeyPair('rsa', {
  modulusLength: 4096, // Stronger but slower to generate

  publicKeyEncoding: {
    type: 'spki',
    format: 'pem',
  },

  privateKeyEncoding: {
    type: 'pkcs8',
    format: 'pem',
  },
}, (err, publicKey, privateKey) => {
  if (err) {
    console.error('Key generation failed:', err);
    return;
  }

  console.log('4096-bit RSA key pair generated successfully');
  console.log('Public key length:', publicKey.length, 'characters');
  console.log('Private key length:', privateKey.length, 'characters');
});
```

### Promise-Based Generation

```javascript
'use strict';

const crypto = require('node:crypto');
const { promisify } = require('node:util');

const generateKeyPair = promisify(crypto.generateKeyPair);

async function generateRSAKeyPair(bits = 2048) {
  const { publicKey, privateKey } = await generateKeyPair('rsa', {
    modulusLength: bits,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

  return { publicKey, privateKey };
}

(async () => {
  console.time('keygen-2048');
  const keys2048 = await generateRSAKeyPair(2048);
  console.timeEnd('keygen-2048');

  console.time('keygen-4096');
  const keys4096 = await generateRSAKeyPair(4096);
  console.timeEnd('keygen-4096');
  // 4096-bit is roughly 5-10x slower to generate than 2048-bit
})();
```

---

## Key Formats and Encodings

### PEM vs DER vs JWK

| Format | Description | Use Case |
|--------|-------------|----------|
| **PEM** | Base64-encoded DER with header/footer lines | Files, configs, most CLI tools |
| **DER** | Raw binary ASN.1 encoding | Certificates, compact storage |
| **JWK** | JSON Web Key — plain JSON object | Web APIs, JWT libraries |

```javascript
'use strict';

const crypto = require('node:crypto');

// Generate keys as KeyObjects (not encoded strings)
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// Export in different formats

// PEM format — text-based, widely used
const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
console.log('PEM public key (first 80 chars):');
console.log(publicPem.substring(0, 80));

// DER format — binary, compact
const publicDer = publicKey.export({ type: 'spki', format: 'der' });
console.log('\nDER public key size:', publicDer.length, 'bytes');

// JWK format — JSON, web-friendly
const publicJwk = publicKey.export({ format: 'jwk' });
console.log('\nJWK public key:');
console.log(JSON.stringify(publicJwk, null, 2).substring(0, 200));
```

### Public Key Encoding Types

| Type | Standard | Notes |
|------|----------|-------|
| `'spki'` | SubjectPublicKeyInfo (X.509) | **Recommended** — algorithm-agnostic |
| `'pkcs1'` | PKCS#1 RSAPublicKey | RSA-specific, used by some legacy tools |

### Private Key Encoding Types

| Type | Standard | Notes |
|------|----------|-------|
| `'pkcs8'` | PKCS#8 PrivateKeyInfo | **Recommended** — algorithm-agnostic |
| `'pkcs1'` | PKCS#1 RSAPrivateKey | RSA-specific, legacy |

### Encrypted Private Keys

You can protect private keys with a passphrase:

```javascript
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: {
    type: 'pkcs8',
    format: 'pem',
    cipher: 'aes-256-cbc',        // Encrypt the private key
    passphrase: 'strong-passphrase', // With this passphrase
  },
});

console.log('Encrypted private key header:');
console.log(privateKey.split('\n')[0]);
// -----BEGIN ENCRYPTED PRIVATE KEY-----

// To use the encrypted private key, provide the passphrase
const keyObject = crypto.createPrivateKey({
  key: privateKey,
  passphrase: 'strong-passphrase',
});

console.log('Key type:', keyObject.type);           // 'private'
console.log('Asymmetric type:', keyObject.asymmetricKeyType); // 'rsa'
console.log('Key size:', keyObject.asymmetricKeySize, 'bits'); // 2048
```

---

## Encrypting and Decrypting with RSA

### Basic RSA Encryption

```javascript
'use strict';

const crypto = require('node:crypto');

// Generate key pair
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// Encrypt with the public key
const plaintext = Buffer.from('This is a secret message');

const encrypted = crypto.publicEncrypt(publicKey, plaintext);
console.log('Encrypted (hex):', encrypted.toString('hex').substring(0, 80) + '...');
console.log('Encrypted length:', encrypted.length, 'bytes');
// For 2048-bit RSA: always 256 bytes output regardless of input size

// Decrypt with the private key
const decrypted = crypto.privateDecrypt(privateKey, encrypted);
console.log('Decrypted:', decrypted.toString('utf8'));
```

### OAEP Padding (Recommended)

OAEP (Optimal Asymmetric Encryption Padding) is the modern, secure padding scheme. It is the default in Node.js:

```javascript
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// OAEP with SHA-256 (more secure than default SHA-1 OAEP)
const encrypted = crypto.publicEncrypt(
  {
    key: publicKey,
    padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
    oaepHash: 'sha256', // Hash used for OAEP padding
  },
  Buffer.from('Secure message with OAEP-SHA256')
);

const decrypted = crypto.privateDecrypt(
  {
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
    oaepHash: 'sha256', // Must match encryption
  },
  encrypted
);

console.log('Decrypted:', decrypted.toString('utf8'));
```

### Padding Options

| Padding | Constant | Security | Notes |
|---------|----------|----------|-------|
| OAEP | `RSA_PKCS1_OAEP_PADDING` | **Recommended** | Provably secure with random oracle model |
| PKCS1 v1.5 | `RSA_PKCS1_PADDING` | Legacy | Vulnerable to Bleichenbacher attacks |
| No padding | `RSA_NO_PADDING` | **Dangerous** | Only for expert use with custom schemes |

---

## RSA Size Limitation

RSA can only encrypt data smaller than the key size minus the padding overhead. This is a fundamental constraint:

```javascript
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// 2048-bit RSA with OAEP-SHA256 padding:
// Max plaintext = 256 - 2*32 - 2 = 190 bytes
// (key_bytes - 2*hash_bytes - 2)

// This works (190 bytes)
const data190 = crypto.randomBytes(190);
const enc190 = crypto.publicEncrypt(
  { key: publicKey, oaepHash: 'sha256' },
  data190
);
console.log('190 bytes encrypted successfully');

// This fails (191 bytes)
try {
  const data191 = crypto.randomBytes(191);
  crypto.publicEncrypt(
    { key: publicKey, oaepHash: 'sha256' },
    data191
  );
} catch (err) {
  console.log('191 bytes failed:', err.message);
  // "data too large for key size"
}

// Maximum plaintext sizes for OAEP-SHA256:
// 1024-bit RSA: 128 - 66 = 62 bytes   (too small for most uses)
// 2048-bit RSA: 256 - 66 = 190 bytes
// 4096-bit RSA: 512 - 66 = 446 bytes
console.log('\nMax plaintext sizes (OAEP-SHA256):');
console.log('2048-bit RSA: 190 bytes');
console.log('4096-bit RSA: 446 bytes');
```

This limitation is why RSA is never used to encrypt bulk data directly. Instead, you use the **hybrid encryption pattern**.

---

## Hybrid Encryption: RSA + AES

The hybrid pattern is how real-world systems (TLS, PGP, S/MIME) handle encryption:

1. Generate a random AES key (the "session key").
2. Encrypt the data with AES (fast, no size limit).
3. Encrypt the AES key with RSA (only 32 bytes to encrypt).
4. Send the RSA-encrypted key + AES-encrypted data together.

```javascript
'use strict';

const crypto = require('node:crypto');

// --- Key pair (the recipient generates this once) ---
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// === Sender: Encrypt ===

function hybridEncrypt(plaintext, recipientPublicKey) {
  // Step 1: Generate a random AES-256 key
  const aesKey = crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);

  // Step 2: Encrypt the data with AES-256-GCM
  const cipher = crypto.createCipheriv('aes-256-gcm', aesKey, iv);
  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  // Step 3: Encrypt the AES key with RSA
  const encryptedKey = crypto.publicEncrypt(
    { key: recipientPublicKey, oaepHash: 'sha256' },
    aesKey // Only 32 bytes — well within RSA limits
  );

  // Step 4: Package everything together
  // Format: [2 bytes: encrypted key length] [encrypted key] [12 bytes: IV] [16 bytes: tag] [ciphertext]
  const keyLenBuf = Buffer.alloc(2);
  keyLenBuf.writeUInt16BE(encryptedKey.length);

  return Buffer.concat([keyLenBuf, encryptedKey, iv, tag, encrypted]);
}

// === Recipient: Decrypt ===

function hybridDecrypt(package_, recipientPrivateKey) {
  let offset = 0;

  // Parse the encrypted key length
  const keyLen = package_.readUInt16BE(offset);
  offset += 2;

  // Extract the RSA-encrypted AES key
  const encryptedKey = package_.subarray(offset, offset + keyLen);
  offset += keyLen;

  // Extract IV
  const iv = package_.subarray(offset, offset + 12);
  offset += 12;

  // Extract auth tag
  const tag = package_.subarray(offset, offset + 16);
  offset += 16;

  // Extract ciphertext
  const ciphertext = package_.subarray(offset);

  // Step 1: Decrypt the AES key with RSA
  const aesKey = crypto.privateDecrypt(
    { key: recipientPrivateKey, oaepHash: 'sha256' },
    encryptedKey
  );

  // Step 2: Decrypt the data with AES
  const decipher = crypto.createDecipheriv('aes-256-gcm', aesKey, iv);
  decipher.setAuthTag(tag);

  const decrypted = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);

  return decrypted.toString('utf8');
}

// Demo
const largeMessage = 'A'.repeat(10000); // 10KB — way too large for RSA alone
console.log('Original size:', largeMessage.length, 'bytes');

const encrypted = hybridEncrypt(largeMessage, publicKey);
console.log('Encrypted size:', encrypted.length, 'bytes');

const decrypted = hybridDecrypt(encrypted, privateKey);
console.log('Decrypted size:', decrypted.length, 'bytes');
console.log('Match:', largeMessage === decrypted); // true
```

---

## The KeyObject API

Node.js provides the `KeyObject` class for structured key management. `KeyObject` instances wrap the underlying OpenSSL key material and provide a consistent interface:

```javascript
'use strict';

const crypto = require('node:crypto');

// Generate keys as KeyObjects (default when no encoding is specified)
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// Inspect key properties
console.log('Public key type:', publicKey.type);               // 'public'
console.log('Private key type:', privateKey.type);             // 'private'
console.log('Algorithm:', publicKey.asymmetricKeyType);        // 'rsa'
console.log('Key size:', publicKey.asymmetricKeySize, 'bits'); // 2048

// Export to different formats
const pem = publicKey.export({ type: 'spki', format: 'pem' });
const der = publicKey.export({ type: 'spki', format: 'der' });
const jwk = publicKey.export({ format: 'jwk' });

console.log('PEM length:', pem.length);
console.log('DER length:', der.length);
console.log('JWK keys:', Object.keys(jwk));
// ['kty', 'n', 'e'] — key type, modulus, exponent
```

### Loading Keys from PEM Strings

```javascript
'use strict';

const crypto = require('node:crypto');

// Suppose you have PEM keys stored as strings (e.g., from a file or env var)
const { publicKey: pubKeyObj, privateKey: privKeyObj } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

const publicPem = pubKeyObj.export({ type: 'spki', format: 'pem' });
const privatePem = privKeyObj.export({ type: 'pkcs8', format: 'pem' });

// Create KeyObjects from PEM strings
const loadedPublic = crypto.createPublicKey(publicPem);
const loadedPrivate = crypto.createPrivateKey(privatePem);

console.log('Loaded public key type:', loadedPublic.asymmetricKeyType);  // 'rsa'
console.log('Loaded private key type:', loadedPrivate.asymmetricKeyType); // 'rsa'

// Encrypt with the loaded public key and decrypt with the loaded private key
const message = Buffer.from('KeyObject API works!');
const enc = crypto.publicEncrypt(loadedPublic, message);
const dec = crypto.privateDecrypt(loadedPrivate, enc);
console.log('Decrypted:', dec.toString('utf8'));
```

### Loading Keys from Files

```javascript
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function loadKeyPair(publicKeyPath, privateKeyPath, passphrase) {
  const publicPem = fs.readFileSync(publicKeyPath, 'utf8');
  const privatePem = fs.readFileSync(privateKeyPath, 'utf8');

  const publicKey = crypto.createPublicKey(publicPem);

  const privateKeyOptions = { key: privatePem };
  if (passphrase) {
    privateKeyOptions.passphrase = passphrase;
  }
  const privateKey = crypto.createPrivateKey(privateKeyOptions);

  return { publicKey, privateKey };
}

// Extracting a public key from a private key
// (The public key is mathematically derived from the private key)
function publicKeyFromPrivate(privateKey) {
  return crypto.createPublicKey(privateKey);
}

// Demo: generate, save, load
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// You can derive the public key from the private key
const derived = publicKeyFromPrivate(privateKey);
const original = publicKey.export({ type: 'spki', format: 'pem' });
const fromPrivate = derived.export({ type: 'spki', format: 'pem' });
console.log('Public keys match:', original === fromPrivate); // true
```

---

## Key Size Recommendations

| Key Size | Security Level | Use Case | Generation Time |
|----------|---------------|----------|----------------|
| 1024 bits | **Broken** | Never use | ~50ms |
| 2048 bits | Adequate until ~2030 | Short-lived keys, development | ~100-300ms |
| 3072 bits | Secure until ~2040 | Medium-term keys | ~500ms-1s |
| 4096 bits | Long-term security | CA certificates, long-lived keys | ~2-5s |

NIST recommends 2048-bit RSA as the minimum. For keys that must remain secure for decades, use 4096 bits. For ephemeral keys (like TLS session keys), 2048 bits is sufficient since they are short-lived.

```javascript
'use strict';

const crypto = require('node:crypto');
const { promisify } = require('node:util');

const generateKeyPair = promisify(crypto.generateKeyPair);

async function benchmarkKeyGen() {
  const sizes = [2048, 3072, 4096];

  for (const bits of sizes) {
    const start = performance.now();
    await generateKeyPair('rsa', {
      modulusLength: bits,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const elapsed = (performance.now() - start).toFixed(1);
    console.log(`RSA-${bits}: ${elapsed}ms`);
  }
}

benchmarkKeyGen();
```

---

## Reverse Encryption: Private Key Encrypts, Public Key Decrypts

This pattern is used for digital signatures (covered in Lesson 06), but `node:crypto` also exposes the raw operation:

```javascript
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
});

// Encrypt with private key (signing-like operation)
const data = Buffer.from('Signed by the private key holder');
const encrypted = crypto.privateEncrypt(privateKey, data);

// Decrypt with public key (verification-like operation)
const decrypted = crypto.publicDecrypt(publicKey, encrypted);
console.log('Decrypted:', decrypted.toString('utf8'));

// Anyone with the public key can decrypt — this proves
// the data was encrypted by the private key holder.
// This is the basis of digital signatures.
```

---

## Key Takeaways

- RSA asymmetric encryption uses a public/private key pair — the public key encrypts, the private key decrypts — solving the key distribution problem that plagues symmetric encryption.
- Generate key pairs with `crypto.generateKeyPairSync()` or the async `crypto.generateKeyPair()`, using `modulusLength: 2048` as the minimum and `4096` for long-term security.
- RSA can only encrypt data smaller than the key size minus padding overhead (~190 bytes for 2048-bit with OAEP-SHA256), so real-world systems use the hybrid pattern: encrypt data with AES, encrypt the AES key with RSA.
- Always use OAEP padding (`RSA_PKCS1_OAEP_PADDING` with `oaepHash: 'sha256'`) — never PKCS1 v1.5 padding for new code, as it is vulnerable to Bleichenbacher's adaptive chosen-ciphertext attack.
- The `KeyObject` API (`createPublicKey()`, `createPrivateKey()`) provides a structured way to load, inspect, and export keys in PEM, DER, and JWK formats, and you can derive a public key from any private key.

## Next

Continue to [Lesson 05 — Diffie-Hellman & ECDH](lesson-05-diffie-hellman.md), where you will implement key exchange protocols that let two parties establish a shared secret over an insecure channel, using both classical Diffie-Hellman and the modern elliptic curve variant.
