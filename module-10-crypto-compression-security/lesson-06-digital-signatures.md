# Module 10 / Lesson 06 — Digital Signatures & Certificates

> Anyone can encrypt data, but only digital signatures prove *who* sent it. Signatures are the foundation of trust on the internet — from HTTPS certificates to package signing to JWT tokens, they answer the question every distributed system must ask: "Can I trust this message?"

## Learning Objectives

- Understand what digital signatures provide: authenticity, integrity, and non-repudiation
- Create and verify RSA-based signatures using `crypto.createSign()` and `crypto.createVerify()`
- Use modern Ed25519 signatures with the one-shot `crypto.sign()` and `crypto.verify()` APIs
- Inspect X.509 certificates using the `crypto.X509Certificate` class
- Explain certificate chains, trust anchors, and certificate pinning

---

## What Digital Signatures Provide

Digital signatures solve three problems that encryption alone cannot:

| Property | What It Means | Example |
|---|---|---|
| **Authenticity** | Proves who created the message | "This update really came from the vendor" |
| **Integrity** | Proves the message was not altered | "Nobody tampered with this binary in transit" |
| **Non-repudiation** | The signer cannot deny signing | "The sender cannot claim they did not authorize the transfer" |

Encryption protects *confidentiality* — it hides the content. Signatures protect *trust* — they prove the content is genuine. You often need both, but they serve fundamentally different purposes.

## How Signing Works

The signing process has three steps:

```
┌──────────────────────────────────────────────────────────┐
│                    SIGNING                                │
│                                                          │
│  Message ──► Hash Function ──► Message Digest            │
│                                      │                   │
│                              Private Key                 │
│                                      │                   │
│                              Encrypt Digest              │
│                                      │                   │
│                                 Signature                │
│                                                          │
│  Send: Message + Signature                               │
└──────────────────────────────────────────────────────────┘
```

1. **Hash the message** — produce a fixed-size digest (e.g., SHA-256 produces 32 bytes)
2. **Encrypt the hash with the private key** — only the private key holder can produce this output
3. **Attach the signature** — send the original message plus the signature

## How Verification Works

```
┌──────────────────────────────────────────────────────────┐
│                  VERIFICATION                            │
│                                                          │
│  Message ──► Hash Function ──► Digest A                  │
│                                                          │
│  Signature ──► Decrypt with Public Key ──► Digest B      │
│                                                          │
│              Digest A === Digest B ?                      │
│                 ✓ Valid    ✗ Invalid                      │
└──────────────────────────────────────────────────────────┘
```

1. **Hash the received message** — produce Digest A
2. **Decrypt the signature with the public key** — produce Digest B
3. **Compare digests** — if they match, the signature is valid

If the message was altered, Digest A changes but Digest B does not. If a different private key signed it, Digest B will not match. Either way, verification fails.

## RSA Signatures with `createSign()` and `createVerify()`

The classic Node.js signing API uses streaming sign/verify objects.

```js
'use strict';

const crypto = require('node:crypto');

// Generate an RSA key pair for demonstration
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const message = 'Transfer $500 to account 12345';

// --- SIGNING ---
const signer = crypto.createSign('RSA-SHA256');
signer.update(message);
const signature = signer.sign(privateKey, 'base64');

console.log('Message:', message);
console.log('Signature:', signature);

// --- VERIFICATION ---
const verifier = crypto.createVerify('RSA-SHA256');
verifier.update(message);
const isValid = verifier.verify(publicKey, signature, 'base64');

console.log('Valid:', isValid); // true

// --- TAMPERED MESSAGE ---
const verifier2 = crypto.createVerify('RSA-SHA256');
verifier2.update('Transfer $5000 to account 12345'); // altered
const isValid2 = verifier2.verify(publicKey, signature, 'base64');

console.log('Tampered valid:', isValid2); // false
```

### Key Points About the API

- `createSign(algorithm)` — algorithm can be `'RSA-SHA256'`, `'RSA-SHA512'`, or shorthand like `'SHA256'` (Node infers RSA from the key type)
- `.update(data)` — can be called multiple times to feed data incrementally (like a stream)
- `.sign(privateKey, encoding)` — finalizes and returns the signature; encoding is `'hex'`, `'base64'`, or `'buffer'`
- `.verify(publicKey, signature, encoding)` — returns `true` or `false`

### Signing Algorithms

| Algorithm | Hash | Key Type | Notes |
|---|---|---|---|
| `'RSA-SHA256'` | SHA-256 | RSA | Most common, good default |
| `'RSA-SHA512'` | SHA-512 | RSA | Stronger hash, slightly slower |
| `'SHA256'` | SHA-256 | Inferred | Shorthand — Node picks based on key |
| `'SHA384'` | SHA-384 | Inferred | Intermediate strength |
| `'SHA512'` | SHA-512 | Inferred | Strongest SHA-2 variant |

