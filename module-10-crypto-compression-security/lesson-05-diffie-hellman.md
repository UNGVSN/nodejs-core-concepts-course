# Module 10 / Lesson 05 — Diffie-Hellman & ECDH

> You can encrypt data with AES if both parties share a key, and you can use RSA to send that key securely. But what if neither party has the other's public key? What if you need two strangers to agree on a shared secret over a channel that anyone can observe? This is the key exchange problem, and Diffie-Hellman solved it in 1976. The elliptic curve variant (ECDH) makes it faster and more compact. Together, they are the foundation of every TLS handshake, every SSH connection, and every end-to-end encrypted chat. Node.js provides both classical DH and ECDH through `node:crypto`.

## Learning Objectives

- Explain the key exchange problem and why Diffie-Hellman was a breakthrough in public-key cryptography
- Implement a complete Diffie-Hellman key exchange using `crypto.createDiffieHellman()`
- Perform ECDH key exchange with `crypto.createECDH()` using standard curves like P-256 and X25519
- Combine a key exchange with symmetric encryption to build a complete secure communication channel
- Define Perfect Forward Secrecy (PFS) and explain why ephemeral key exchange is critical for modern security

---

## The Key Exchange Problem

Imagine Alice and Bob want to communicate securely. They need a shared secret key for AES encryption. But how do they agree on that key?

| Approach | Problem |
|----------|---------|
| Meet in person | Does not scale — what about millions of web users? |
| Send the key over the network | An eavesdropper (Eve) intercepts it. |
| Use RSA to encrypt the key | Requires Alice to already have Bob's public key. |
| Diffie-Hellman | Both parties contribute randomness over a public channel. Eve sees the exchange but cannot compute the shared secret. |

Diffie-Hellman is the elegant solution: Alice and Bob each generate a private value, exchange public values, and independently compute the same shared secret. An eavesdropper who sees the public values cannot derive the secret — it is computationally infeasible.

---

## Classical Diffie-Hellman (DH)

### The Math (Simplified)

The protocol relies on the **discrete logarithm problem**: given a prime `p`, a generator `g`, and the value `g^a mod p`, it is computationally infeasible to determine `a`.

```
Setup:
  Choose a large prime p and a generator g.

Alice:                              Bob:
  Pick secret a                       Pick secret b
  Compute A = g^a mod p               Compute B = g^b mod p
  Send A to Bob ──────────────────▶   Send B to Alice
                 ◀──────────────────

  Compute secret = B^a mod p          Compute secret = A^b mod p
  = (g^b)^a mod p                     = (g^a)^b mod p
  = g^(ab) mod p                      = g^(ab) mod p
                    ↕ SAME ↕

Eve sees: p, g, A, B
Eve needs: a or b (discrete log problem — computationally infeasible)
```

### DH Key Exchange in Node.js

```javascript
'use strict';

const crypto = require('node:crypto');

// === Step 1: Alice generates DH parameters and her key pair ===

const alice = crypto.createDiffieHellman(2048); // Generate prime p and generator g
alice.generateKeys(); // Generate Alice's private key and compute public key

const alicePublicKey = alice.getPublicKey();     // g^a mod p
const prime = alice.getPrime();                  // p
const generator = alice.getGenerator();          // g

console.log('=== Alice ===');
console.log('Prime length:', prime.length, 'bytes');
console.log('Generator:', generator.toString('hex'));
console.log('Public key length:', alicePublicKey.length, 'bytes');

// === Step 2: Alice sends her public key, prime, and generator to Bob ===
// (These values are safe to transmit over an insecure channel)

// === Step 3: Bob creates DH with Alice's parameters and generates his keys ===

const bob = crypto.createDiffieHellman(prime, generator);
bob.generateKeys();

const bobPublicKey = bob.getPublicKey();

console.log('\n=== Bob ===');
console.log('Public key length:', bobPublicKey.length, 'bytes');

// === Step 4: Both compute the shared secret ===

const aliceSecret = alice.computeSecret(bobPublicKey);
const bobSecret = bob.computeSecret(alicePublicKey);

console.log('\n=== Shared Secret ===');
console.log('Alice computed:', aliceSecret.toString('hex').substring(0, 64) + '...');
console.log('Bob computed:  ', bobSecret.toString('hex').substring(0, 64) + '...');
console.log('Secrets match:', aliceSecret.equals(bobSecret)); // true
```

### Inspecting DH Parameters

