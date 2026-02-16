# Track 02 / Lesson 02 — TLS Deep Dive

> TLS is the protocol that turns the public internet from an open postcard system into sealed envelopes. Understanding it at the handshake level — not just calling `https.createServer()` — is the difference between a server that is encrypted and a server that is actually secure.

## Learning Objectives

- Trace the full TLS 1.3 handshake: ClientHello, ServerHello, key exchange, and 0-RTT resumption
- Explain certificate chains (root CA, intermediate CA, leaf certificate) and how Node.js validates them
- Configure cipher suites using `tls.DEFAULT_CIPHERS` and understand which to prefer and which to disable
- Implement OCSP stapling and certificate transparency verification using `node:tls`
- Verify peer certificates programmatically and enforce certificate pinning from a Node.js client

---

## The Purpose of TLS

TLS (Transport Layer Security) provides three guarantees:

1. **Confidentiality** — Data is encrypted in transit. An eavesdropper on the network sees ciphertext, not plaintext.
2. **Integrity** — Data cannot be modified in transit without detection. Each record includes a MAC (Message Authentication Code).
3. **Authentication** — The server proves its identity via a certificate signed by a trusted Certificate Authority.

TLS sits between the application layer (HTTP) and the transport layer (TCP):

```
┌──────────────┐
│  HTTP (L7)   │  ← Application data (request/response)
├──────────────┤
│  TLS (L6)    │  ← Encryption, authentication, integrity
├──────────────┤
│  TCP (L4)    │  ← Reliable byte stream
├──────────────┤
│  IP  (L3)    │  ← Routing
└──────────────┘
```

---

## Certificate Chains

TLS authentication works through a chain of trust:

```
Root CA Certificate (self-signed, in OS trust store)
  │
  └── Intermediate CA Certificate (signed by Root CA)
        │
        └── Leaf Certificate (signed by Intermediate CA)
              │
              └── Your server presents this to clients
```

**Root CA:** Self-signed certificate pre-installed in the operating system or browser trust store. There are approximately 150 trusted root CAs worldwide. Node.js uses the OpenSSL-compiled trust store or, since v7.3.0, can use the `--use-openssl-ca` or `--use-bundled-ca` flags.

**Intermediate CA:** Signed by the root CA. Intermediates exist so the root CA's private key can remain offline (in a hardware security module). If an intermediate is compromised, only that intermediate's certificates are revoked — not every certificate from the root.

**Leaf Certificate:** Your server's certificate. It contains your domain name (the Common Name or Subject Alternative Name), a public key, a validity period, and the issuer's signature.

### Inspecting a Certificate Chain in Node.js

```js
'use strict';

const tls = require('node:tls');

// Connect to a server and inspect its certificate chain
function inspectCertificateChain(hostname, port = 443) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: hostname, port, servername: hostname }, () => {
      const cert = socket.getPeerCertificate(true); // true = include full chain
      const chain = [];

      let current = cert;
      const seen = new Set();

      while (current && !seen.has(current.fingerprint256)) {
        seen.add(current.fingerprint256);
        chain.push({
          subject:     current.subject?.CN || '(none)',
          issuer:      current.issuer?.CN || '(none)',
          validFrom:   current.valid_from,
          validTo:     current.valid_to,
          fingerprint: current.fingerprint256,
          serialNumber: current.serialNumber,
          subjectAltName: current.subjectaltname || '(none)',
        });
        current = current.issuerCertificate;
      }

      socket.end();
      resolve(chain);
    });

    socket.on('error', reject);
  });
}

// Usage
inspectCertificateChain('nodejs.org').then(chain => {
  console.log(`Certificate chain for nodejs.org (${chain.length} certificates):\n`);
  chain.forEach((cert, i) => {
    const indent = '  '.repeat(i);
    console.log(`${indent}[${i}] Subject: ${cert.subject}`);
    console.log(`${indent}    Issuer:  ${cert.issuer}`);
    console.log(`${indent}    Valid:   ${cert.validFrom} → ${cert.validTo}`);
    console.log(`${indent}    SAN:     ${cert.subjectAltName}`);
    console.log();
  });
}).catch(err => {
  console.error('Connection failed:', err.message);
});
```

---

## The TLS 1.3 Handshake