## Incremental Signing — Streaming Data

You can sign large files or streams by calling `.update()` multiple times:

```js
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

// Sign a file by streaming its contents
function signFile(filePath, privKey) {
  const signer = crypto.createSign('SHA256');
  const stream = fs.createReadStream(filePath, { highWaterMark: 16384 });

  return new Promise((resolve, reject) => {
    stream.on('data', (chunk) => signer.update(chunk));
    stream.on('end', () => {
      const sig = signer.sign(privKey, 'base64');
      resolve(sig);
    });
    stream.on('error', reject);
  });
}

// Verify a file signature
function verifyFile(filePath, pubKey, signature) {
  const verifier = crypto.createVerify('SHA256');
  const stream = fs.createReadStream(filePath, { highWaterMark: 16384 });

  return new Promise((resolve, reject) => {
    stream.on('data', (chunk) => verifier.update(chunk));
    stream.on('end', () => {
      const valid = verifier.verify(pubKey, signature, 'base64');
      resolve(valid);
    });
    stream.on('error', reject);
  });
}

// Usage
(async () => {
  const target = path.join(__dirname, 'package.json');
  const sig = await signFile(target, privateKey);
  console.log('File signature:', sig.slice(0, 40) + '...');

  const valid = await verifyFile(target, publicKey, sig);
  console.log('File signature valid:', valid); // true
})();
```

## Ed25519 Signatures — Modern and Fast

Ed25519 is an elliptic curve signature scheme that is faster, produces smaller keys and signatures, and eliminates algorithm choice — there is no "Ed25519-SHA256" vs "Ed25519-SHA512" decision. The hash is baked into the algorithm.

```js
'use strict';

const crypto = require('node:crypto');

// Generate Ed25519 key pair
const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519', {
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

const message = Buffer.from('Authenticate user session 9a3f');

// --- ONE-SHOT SIGNING (no createSign needed) ---
const signature = crypto.sign(null, message, privateKey);

console.log('Signature length:', signature.length, 'bytes'); // 64 bytes always
console.log('Signature (hex):', signature.toString('hex').slice(0, 40) + '...');

// --- ONE-SHOT VERIFICATION ---
const isValid = crypto.verify(null, message, publicKey, signature);
console.log('Valid:', isValid); // true

// --- TAMPERED ---
const tampered = Buffer.from('Authenticate user session XXXX');
const isValid2 = crypto.verify(null, tampered, publicKey, signature);
console.log('Tampered valid:', isValid2); // false
```

### RSA vs Ed25519 Comparison

| Property | RSA-2048 | Ed25519 |
|---|---|---|
| Key generation | ~50ms | ~0.5ms |
| Signature size | 256 bytes | 64 bytes |
| Public key size | 294 bytes (DER) | 44 bytes (DER) |
| Sign speed | ~1,000/sec | ~30,000/sec |
| Verify speed | ~15,000/sec | ~12,000/sec |
| Algorithm choice | Must pick hash | None needed |
| Quantum resistance | Neither | Neither |

Ed25519 is the preferred choice for new applications unless you need RSA for compatibility with legacy systems.

## Signing a JSON Document

A practical pattern is signing structured data. You must canonicalize the JSON first — identical objects can serialize differently if key order varies.

```js
'use strict';

const crypto = require('node:crypto');

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519', {
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

// Canonical JSON: sort keys to ensure consistent serialization
function canonicalize(obj) {
  return JSON.stringify(obj, Object.keys(obj).sort());
}

function signDocument(doc, privKey) {
  const canonical = canonicalize(doc);
  const signature = crypto.sign(null, Buffer.from(canonical), privKey);
  return {
    ...doc,
    _signature: signature.toString('base64'),
  };
}

function verifyDocument(signedDoc, pubKey) {
  const { _signature, ...doc } = signedDoc;
  const canonical = canonicalize(doc);
  const sigBuffer = Buffer.from(_signature, 'base64');
  return crypto.verify(null, Buffer.from(canonical), pubKey, sigBuffer);
}

// Usage
const invoice = {
  id: 'INV-2026-001',
  amount: 1500.00,
  currency: 'USD',
  recipient: 'Acme Corp',
  timestamp: '2026-02-15T10:30:00Z',
};

const signed = signDocument(invoice, privateKey);
console.log('Signed document:', JSON.stringify(signed, null, 2));

const valid = verifyDocument(signed, publicKey);
console.log('Document valid:', valid); // true

// Tamper with the amount
signed.amount = 15000.00;
const validAfterTamper = verifyDocument(signed, publicKey);
console.log('After tampering:', validAfterTamper); // false
```

## X.509 Certificates

X.509 is the standard format for public key certificates — the kind used in HTTPS. A certificate binds a public key to an identity and is signed by a Certificate Authority (CA).