```javascript
'use strict';

const crypto = require('node:crypto');

const dh = crypto.createDiffieHellman(1024); // Smaller for demo speed
dh.generateKeys();

console.log('Prime (p):', dh.getPrime('hex').substring(0, 60) + '...');
console.log('Generator (g):', dh.getGenerator('hex'));
console.log('Public key:', dh.getPublicKey('hex').substring(0, 60) + '...');
console.log('Private key:', dh.getPrivateKey('hex').substring(0, 60) + '...');

// You can also get/set keys in different encodings
console.log('\nPublic key (base64):', dh.getPublicKey('base64').substring(0, 40) + '...');
```

---

## Elliptic Curve Diffie-Hellman (ECDH)

ECDH performs the same key exchange as classical DH but uses elliptic curves instead of prime number modular arithmetic. The result: **same security with much smaller keys**.

| Algorithm | Key Size for ~128-bit Security | Key Size for ~256-bit Security |
|-----------|-------------------------------|-------------------------------|
| Classical DH | 3072 bits | 15360 bits |
| ECDH | 256 bits | 512 bits |

Smaller keys mean faster computation, less bandwidth, and less storage — a significant advantage for mobile devices and high-throughput servers.

### Available Curves

```javascript
'use strict';

const crypto = require('node:crypto');

const curves = crypto.getCurves();
console.log('Total curves available:', curves.length);

// The curves you will actually use:
const importantCurves = [
  { name: 'prime256v1', alias: 'P-256 / secp256r1', bits: 256 },
  { name: 'secp384r1',  alias: 'P-384',             bits: 384 },
  { name: 'secp521r1',  alias: 'P-521',             bits: 521 },
  { name: 'X25519',     alias: 'Curve25519',         bits: 255 },
];

console.log('\nImportant curves:');
for (const curve of importantCurves) {
  const available = curves.includes(curve.name);
  console.log(`  ${curve.name.padEnd(14)} (${curve.alias.padEnd(20)}) ${curve.bits}-bit — ${available ? 'available' : 'NOT available'}`);
}
```

| Curve | Security Level | Performance | Notes |
|-------|---------------|-------------|-------|
| `prime256v1` (P-256) | 128-bit | Fast | Most widely used, NIST standard |
| `secp384r1` (P-384) | 192-bit | Moderate | Required by some government standards |
| `secp521r1` (P-521) | 256-bit | Slower | Maximum NIST curve security |
| `X25519` | 128-bit | Fastest | Modern, constant-time, TLS 1.3 default |

### ECDH Key Exchange with P-256

```javascript
'use strict';

const crypto = require('node:crypto');

// === Alice creates ECDH with P-256 curve ===
const alice = crypto.createECDH('prime256v1');
alice.generateKeys();

// === Bob creates ECDH with the same curve ===
const bob = crypto.createECDH('prime256v1');
bob.generateKeys();

console.log('=== ECDH Key Exchange (P-256) ===');
console.log('Alice public key:', alice.getPublicKey('hex').substring(0, 40) + '...');
console.log('Bob public key:  ', bob.getPublicKey('hex').substring(0, 40) + '...');

// Both compute the shared secret
const aliceSecret = alice.computeSecret(bob.getPublicKey());
const bobSecret = bob.computeSecret(alice.getPublicKey());

console.log('\nAlice secret:', aliceSecret.toString('hex'));
console.log('Bob secret:  ', bobSecret.toString('hex'));
console.log('Match:', aliceSecret.equals(bobSecret)); // true
console.log('Secret length:', aliceSecret.length, 'bytes (256 bits)');
```

### ECDH Key Exchange with X25519

X25519 (Curve25519) is the modern choice — it is fast, constant-time (resistant to side-channel attacks), and is the default key exchange in TLS 1.3:

```javascript
'use strict';

const crypto = require('node:crypto');

// X25519 uses the KeyObject API instead of createECDH
// Generate key pairs
const alice = crypto.generateKeyPairSync('x25519');
const bob = crypto.generateKeyPairSync('x25519');

console.log('=== ECDH Key Exchange (X25519) ===');
console.log('Alice public key:', alice.publicKey.export({ type: 'spki', format: 'der' }).toString('hex'));
console.log('Bob public key:  ', bob.publicKey.export({ type: 'spki', format: 'der' }).toString('hex'));

// Compute shared secrets using diffieHellman()
const aliceSecret = crypto.diffieHellman({
  privateKey: alice.privateKey,
  publicKey: bob.publicKey,
});

const bobSecret = crypto.diffieHellman({
  privateKey: bob.privateKey,
  publicKey: alice.publicKey,
});

console.log('\nAlice secret:', aliceSecret.toString('hex'));
console.log('Bob secret:  ', bobSecret.toString('hex'));
console.log('Match:', aliceSecret.equals(bobSecret)); // true
console.log('Secret length:', aliceSecret.length, 'bytes (256 bits)');
```