TLS 1.3 (RFC 8446) dramatically simplified the handshake compared to TLS 1.2. The full handshake completes in a single round trip (1-RTT):

```
Client                                              Server
  │                                                    │
  │── ClientHello ───────────────────────────────────▶ │
  │   - Supported cipher suites                        │
  │   - Supported key exchange groups                  │
  │   - Key share (client's DH public key)             │
  │   - Supported TLS versions                         │
  │                                                    │
  │◀── ServerHello ─────────────────────────────────── │
  │   - Selected cipher suite                          │
  │   - Key share (server's DH public key)             │
  │   - {EncryptedExtensions}                          │
  │   - {Certificate}                                  │
  │   - {CertificateVerify}                            │
  │   - {Finished}                                     │
  │                                                    │
  │── {Finished} ────────────────────────────────────▶ │
  │                                                    │
  │◀═══════ Encrypted Application Data ═══════════════▶│
```

Key differences from TLS 1.2:

- **1-RTT instead of 2-RTT:** The client sends its key share in the first message, so the handshake completes one round trip faster.
- **No RSA key exchange:** Only Diffie-Hellman-based key exchanges remain, providing forward secrecy by default.
- **Encrypted after ServerHello:** Everything after the ServerHello is encrypted — including the certificate. In TLS 1.2, the certificate was sent in the clear.
- **Removed insecure features:** No more RC4, SHA-1, static RSA, CBC-mode ciphers, or renegotiation.

### 0-RTT Resumption

When a client has previously connected to a server, TLS 1.3 supports 0-RTT (zero round trip time) resumption:

```
Client                                              Server
  │                                                    │
  │── ClientHello + EarlyData (0-RTT) ──────────────▶ │
  │   - Pre-shared key from previous session           │
  │   - Application data (e.g., GET /api/data)         │
  │                                                    │
  │◀── ServerHello + {Finished} ────────────────────── │
  │                                                    │
  │── {Finished} ────────────────────────────────────▶ │
  │                                                    │
  │◀═══════ Encrypted Application Data ═══════════════▶│
```

**Warning:** 0-RTT data is vulnerable to replay attacks. An attacker who captures the 0-RTT message can replay it, causing the server to process the same request twice. Only use 0-RTT for idempotent operations (GET requests, not POST).

---

## Cipher Suite Configuration

A cipher suite specifies the algorithms used for key exchange, authentication, bulk encryption, and MAC:

```
TLS_AES_256_GCM_SHA384
│    │        │
│    │        └── Hash for key derivation (HKDF)
│    └─────────── Bulk encryption algorithm + mode
└──────────────── TLS 1.3 prefix (key exchange is always DH)
```

In TLS 1.3, only five cipher suites exist:

```
TLS_AES_256_GCM_SHA384       (recommended)
TLS_AES_128_GCM_SHA256       (recommended)
TLS_CHACHA20_POLY1305_SHA256 (recommended for mobile/ARM)
TLS_AES_128_CCM_SHA256       (niche)
TLS_AES_128_CCM_8_SHA256     (IoT only)
```

### Configuring Cipher Suites in Node.js

```js
'use strict';

const tls = require('node:tls');
const fs = require('node:fs');
const crypto = require('node:crypto');

// View the default cipher list
console.log('Default ciphers:');
console.log(tls.DEFAULT_CIPHERS);
console.log();

// View supported ciphers with details
const ciphers = crypto.getCiphers();
console.log(`Total supported ciphers: ${ciphers.length}`);
console.log('AES ciphers:', ciphers.filter(c => c.startsWith('aes')).join(', '));
console.log();

// Create an HTTPS server with explicit cipher configuration
// In production, use real certificates from a CA
function createHardenedServer(certPath, keyPath) {
  const options = {
    cert: fs.readFileSync(certPath),
    key: fs.readFileSync(keyPath),

    // TLS 1.3 only — disable TLS 1.2 and below
    minVersion: 'TLSv1.3',

    // For environments that must support TLS 1.2 clients:
    // minVersion: 'TLSv1.2',
    // ciphers: [
    //   'TLS_AES_256_GCM_SHA384',
    //   'TLS_CHACHA20_POLY1305_SHA256',
    //   'TLS_AES_128_GCM_SHA256',
    //   'ECDHE-ECDSA-AES256-GCM-SHA384',
    //   'ECDHE-RSA-AES256-GCM-SHA384',
    //   'ECDHE-ECDSA-CHACHA20-POLY1305',
    //   'ECDHE-RSA-CHACHA20-POLY1305',
    // ].join(':'),

    // Prefer server cipher order — the server picks the cipher, not the client
    honorCipherOrder: true,

    // Disable session tickets for TLS 1.2 if forward secrecy is paramount
    // (TLS 1.3 handles this differently)
    // ticketKeys: crypto.randomBytes(48),

    // ECDH curve preference
    ecdhCurve: 'X25519:P-256:P-384',
  };

  return tls.createServer(options, (socket) => {
    console.log('Client connected:');
    console.log('  Protocol:', socket.getProtocol());
    console.log('  Cipher:  ', socket.getCipher().name);
    console.log('  Peer CN: ', socket.getPeerCertificate()?.subject?.CN || 'none');

    socket.write('Connected securely\n');
    socket.end();
  });
}
```