### What a Certificate Contains

```
┌───────────────────────────────────────────┐
│           X.509 Certificate               │
├───────────────────────────────────────────┤
│  Version:           3 (v3)                │
│  Serial Number:     01:23:AB:...          │
│  Issuer:            CN=My CA              │
│  Validity:                                │
│    Not Before:      2026-01-01            │
│    Not After:       2027-01-01            │
│  Subject:           CN=example.com        │
│  Subject Public Key:  RSA 2048-bit        │
│  Extensions:                              │
│    Key Usage:       Digital Signature      │
│    Subject Alt Name: DNS:example.com      │
│  Signature Algorithm: SHA256WithRSA       │
│  Signature:         [bytes]               │
└───────────────────────────────────────────┘
```

### The `crypto.X509Certificate` Class

Node.js 15.6+ provides `crypto.X509Certificate` for inspecting certificates:

```js
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

// Load a PEM-encoded certificate (e.g., from a file)
// For demonstration, we will use a certificate from a TLS connection
// In practice: const pem = fs.readFileSync('cert.pem');
// const cert = new crypto.X509Certificate(pem);

// Simulated example using a self-signed cert generated at runtime
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

// Note: Node.js does not have a built-in API to CREATE X.509 certs.
// In practice, you use `openssl` or a library. Here we inspect an
// existing certificate loaded from a PEM file.

function inspectCertificate(pemData) {
  const cert = new crypto.X509Certificate(pemData);

  console.log('Subject:       ', cert.subject);
  console.log('Issuer:        ', cert.issuer);
  console.log('Valid From:    ', cert.validFrom);
  console.log('Valid To:      ', cert.validTo);
  console.log('Serial Number: ', cert.serialNumber);
  console.log('Fingerprint:   ', cert.fingerprint256);
  console.log('Is CA:         ', cert.ca);
  console.log('Key Usage:     ', cert.keyUsage);

  // Check if certificate covers a specific hostname
  // Returns the hostname if valid, undefined if not
  const hostCheck = cert.checkHost('example.com');
  console.log('Covers example.com:', hostCheck !== undefined);

  return cert;
}

// If you have a cert.pem file:
// inspectCertificate(fs.readFileSync('cert.pem'));
```

### Useful `X509Certificate` Properties and Methods

| Property/Method | Returns | Purpose |
|---|---|---|
| `.subject` | `string` | Distinguished name of the certificate holder |
| `.issuer` | `string` | Distinguished name of the CA that signed it |
| `.validFrom` | `string` | Start of validity period |
| `.validTo` | `string` | End of validity period |
| `.serialNumber` | `string` | Unique serial number (hex) |
| `.fingerprint256` | `string` | SHA-256 fingerprint of the DER-encoded cert |
| `.publicKey` | `KeyObject` | The public key embedded in the certificate |
| `.ca` | `boolean` | Whether this is a CA certificate |
| `.keyUsage` | `string[]` | Permitted uses (e.g., `['digitalSignature']`) |
| `.checkHost(host)` | `string \| undefined` | Checks Subject Alt Name against a hostname |
| `.checkEmail(email)` | `string \| undefined` | Checks against an email address |
| `.checkIP(ip)` | `string \| undefined` | Checks against an IP address |
| `.verify(publicKey)` | `boolean` | Verifies the cert was signed by the given key |

## Certificate Chains

No certificate exists in isolation. Trust is established through a *chain*:

```
┌─────────────────────┐
│   Root CA            │  ← Self-signed, pre-installed in OS/browser
│   (Trust Anchor)     │     Validity: 20-30 years
└────────┬────────────┘
         │ signs
┌────────▼────────────┐
│   Intermediate CA    │  ← Signed by Root CA
│                      │     Validity: 5-10 years
└────────┬────────────┘
         │ signs
┌────────▼────────────┐
│   Leaf Certificate   │  ← Your server's certificate
│   (End Entity)       │     Validity: 90 days - 1 year
└─────────────────────┘
```

**Why intermediate CAs?** The root CA private key is kept offline in a vault. Intermediate CAs handle day-to-day signing. If an intermediate is compromised, the root can revoke it without replacing every certificate on every device.

### Verifying a Certificate Chain