### Comparing createECDH vs KeyObject API

```javascript
'use strict';

const crypto = require('node:crypto');

// --- Method 1: createECDH (older API, works with named curves) ---
function ecdhClassic(curveName) {
  const alice = crypto.createECDH(curveName);
  alice.generateKeys();
  const bob = crypto.createECDH(curveName);
  bob.generateKeys();

  const secret1 = alice.computeSecret(bob.getPublicKey());
  const secret2 = bob.computeSecret(alice.getPublicKey());

  return {
    method: 'createECDH',
    curve: curveName,
    match: secret1.equals(secret2),
    secretLength: secret1.length,
  };
}

// --- Method 2: KeyObject + diffieHellman (newer API, supports X25519/X448) ---
function ecdhKeyObject(type) {
  const alice = crypto.generateKeyPairSync(type);
  const bob = crypto.generateKeyPairSync(type);

  const secret1 = crypto.diffieHellman({
    privateKey: alice.privateKey,
    publicKey: bob.publicKey,
  });

  const secret2 = crypto.diffieHellman({
    privateKey: bob.privateKey,
    publicKey: alice.publicKey,
  });

  return {
    method: 'diffieHellman',
    type,
    match: secret1.equals(secret2),
    secretLength: secret1.length,
  };
}

console.log('P-256 (createECDH):', ecdhClassic('prime256v1'));
console.log('P-384 (createECDH):', ecdhClassic('secp384r1'));
console.log('X25519 (KeyObject):', ecdhKeyObject('x25519'));
```

---

## Perfect Forward Secrecy (PFS)

Perfect Forward Secrecy means that compromising today's private key does not compromise past communications. This is achieved by using **ephemeral** (one-time) key exchange keys.

### Without PFS (Static RSA Key Exchange)

```
Server has a long-lived RSA key pair.
1. Client encrypts session key with server's RSA public key.
2. Server decrypts with RSA private key.
3. Both use the session key for AES.

PROBLEM: If the server's RSA private key is compromised years later,
an attacker who recorded past traffic can decrypt ALL past sessions.
```

### With PFS (Ephemeral ECDHE)

```
1. For EACH connection, both sides generate fresh ECDH key pairs.
2. They exchange public keys (signed with the server's RSA key for authentication).
3. Both compute a shared secret → derive AES session key.
4. Ephemeral keys are discarded after the handshake.

RESULT: Even if the server's RSA key is compromised later,
past sessions remain secure because the ephemeral ECDH keys no longer exist.
```

```javascript
'use strict';

const crypto = require('node:crypto');

// Simulating ephemeral ECDHE (what TLS 1.3 does for every connection)
function simulateTlsHandshake() {
  console.log('=== Simulated TLS 1.3 Handshake (ECDHE) ===\n');

  // Each connection generates fresh ephemeral keys
  console.log('1. Both sides generate ephemeral X25519 key pairs');
  const client = crypto.generateKeyPairSync('x25519');
  const server = crypto.generateKeyPairSync('x25519');

  // Exchange public keys (in real TLS, server signs this with its certificate)
  console.log('2. Exchange public keys over the network');
  const clientPub = client.publicKey.export({ type: 'spki', format: 'der' });
  const serverPub = server.publicKey.export({ type: 'spki', format: 'der' });
  console.log('   Client pub:', clientPub.toString('hex').substring(0, 40) + '...');
  console.log('   Server pub:', serverPub.toString('hex').substring(0, 40) + '...');

  // Compute shared secret
  console.log('3. Both compute shared secret');
  const clientSecret = crypto.diffieHellman({
    privateKey: client.privateKey,
    publicKey: server.publicKey,
  });
  const serverSecret = crypto.diffieHellman({
    privateKey: server.privateKey,
    publicKey: client.publicKey,
  });
  console.log('   Shared secret:', clientSecret.toString('hex'));
  console.log('   Secrets match:', clientSecret.equals(serverSecret));

  // Derive AES session key from the shared secret using HKDF
  console.log('4. Derive AES session key via HKDF');

  const sessionKey = crypto.hkdfSync(
    'sha256',
    clientSecret,                             // Input key material
    crypto.randomBytes(32),                   // Salt
    Buffer.from('tls13 session key'),         // Info/context
    32                                        // Output key length (AES-256)
  );
  console.log('   Session key:', Buffer.from(sessionKey).toString('hex'));

  // Now both parties can encrypt/decrypt with AES-256-GCM using the session key
  console.log('5. Ephemeral keys discarded — even if server\'s long-term');
  console.log('   RSA key is compromised later, this session is safe.');

  return Buffer.from(sessionKey);
}

const sessionKey = simulateTlsHandshake();
```