---

## OCSP Stapling

OCSP (Online Certificate Status Protocol) lets a client check whether a certificate has been revoked. Without stapling, the client contacts the CA's OCSP responder directly — adding latency and a privacy leak (the CA knows which sites you visit).

With OCSP stapling, the **server** fetches the OCSP response from the CA and includes ("staples") it in the TLS handshake:

```
Without Stapling:
  Client → Server: TLS handshake
  Client → CA OCSP Responder: Is this certificate revoked?
  CA → Client: No, it is valid (signed response)

With Stapling:
  Server → CA OCSP Responder: Is my certificate revoked? (periodic)
  CA → Server: No, it is valid (signed response, cached)
  Client → Server: TLS handshake
  Server → Client: Certificate + stapled OCSP response
```

### Implementing OCSP Stapling in Node.js

```js
'use strict';

const tls = require('node:tls');
const https = require('node:https');
const fs = require('node:fs');

// Node.js supports OCSP stapling via the 'OCSPRequest' event on tls.Server.
// When a client sends a status_request extension (requesting stapled OCSP),
// this event fires.

function createServerWithOCSP(certPath, keyPath, ocspResponsePath) {
  const serverOptions = {
    cert: fs.readFileSync(certPath),
    key: fs.readFileSync(keyPath),
    minVersion: 'TLSv1.2',
  };

  const server = https.createServer(serverOptions, (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OCSP stapling enabled\n');
  });

  // Cache the OCSP response (in production, refresh it periodically)
  let cachedOCSPResponse = null;

  try {
    cachedOCSPResponse = fs.readFileSync(ocspResponsePath);
    console.log('Loaded OCSP response:', cachedOCSPResponse.length, 'bytes');
  } catch {
    console.log('No cached OCSP response found — stapling disabled');
  }

  // Handle OCSP requests from clients
  server.on('OCSPRequest', (certificate, issuer, callback) => {
    console.log('Client requested OCSP stapling');

    if (cachedOCSPResponse) {
      // Provide the cached OCSP response
      callback(null, cachedOCSPResponse);
    } else {
      // No OCSP response available — client will check on its own
      callback(null, null);
    }
  });

  return server;
}
```

---

## Certificate Transparency

Certificate Transparency (CT) is a framework that logs every certificate issued by a CA to publicly auditable logs. If a CA issues a fraudulent certificate for your domain, CT logs make it visible.

A Signed Certificate Timestamp (SCT) proves that a certificate was submitted to a CT log. Modern browsers require SCTs — a certificate without them will show a warning.