```js
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

function verifyCertificateChain(leafPem, intermediatePem, rootPem) {
  const leaf = new crypto.X509Certificate(leafPem);
  const intermediate = new crypto.X509Certificate(intermediatePem);
  const root = new crypto.X509Certificate(rootPem);

  // Verify leaf was signed by intermediate
  const leafValid = leaf.verify(intermediate.publicKey);
  console.log('Leaf signed by intermediate:', leafValid);

  // Verify intermediate was signed by root
  const intValid = intermediate.verify(root.publicKey);
  console.log('Intermediate signed by root:', intValid);

  // Verify root is self-signed
  const rootSelfSigned = root.verify(root.publicKey);
  console.log('Root is self-signed:', rootSelfSigned);

  // Check validity dates
  const now = new Date();
  const leafNotExpired = new Date(leaf.validTo) > now;
  const leafNotTooEarly = new Date(leaf.validFrom) <= now;
  console.log('Leaf currently valid:', leafNotExpired && leafNotTooEarly);

  return leafValid && intValid && rootSelfSigned;
}

// Usage with actual PEM files:
// verifyCertificateChain(
//   fs.readFileSync('leaf.pem'),
//   fs.readFileSync('intermediate.pem'),
//   fs.readFileSync('root.pem')
// );
```

## Certificate Pinning

Certificate pinning means your client remembers (pins) the exact certificate or public key it expects from a server. Even if a rogue CA issues a valid certificate for your domain, the pinned client will reject it.

```js
'use strict';

const https = require('node:https');
const crypto = require('node:crypto');

// Pin the SHA-256 fingerprint of the expected certificate
const PINNED_FINGERPRINT = 'AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90:AB:CD:EF:12:34:56:78:90';

function makeSecureRequest(hostname, path) {
  return new Promise((resolve, reject) => {
    const req = https.request({ hostname, path, port: 443 }, (res) => {
      // Get the peer certificate
      const cert = res.socket.getPeerCertificate();

      if (!cert || !cert.fingerprint256) {
        req.destroy();
        return reject(new Error('No certificate received'));
      }

      // Compare fingerprints
      if (cert.fingerprint256 !== PINNED_FINGERPRINT) {
        req.destroy();
        return reject(new Error(
          `Certificate fingerprint mismatch!\n` +
          `Expected: ${PINNED_FINGERPRINT}\n` +
          `Received: ${cert.fingerprint256}`
        ));
      }

      console.log('Certificate pin verified successfully');

      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve(body));
    });

    req.on('error', reject);
    req.end();
  });
}
```

### When to Pin

| Scenario | Pin? | Why |
|---|---|---|
| Mobile app → your API | Yes | You control both ends, pin the leaf cert or public key |
| Browser → any website | No | Browsers handle certificate trust via the OS trust store |
| Microservice → microservice | Maybe | Internal CAs make pinning practical |
| CLI tool → known server | Yes | Pin the expected cert fingerprint |

## Putting It All Together — Signed API Payload

Here is a complete example combining key generation, signing, verification, and certificate concepts:

```js
'use strict';

const crypto = require('node:crypto');

// --- Key Management ---
function generateSigningKeys(algorithm = 'ed25519') {
  return crypto.generateKeyPairSync(algorithm, {
    publicKeyEncoding:  { type: 'spki',  format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
}

// --- Signing ---
function signPayload(payload, privateKeyPem) {
  const data = Buffer.from(JSON.stringify(payload));
  const signature = crypto.sign(null, data, privateKeyPem);
  return signature.toString('base64');
}

// --- Verification ---
function verifyPayload(payload, signatureBase64, publicKeyPem) {
  const data = Buffer.from(JSON.stringify(payload));
  const signature = Buffer.from(signatureBase64, 'base64');
  return crypto.verify(null, data, publicKeyPem, signature);
}

// --- Demo ---
const { publicKey, privateKey } = generateSigningKeys();

const apiPayload = {
  action: 'deploy',
  version: '2.1.0',
  environment: 'production',
  timestamp: Date.now(),
};

const sig = signPayload(apiPayload, privateKey);
console.log('Payload:', JSON.stringify(apiPayload, null, 2));
console.log('Signature:', sig);

const valid = verifyPayload(apiPayload, sig, publicKey);
console.log('Verification:', valid ? 'PASSED' : 'FAILED');

// Simulate someone altering the payload
apiPayload.environment = 'staging';
const stillValid = verifyPayload(apiPayload, sig, publicKey);
console.log('After tamper:', stillValid ? 'PASSED' : 'FAILED');
```

## Key Takeaways

- Digital signatures provide authenticity, integrity, and non-repudiation — three properties that encryption alone cannot deliver
- Use `crypto.createSign()` / `crypto.createVerify()` for RSA signatures, or the one-shot `crypto.sign()` / `crypto.verify()` for Ed25519
- Ed25519 is faster, produces smaller signatures, and eliminates algorithm choice — prefer it for new applications
- X.509 certificates bind public keys to identities and form chains of trust from leaf to root CA
- Certificate pinning adds an extra layer of trust by verifying the exact certificate fingerprint, but requires careful rotation planning

## Next

Continue to [Lesson 07 — TLS/HTTPS Implementation](lesson-07-tls-https.md), where we use certificates and keys to build encrypted network connections with the `node:tls` and `node:https` modules.