---

## Deriving Encryption Keys from Shared Secrets

The raw shared secret from DH/ECDH should not be used directly as an encryption key. Instead, pass it through a Key Derivation Function (KDF) to produce a key of the correct length with proper entropy distribution.

### Using HKDF (HMAC-based Key Derivation Function)

```javascript
'use strict';

const crypto = require('node:crypto');

// ECDH key exchange
const alice = crypto.createECDH('prime256v1');
alice.generateKeys();
const bob = crypto.createECDH('prime256v1');
bob.generateKeys();

const sharedSecret = alice.computeSecret(bob.getPublicKey());
console.log('Shared secret:', sharedSecret.toString('hex'));

// Derive AES key using HKDF (synchronous)
const salt = crypto.randomBytes(32);    // Random salt for this session
const info = Buffer.from('aes-key');    // Context string — different info = different key

const derivedKey = crypto.hkdfSync(
  'sha256',       // Hash algorithm
  sharedSecret,   // Input key material (IKM)
  salt,           // Salt
  info,           // Info/context string
  32              // Output key length in bytes
);

console.log('Derived AES key:', Buffer.from(derivedKey).toString('hex'));

// Derive multiple keys from the same shared secret
const encryptionKey = crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('encryption'), 32);
const macKey = crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('mac'), 32);
const ivKey = crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('iv'), 12);

console.log('Encryption key:', Buffer.from(encryptionKey).toString('hex'));
console.log('MAC key:', Buffer.from(macKey).toString('hex'));
console.log('IV:', Buffer.from(ivKey).toString('hex'));
```

### Using scrypt for Key Derivation

```javascript
'use strict';

const crypto = require('node:crypto');

// Alternative: use scrypt when you need memory-hardness
const alice = crypto.createECDH('prime256v1');
alice.generateKeys();
const bob = crypto.createECDH('prime256v1');
bob.generateKeys();

const sharedSecret = alice.computeSecret(bob.getPublicKey());
const salt = crypto.randomBytes(16);

crypto.scrypt(sharedSecret, salt, 32, { N: 16384, r: 8, p: 1 }, (err, key) => {
  if (err) throw err;
  console.log('scrypt-derived key:', key.toString('hex'));
});
```

---

## Complete Example: Secure Channel Between Two Parties

This brings everything together — key exchange, key derivation, and symmetric encryption:

```javascript
'use strict';

const crypto = require('node:crypto');

class SecureChannel {
  constructor(name) {
    this.name = name;
    this.ecdh = crypto.createECDH('prime256v1');
    this.ecdh.generateKeys();
    this.sessionKey = null;
  }

  getPublicKey() {
    return this.ecdh.getPublicKey();
  }

  establishSession(otherPublicKey) {
    const sharedSecret = this.ecdh.computeSecret(otherPublicKey);
    const salt = crypto.randomBytes(32);

    // Derive session key via HKDF
    this.sessionKey = Buffer.from(
      crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('session-key'), 32)
    );

    console.log(`${this.name}: Session established`);
    return salt; // Both sides need the same salt
  }

  establishSessionWithSalt(otherPublicKey, salt) {
    const sharedSecret = this.ecdh.computeSecret(otherPublicKey);

    this.sessionKey = Buffer.from(
      crypto.hkdfSync('sha256', sharedSecret, salt, Buffer.from('session-key'), 32)
    );

    console.log(`${this.name}: Session established`);
  }

  encrypt(plaintext) {
    if (!this.sessionKey) throw new Error('Session not established');

    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', this.sessionKey, iv);
    const encrypted = Buffer.concat([
      cipher.update(plaintext, 'utf8'),
      cipher.final(),
    ]);
    const tag = cipher.getAuthTag();

    return Buffer.concat([iv, tag, encrypted]);
  }

  decrypt(data) {
    if (!this.sessionKey) throw new Error('Session not established');

    const iv = data.subarray(0, 12);
    const tag = data.subarray(12, 28);
    const ciphertext = data.subarray(28);

    const decipher = crypto.createDecipheriv('aes-256-gcm', this.sessionKey, iv);
    decipher.setAuthTag(tag);

    return Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ]).toString('utf8');
  }
}

// === Simulation ===

console.log('=== Secure Channel Demo ===\n');

const alice = new SecureChannel('Alice');
const bob = new SecureChannel('Bob');

// Step 1: Exchange public keys
const alicePub = alice.getPublicKey();
const bobPub = bob.getPublicKey();

console.log('Public keys exchanged over insecure channel');
console.log(`  Alice → Bob: ${alicePub.toString('hex').substring(0, 30)}...`);
console.log(`  Bob → Alice: ${bobPub.toString('hex').substring(0, 30)}...`);

// Step 2: Establish session (compute shared secret + derive key)
const salt = alice.establishSession(bobPub);
bob.establishSessionWithSalt(alicePub, salt);

// Step 3: Encrypted communication
console.log('\n--- Encrypted Messages ---');

const msg1 = alice.encrypt('Hello Bob! This is a secret message.');
console.log(`Alice → Bob (encrypted): ${msg1.toString('hex').substring(0, 40)}...`);
console.log(`Bob decrypts: "${bob.decrypt(msg1)}"`);

const msg2 = bob.encrypt('Hi Alice! Got your message. Here is my reply.');
console.log(`Bob → Alice (encrypted): ${msg2.toString('hex').substring(0, 40)}...`);
console.log(`Alice decrypts: "${alice.decrypt(msg2)}"`);

// Step 4: Verify tamper detection
console.log('\n--- Tamper Detection ---');
const tampered = Buffer.from(msg1);
tampered[tampered.length - 1] ^= 0x01;

try {
  bob.decrypt(tampered);
} catch (err) {
  console.log('Tampered message rejected:', err.message);
}
```