```js
'use strict';

const tls = require('node:tls');

// Check if a server's certificate includes SCTs
function checkCertificateTransparency(hostname, port = 443) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect(
      { host: hostname, port, servername: hostname },
      () => {
        const cert = socket.getPeerCertificate(false);
        const protocol = socket.getProtocol();
        const cipher = socket.getCipher();

        // Check for CT-related extensions in the certificate
        const result = {
          hostname,
          protocol,
          cipher: cipher.name,
          subject: cert.subject?.CN,
          issuer: cert.issuer?.CN,
          validTo: cert.valid_to,
          serialNumber: cert.serialNumber,
          fingerprint256: cert.fingerprint256,
          // Node.js exposes raw certificate data
          // SCTs may be embedded in the certificate extension
          // or delivered via TLS extension or OCSP response
          hasInfoAccess: !!cert.infoAccess,
          infoAccess: cert.infoAccess || {},
        };

        socket.end();
        resolve(result);
      }
    );

    socket.on('error', reject);
  });
}

checkCertificateTransparency('nodejs.org').then(result => {
  console.log('Certificate Transparency Check:');
  console.log(JSON.stringify(result, null, 2));
}).catch(err => {
  console.error('Failed:', err.message);
});
```

---

## Certificate Pinning

Certificate pinning means the client remembers (pins) the server's certificate or public key and rejects connections that present a different one — even if the new certificate is signed by a trusted CA. This defends against compromised CAs.

**HPKP (HTTP Public Key Pinning)** was a browser mechanism for pinning. It was deprecated in 2018 because misconfiguration could permanently lock users out of a site. However, application-level pinning in Node.js clients remains a valid and powerful defense.

### Implementing Certificate Pinning in a Node.js Client

```js
'use strict';

const https = require('node:https');
const crypto = require('node:crypto');
const tls = require('node:tls');

// Pin the SHA-256 hash of the server's public key
// Obtain this by inspecting the certificate beforehand
const PINNED_KEYS = new Set([
  // Example: SHA-256 of the public key in DER format
  // Replace with actual pins for your target server
  'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
]);

function pinnedRequest(hostname, path) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      {
        hostname,
        path,
        port: 443,
        // Custom certificate verification
        checkServerIdentity: (host, cert) => {
          // First, perform standard hostname verification
          const err = tls.checkServerIdentity(host, cert);
          if (err) return err;

          // Then verify the pin
          // Extract the public key and hash it
          const pubkey = cert.pubkey;
          if (!pubkey) {
            return new Error('No public key in certificate');
          }

          const hash = crypto
            .createHash('sha256')
            .update(pubkey)
            .digest('base64');

          const pin = `sha256/${hash}`;

          if (!PINNED_KEYS.has(pin)) {
            return new Error(
              `Certificate pin mismatch!\n` +
              `  Expected one of: ${[...PINNED_KEYS].join(', ')}\n` +
              `  Got: ${pin}\n` +
              `  This may indicate a MITM attack.`
            );
          }

          console.log(`Pin verified: ${pin}`);
          return undefined; // Success
        },
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString(),
        }));
      }
    );

    req.on('error', reject);
  });
}
```

---

## DANE (DNS-Based Authentication of Named Entities)

DANE uses DNSSEC to publish certificate information in DNS TLSA records. Instead of relying on the CA trust model, the domain owner publishes the expected certificate hash in DNS:

```
_443._tcp.example.com.  IN  TLSA  3 1 1  <sha256-of-public-key>
```

DANE is not widely adopted on the web (browsers do not support it), but it is used in email (SMTP with DANE) and can be useful in server-to-server Node.js communication where you control both ends.

```js
'use strict';

const dns = require('node:dns');
const { promisify } = require('node:util');

const resolveTlsa = promisify(dns.resolve);

// DANE TLSA lookup (requires a DNS server that supports TLSA records)
// This demonstrates the concept — TLSA resolution depends on DNSSEC support
async function lookupDaneTlsa(hostname, port = 443) {
  const tlsaName = `_${port}._tcp.${hostname}`;
  console.log(`Looking up TLSA record: ${tlsaName}`);

  try {
    // dns.resolve with 'TLSA' type
    // Note: Not all DNS resolvers support TLSA queries
    const records = await resolveTlsa(tlsaName, 'TLSA');
    console.log('TLSA records found:', records);
    return records;
  } catch (err) {
    if (err.code === 'ENODATA' || err.code === 'ENOTFOUND') {
      console.log('No DANE TLSA record found for', hostname);
      console.log('This is expected — DANE adoption is limited');
    } else {
      console.error('DNS error:', err.message);
    }
    return null;
  }
}

lookupDaneTlsa('example.com');
```

---

## Verifying Peer Certificates Programmatically

When Node.js acts as a client, you can inspect the peer certificate at every level of detail:

