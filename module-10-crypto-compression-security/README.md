# Module 10 — Cryptography, Compression & Security

> Trust nothing. Verify everything. This final module covers the `node:crypto` and `node:zlib` modules — hashing passwords, encrypting data, establishing TLS connections, signing artifacts, and compressing responses. Every concept is implemented from first principles using Node.js core, with a relentless focus on the mistakes that lead to real-world security breaches.

---

## Learning Objectives

- Hash data with SHA-256, HMAC, and timing-safe comparison to prevent length-extension and timing attacks
- Encrypt and decrypt data using AES-256-GCM with proper IV generation and authentication tag handling
- Generate RSA key pairs, encrypt with public keys, and decrypt with private keys
- Perform Diffie-Hellman and ECDH key exchanges for secure channel establishment
- Create and verify digital signatures, generate self-signed certificates, and stand up HTTPS servers
- Compress and decompress data with gzip, deflate, and brotli — both buffered and streaming
- Apply security best practices: `scrypt` for passwords, `randomBytes` for entropy, secure headers for responses

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Cryptography Fundamentals](lesson-01-crypto-fundamentals.md) | Symmetric vs asymmetric, keys, entropy, `crypto.randomBytes`, `crypto.randomUUID` |
| 02 | [Hashing (SHA, MD5, HMAC)](lesson-02-hashing.md) | `crypto.createHash`, `crypto.createHmac`, SHA-256, SHA-512, MD5 (and why not to use it) |
| 03 | [Symmetric Encryption (AES)](lesson-03-symmetric-encryption.md) | AES-256-GCM, `createCipheriv`/`createDecipheriv`, IVs, auth tags, key derivation with `scrypt` |
| 04 | [Asymmetric Encryption (RSA)](lesson-04-asymmetric-encryption.md) | `generateKeyPairSync`, `publicEncrypt`, `privateDecrypt`, OAEP padding, key formats |
| 05 | [Diffie-Hellman & ECDH](lesson-05-diffie-hellman.md) | Key exchange protocols, `createDiffieHellman`, `createECDH`, computing shared secrets |
| 06 | [Digital Signatures & Certificates](lesson-06-digital-signatures.md) | `crypto.sign`, `crypto.verify`, X.509 certificates, self-signed cert generation |
| 07 | [TLS/HTTPS Implementation](lesson-07-tls-https.md) | `node:https`, `node:tls`, certificate chains, SNI, `tls.connect`, mutual TLS |
| 08 | [Zlib Compression (gzip, deflate, brotli)](lesson-08-zlib-compression.md) | `zlib.gzip`, `zlib.deflate`, `zlib.brotliCompress`, streaming compression, `Accept-Encoding` |
| 09 | [Security Best Practices](lesson-09-security-best-practices.md) | Timing attacks, `timingSafeEqual`, password hashing (`scrypt`/`pbkdf2`), secure response headers |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [Password Hasher & Verifier](exercise-01-password-hasher.md) | Hash passwords with `scrypt`, generate random salts, timing-safe comparison on verify |
| E02 | [File Encryptor/Decryptor](exercise-02-file-encryptor.md) | AES-256-GCM streaming file encryption — encrypt large files without loading into memory |
| E03 | [Self-Signed HTTPS Server](exercise-03-self-signed-https.md) | Generate certs with `crypto.generateKeyPairSync`, create HTTPS server, test with `curl` |
| E04 | [Compression Benchmark](exercise-04-compression-benchmark.md) | Compare gzip vs deflate vs brotli — compression ratio, speed, memory, across file types |
| E05 | [Secure Key Exchange](exercise-05-secure-key-exchange.md) | Two Node.js processes exchange keys via ECDH, then communicate with AES-encrypted messages |
| E06 | [Digital Signature Verification](exercise-06-digital-signature-verification.md) | Sign files with RSA, distribute the public key, verify signatures, detect tampering |

---

## Progressive Project — Step 10: TLS/HTTPS + Compression

This is the tenth and final step of the course-spanning progressive project: **Build Your Own Production HTTP Server**.

In this step you add the production security and performance features that transform your HTTP framework from a learning exercise into something you could actually deploy. Encryption protects data in transit, compression reduces bandwidth, and security headers defend against common web attacks.

**What you will build:**

- HTTPS support via `tls.createServer` with PEM certificate and key loading
- Gzip and brotli response compression as middleware, negotiated via the `Accept-Encoding` header
- `Content-Encoding` response header set automatically based on compression algorithm
- Security headers middleware: `Strict-Transport-Security`, `Content-Security-Policy`, `X-Content-Type-Options`, `X-Frame-Options`
- HTTP-to-HTTPS redirect for plaintext requests
- Certificate hot-reload — watch cert files and update TLS context without server restart

**Key code pattern:**

```javascript
'use strict';

const https = require('node:https');
const fs = require('node:fs');
const zlib = require('node:zlib');
const { pipeline } = require('node:stream');

const options = {
  key: fs.readFileSync('./certs/server-key.pem'),
  cert: fs.readFileSync('./certs/server-cert.pem'),
};

function compressionMiddleware(req, res, body) {
  const accept = req.headers['accept-encoding'] || '';

  if (accept.includes('br')) {
    res.setHeader('Content-Encoding', 'br');
    pipeline(body, zlib.createBrotliCompress(), res, (err) => {
      if (err) console.error('Compression error:', err.message);
    });
  } else if (accept.includes('gzip')) {
    res.setHeader('Content-Encoding', 'gzip');
    pipeline(body, zlib.createGzip(), res, (err) => {
      if (err) console.error('Compression error:', err.message);
    });
  } else {
    pipeline(body, res, (err) => {
      if (err) console.error('Stream error:', err.message);
    });
  }
}

const server = https.createServer(options, (req, res) => {
  // Security headers
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  // ... route handling
});
```

**Builds on:** Step 09 (Worker Thread Request Handling) — you have a multi-threaded HTTP server; now you secure and optimize it for production traffic.

**Completes:** The progressive project. You now have a fully functional HTTP server framework built entirely from Node.js core modules — event-driven dispatch, middleware chain, Buffer body parsing, static file serving, streaming responses, TCP foundation, HTTP protocol, child process workers, thread pool offloading, TLS encryption, and response compression.

---

## Key Takeaways

After completing this module — and the entire course — you will understand cryptography and compression at the implementation level, not just the API level. You will know why AES-GCM beats AES-CBC, why `scrypt` beats `pbkdf2` for passwords, and why brotli beats gzip for text. More importantly, you will have built every layer of an HTTP server from scratch, proving that Node.js core is all you need.

---

## Next

You have completed all 10 modules. Continue to the [Capstone Projects](../project-01-production-http-server/README.md) to put everything together in large-scale, production-grade builds.