---

## Performance Comparison

```javascript
'use strict';

const crypto = require('node:crypto');

function benchmark(label, fn, iterations = 100) {
  const start = performance.now();
  for (let i = 0; i < iterations; i++) {
    fn();
  }
  const elapsed = ((performance.now() - start) / iterations).toFixed(2);
  console.log(`${label.padEnd(30)} ${elapsed}ms per operation`);
}

console.log('=== Key Exchange Performance ===\n');

// Classical DH (2048-bit) — parameter generation is slow
benchmark('DH-2048 (keygen)', () => {
  const dh = crypto.createDiffieHellman(2048);
  dh.generateKeys();
}, 5); // Only 5 iterations — it's slow

// ECDH P-256
benchmark('ECDH P-256 (full exchange)', () => {
  const alice = crypto.createECDH('prime256v1');
  alice.generateKeys();
  const bob = crypto.createECDH('prime256v1');
  bob.generateKeys();
  alice.computeSecret(bob.getPublicKey());
});

// X25519
benchmark('X25519 (full exchange)', () => {
  const alice = crypto.generateKeyPairSync('x25519');
  const bob = crypto.generateKeyPairSync('x25519');
  crypto.diffieHellman({
    privateKey: alice.privateKey,
    publicKey: bob.publicKey,
  });
});
```

---

## When to Use Which

```
Need a key exchange for...                 Use...
─────────────────────────────────────────  ──────────────
TLS 1.3 or modern protocols               X25519 (ECDHE)
Legacy system compatibility                ECDH with P-256
FIPS/government compliance                 ECDH with P-384
Maximum security (overkill for most)       ECDH with P-521
Legacy system that mandates DH             Classical DH (2048+ bits)
```

---

## Key Takeaways

- Diffie-Hellman key exchange allows two parties to establish a shared secret over an insecure channel — the eavesdropper sees the public values but cannot compute the secret due to the discrete logarithm problem.
- ECDH (Elliptic Curve Diffie-Hellman) provides the same security as classical DH with dramatically smaller keys and faster computation — `prime256v1` (P-256) is the most widely deployed curve, while `X25519` is the modern default for TLS 1.3.
- Never use the raw shared secret directly as an encryption key — always pass it through a KDF like `crypto.hkdfSync()` or `crypto.scrypt()` to derive a properly-sized key with uniform entropy.
- Perfect Forward Secrecy (PFS) requires ephemeral key exchange — generate fresh DH/ECDH key pairs for every session so that compromising a long-term key cannot decrypt past traffic.
- Node.js offers two APIs for ECDH: the older `crypto.createECDH(curve)` for named NIST curves, and the newer `crypto.diffieHellman({ privateKey, publicKey })` with `KeyObject` pairs for modern curves like X25519.

## Next

Continue to [Lesson 06 — Digital Signatures & Certificates](lesson-06-digital-signatures.md), where you will sign messages with RSA and ECDSA, verify signatures, and work with X.509 certificates to establish trust chains.