```js
'use strict';

const tls = require('node:tls');
const crypto = require('node:crypto');

function detailedCertificateAudit(hostname, port = 443) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect(
      { host: hostname, port, servername: hostname, rejectUnauthorized: true },
      () => {
        const cert = socket.getPeerCertificate(true);
        const cipher = socket.getCipher();
        const protocol = socket.getProtocol();

        const audit = {
          connection: {
            protocol,
            cipher: cipher.name,
            cipherVersion: cipher.version,
            authorized: socket.authorized,
          },
          certificate: {
            subject: cert.subject,
            issuer: cert.issuer,
            validFrom: cert.valid_from,
            validTo: cert.valid_to,
            serialNumber: cert.serialNumber,
            fingerprint256: cert.fingerprint256,
            subjectAltName: cert.subjectaltname,
            keyUsage: cert.ext_key_usage || [],
          },
          checks: {},
        };

        // Check 1: Certificate is not expired
        const now = Date.now();
        const validFrom = new Date(cert.valid_from).getTime();
        const validTo = new Date(cert.valid_to).getTime();
        audit.checks.notExpired = now < validTo;
        audit.checks.alreadyValid = now >= validFrom;

        // Check 2: Certificate expires more than 30 days from now
        const thirtyDays = 30 * 24 * 60 * 60 * 1000;
        audit.checks.expiresInMoreThan30Days = (validTo - now) > thirtyDays;
        audit.checks.daysUntilExpiry = Math.floor((validTo - now) / (24 * 60 * 60 * 1000));

        // Check 3: Uses TLS 1.3
        audit.checks.usesTls13 = protocol === 'TLSv1.3';

        // Check 4: Uses strong cipher
        const strongCiphers = ['TLS_AES_256_GCM_SHA384', 'TLS_CHACHA20_POLY1305_SHA256'];
        audit.checks.strongCipher = strongCiphers.includes(cipher.name) ||
                                     cipher.name.includes('AES') && cipher.name.includes('GCM');

        // Check 5: Certificate has Subject Alternative Names (not just CN)
        audit.checks.hasSAN = !!cert.subjectaltname;

        // Check 6: Key size is adequate
        if (cert.bits) {
          audit.checks.keyBits = cert.bits;
          audit.checks.adequateKeySize = cert.bits >= 2048;
        }

        socket.end();
        resolve(audit);
      }
    );

    socket.on('error', reject);
  });
}

// Run the audit
detailedCertificateAudit('nodejs.org').then(audit => {
  console.log('\nTLS Certificate Audit for nodejs.org:');
  console.log('─'.repeat(50));

  console.log('\nConnection:');
  console.log(`  Protocol: ${audit.connection.protocol}`);
  console.log(`  Cipher:   ${audit.connection.cipher}`);
  console.log(`  Authorized: ${audit.connection.authorized}`);

  console.log('\nCertificate:');
  console.log(`  Subject: ${audit.certificate.subject?.CN}`);
  console.log(`  Issuer:  ${audit.certificate.issuer?.CN}`);
  console.log(`  Valid:    ${audit.certificate.validFrom} → ${audit.certificate.validTo}`);

  console.log('\nSecurity Checks:');
  for (const [check, result] of Object.entries(audit.checks)) {
    const icon = result === true ? 'PASS' :
                 result === false ? 'FAIL' :
                 String(result);
    console.log(`  ${check}: ${icon}`);
  }
}).catch(err => {
  console.error('Audit failed:', err.message);
});
```

---

## TLS Configuration Anti-Patterns

Avoid these common mistakes in Node.js TLS configuration:

```js
'use strict';

// ANTI-PATTERN 1: Disabling certificate verification
// This defeats the entire purpose of TLS authentication.
// NEVER do this in production.
//
// const options = { rejectUnauthorized: false };   // DO NOT
// process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';  // DO NOT

// ANTI-PATTERN 2: Using TLS 1.0 or 1.1
// Both are deprecated (RFC 8996). Attackers can exploit
// BEAST, POODLE, and CRIME attacks against older protocols.
//
// const options = { minVersion: 'TLSv1' };  // DO NOT

// ANTI-PATTERN 3: Allowing weak ciphers
// RC4, DES, 3DES, and export ciphers are broken.
//
// const options = { ciphers: 'ALL' };  // DO NOT — includes weak ciphers

// ANTI-PATTERN 4: Hardcoding a single cipher
// If that cipher is broken, you have no fallback.
//
// const options = { ciphers: 'TLS_AES_128_GCM_SHA256' };  // Too restrictive

// CORRECT: Secure defaults with flexibility
const secureDefaults = {
  minVersion: 'TLSv1.2',          // Accept TLS 1.2 and 1.3
  honorCipherOrder: true,          // Server picks the cipher
  ecdhCurve: 'X25519:P-256:P-384', // Modern curves
  // Node.js default ciphers are already strong for TLS 1.3
  // For TLS 1.2, explicitly list strong suites:
  ciphers: [
    'TLS_AES_256_GCM_SHA384',
    'TLS_CHACHA20_POLY1305_SHA256',
    'TLS_AES_128_GCM_SHA256',
    'ECDHE-ECDSA-AES256-GCM-SHA384',
    'ECDHE-RSA-AES256-GCM-SHA384',
    'ECDHE-ECDSA-CHACHA20-POLY1305',
    'ECDHE-RSA-CHACHA20-POLY1305',
    'ECDHE-ECDSA-AES128-GCM-SHA256',
    'ECDHE-RSA-AES128-GCM-SHA256',
  ].join(':'),
};

console.log('Secure TLS configuration ready');
console.log('Min version:', secureDefaults.minVersion);
console.log('Cipher count:', secureDefaults.ciphers.split(':').length);
```

---

## Self-Signed Certificates for Development

For testing, generate self-signed certificates using `node:crypto`:

```js
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// Generate a self-signed certificate using openssl
// (openssl is available on most systems where Node.js runs)
function generateSelfSignedCert(outputDir, hostname = 'localhost') {
  const keyPath = path.join(outputDir, 'server.key');
  const certPath = path.join(outputDir, 'server.crt');

  // Generate RSA private key
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:4096',
    '-keyout', keyPath,
    '-out', certPath,
    '-days', '365',
    '-nodes',
    '-subj', `/CN=${hostname}`,
    '-addext', `subjectAltName=DNS:${hostname},IP:127.0.0.1`,
  ]);

  console.log(`Generated self-signed certificate:`);
  console.log(`  Key:  ${keyPath}`);
  console.log(`  Cert: ${certPath}`);

  return { keyPath, certPath };
}

// Usage with https server
const https = require('node:https');

function startDevServer(certPath, keyPath, port = 3443) {
  const server = https.createServer(
    {
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
      minVersion: 'TLSv1.3',
    },
    (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        message: 'Secure connection established',
        protocol: req.socket.getProtocol?.() || 'unknown',
        cipher: req.socket.getCipher?.()?.name || 'unknown',
      }));
    }
  );

  server.listen(port, () => {
    console.log(`HTTPS server running on https://localhost:${port}`);
    console.log(`Test with: curl --cacert server.crt https://localhost:${port}`);
  });
}
```

---

## Key Takeaways

- TLS 1.3 completes the handshake in one round trip (1-RTT) and encrypts the certificate — always set `minVersion: 'TLSv1.2'` at minimum, and prefer TLS 1.3 where clients support it
- Certificate chains (root CA, intermediate, leaf) form a trust hierarchy — Node.js validates the entire chain against the system trust store, and `getPeerCertificate(true)` lets you inspect every link
- OCSP stapling eliminates the latency and privacy cost of clients checking certificate revocation directly with the CA — enable it via the `'OCSPRequest'` event on `tls.Server`
- Certificate pinning in Node.js clients (`checkServerIdentity` with public key hashing) defends against compromised CAs but requires careful key rotation planning
- Never set `rejectUnauthorized: false` in production, never use `NODE_TLS_REJECT_UNAUTHORIZED=0`, and never allow TLS versions below 1.2 — these anti-patterns undo every security guarantee TLS provides

## Next

In [Lesson 03 — Timing Attacks & Side Channels](lesson-03-timing-attacks.md), we examine a class of attack that bypasses encryption entirely. Even with perfect TLS, a server that compares secrets with `===` leaks information through timing differences — and we will prove it with measurements.
