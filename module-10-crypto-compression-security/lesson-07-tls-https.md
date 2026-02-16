# Module 10 / Lesson 07 — TLS/HTTPS Implementation

> Every time you visit a website with a padlock icon, TLS is doing the heavy lifting — negotiating ciphers, exchanging keys, and encrypting every byte. Understanding TLS at the Node.js level means you can build secure servers, debug certificate errors that stump your team, and implement mutual authentication between services.

## Learning Objectives

- Explain the TLS handshake process and the differences between TLS 1.2 and TLS 1.3
- Create TLS servers and clients using the `node:tls` module
- Build HTTPS servers with proper certificate configuration using `node:https`
- Implement mutual TLS (mTLS) for client certificate authentication
- Diagnose and fix common TLS errors in Node.js applications

---

## What TLS Does

TLS (Transport Layer Security) sits between the application layer (HTTP) and the transport layer (TCP). It provides three guarantees:

| Guarantee | Mechanism | What It Prevents |
|---|---|---|
| **Confidentiality** | Symmetric encryption (AES) | Eavesdropping |
| **Integrity** | HMAC / AEAD | Message tampering |
| **Authentication** | X.509 certificates | Impersonation |

When TLS wraps HTTP, we call it HTTPS. But TLS can wrap *any* TCP protocol — databases, message queues, custom protocols.

## The TLS Handshake

### TLS 1.2 Handshake (2 round trips)

```
Client                                Server
  │                                     │
  │──── ClientHello ──────────────────►│  Supported versions, ciphers, random
  │                                     │
  │◄──── ServerHello ─────────────────│  Chosen version, cipher, random
  │◄──── Certificate ─────────────────│  Server's X.509 cert
  │◄──── ServerKeyExchange ───────────│  DH parameters (if applicable)
  │◄──── ServerHelloDone ─────────────│
  │                                     │
  │──── ClientKeyExchange ────────────►│  Pre-master secret (encrypted)
  │──── ChangeCipherSpec ─────────────►│  "Switching to encrypted mode"
  │──── Finished ─────────────────────►│  Encrypted verification
  │                                     │
  │◄──── ChangeCipherSpec ────────────│
  │◄──── Finished ────────────────────│
  │                                     │
  │◄════ Encrypted Application Data ══►│
```

### TLS 1.3 Handshake (1 round trip)

```
Client                                Server
  │                                     │
  │──── ClientHello + KeyShare ───────►│  Includes DH key share upfront
  │                                     │
  │◄──── ServerHello + KeyShare ──────│  Server's DH share
  │◄──── EncryptedExtensions ─────────│  Already encrypted!
  │◄──── Certificate ─────────────────│
  │◄──── CertificateVerify ──────────│
  │◄──── Finished ────────────────────│
  │                                     │
  │──── Finished ─────────────────────►│
  │                                     │
  │◄════ Encrypted Application Data ══►│
```

### TLS 1.2 vs TLS 1.3

| Feature | TLS 1.2 | TLS 1.3 |
|---|---|---|
| Round trips | 2 | 1 (+ 0-RTT resumption) |
| RSA key exchange | Supported | **Removed** |
| Perfect Forward Secrecy | Optional | **Mandatory** |
| Cipher suites | ~40+ options | 5 options |
| CBC mode ciphers | Supported | **Removed** |
| 0-RTT resumption | No | Yes (with replay risk) |
| Handshake encryption | Partial | Full (after ServerHello) |

**Node.js default:** TLS 1.2 minimum, TLS 1.3 preferred. You can adjust with `minVersion` and `maxVersion`.

## The `node:tls` Module

The `tls` module provides TLS/SSL encrypted stream communication built on top of `node:net`.

### Creating a TLS Server

```js
'use strict';

const tls = require('node:tls');
const fs = require('node:fs');
const path = require('node:path');

// Load certificate and private key
// Generate these with:
//   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
//     -days 365 -nodes -subj '/CN=localhost'
const options = {
  key:  fs.readFileSync(path.join(__dirname, 'key.pem')),
  cert: fs.readFileSync(path.join(__dirname, 'cert.pem')),

  // TLS version constraints
  minVersion: 'TLSv1.2',
  maxVersion: 'TLSv1.3',
};

const server = tls.createServer(options, (socket) => {
  console.log('Client connected:', {
    authorized: socket.authorized,
    protocol:   socket.getProtocol(),
    cipher:     socket.getCipher().name,
    remoteAddr: socket.remoteAddress,
  });

  socket.write('Welcome to the secure server!\n');

  socket.on('data', (data) => {
    console.log('Received:', data.toString().trim());
    socket.write(`Echo: ${data}`);
  });

  socket.on('end', () => {
    console.log('Client disconnected');
  });
});

server.listen(8443, () => {
  console.log('TLS server listening on port 8443');
});

server.on('tlsClientError', (err, tlsSocket) => {
  console.error('TLS client error:', err.message);
});
```

### TLS Server Options Reference

| Option | Type | Purpose |
|---|---|---|
| `key` | `string \| Buffer` | Private key in PEM format |
| `cert` | `string \| Buffer` | Certificate in PEM format |
| `ca` | `string \| Buffer \| Array` | CA certificates for client verification |
| `passphrase` | `string` | Passphrase for the private key |
| `minVersion` | `string` | Minimum TLS version (`'TLSv1.2'`, `'TLSv1.3'`) |
| `maxVersion` | `string` | Maximum TLS version |
| `ciphers` | `string` | OpenSSL cipher list string |
| `requestCert` | `boolean` | Request client certificate (for mTLS) |
| `rejectUnauthorized` | `boolean` | Reject clients without valid certs |
| `SNICallback` | `function` | Callback for Server Name Indication |

### Creating a TLS Client

```js
'use strict';

const tls = require('node:tls');
const fs = require('node:fs');
const path = require('node:path');

const options = {
  host: 'localhost',
  port: 8443,

  // For self-signed certs, provide the CA that signed them
  ca: fs.readFileSync(path.join(__dirname, 'cert.pem')),

  // Alternatively (development only):
  // rejectUnauthorized: false,

  // Check the server's hostname matches the certificate
  checkServerIdentity: (hostname, cert) => {
    // Custom validation logic (or return undefined to accept)
    console.log('Server cert subject:', cert.subject.CN);
    // Return an error to reject, or undefined to accept
    return undefined;
  },
};

const socket = tls.connect(options, () => {
  console.log('Connected to server:', {
    authorized: socket.authorized,
    protocol:   socket.getProtocol(),
    cipher:     socket.getCipher().name,
  });

  socket.write('Hello from the TLS client!\n');
});

socket.on('data', (data) => {
  console.log('Server says:', data.toString().trim());
});

socket.on('end', () => {
  console.log('Connection ended');
});

socket.on('error', (err) => {
  console.error('TLS error:', err.message);
});
```

### `tls.TLSSocket` Properties and Methods

| Member | Returns | Purpose |
|---|---|---|
| `.authorized` | `boolean` | Whether the peer certificate was verified by a CA |
| `.authorizationError` | `Error \| null` | The reason authorization failed |
| `.getProtocol()` | `string` | `'TLSv1.2'` or `'TLSv1.3'` |
| `.getCipher()` | `object` | `{ name, standardName, version }` |
| `.getPeerCertificate()` | `object` | Peer's certificate details |
| `.getPeerX509Certificate()` | `X509Certificate` | Full X509Certificate object |
| `.getEphemeralKeyInfo()` | `object` | Ephemeral key exchange details |
| `.encrypted` | `boolean` | Always `true` for TLS sockets |

## HTTPS Servers with `node:https`

The `https` module is the most common way to use TLS in Node.js. It wraps `http.createServer` with TLS.

```js
'use strict';

const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');

const options = {
  key:  fs.readFileSync(path.join(__dirname, 'key.pem')),
  cert: fs.readFileSync(path.join(__dirname, 'cert.pem')),
  minVersion: 'TLSv1.2',
};

const server = https.createServer(options, (req, res) => {
  // req and res work exactly like http.IncomingMessage / http.ServerResponse
  const info = {
    method:   req.method,
    url:      req.url,
    protocol: req.socket.getProtocol(),
    cipher:   req.socket.getCipher().name,
  };

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(info, null, 2));
});

server.listen(8443, () => {
  console.log('HTTPS server running at https://localhost:8443');
});
```

### Generating Self-Signed Certificates for Development

You need a private key and a certificate. Use `openssl` on the command line:

```bash
# Generate a self-signed certificate (valid for 365 days)
openssl req -x509 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
```

The flags explained:

| Flag | Purpose |
|---|---|
| `-x509` | Generate a self-signed certificate (not a CSR) |
| `-newkey rsa:2048` | Generate a new 2048-bit RSA key |
| `-keyout key.pem` | Write the private key to `key.pem` |
| `-out cert.pem` | Write the certificate to `cert.pem` |
| `-days 365` | Certificate validity period |
| `-nodes` | No passphrase on the private key |
| `-subj '/CN=localhost'` | Set the Common Name |
| `-addext 'subjectAltName=...'` | Add Subject Alternative Names |

### Loading Certificates Safely

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function loadCertificates(certDir) {
  const keyPath  = path.join(certDir, 'key.pem');
  const certPath = path.join(certDir, 'cert.pem');
  const caPath   = path.join(certDir, 'ca.pem');

  // Validate files exist before loading
  for (const filePath of [keyPath, certPath]) {
    if (!fs.existsSync(filePath)) {
      throw new Error(`Missing certificate file: ${filePath}`);
    }
  }

  const result = {
    key:  fs.readFileSync(keyPath),
    cert: fs.readFileSync(certPath),
  };

  // CA is optional (for self-signed certs in development)
  if (fs.existsSync(caPath)) {
    result.ca = fs.readFileSync(caPath);
  }

  return result;
}

// Usage:
// const certs = loadCertificates('/etc/myapp/certs');
// const server = https.createServer(certs, handler);
```

## Mutual TLS (mTLS)

In standard TLS, only the server presents a certificate. In mutual TLS, *both* sides authenticate — the client also presents a certificate that the server verifies.

```
Standard TLS:     Client ──── verifies ────► Server cert
Mutual TLS:       Client cert ◄── verifies ──► Server cert
```

### mTLS Server

```js
'use strict';

const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');

const certDir = path.join(__dirname, 'certs');

const server = https.createServer({
  key:  fs.readFileSync(path.join(certDir, 'server-key.pem')),
  cert: fs.readFileSync(path.join(certDir, 'server-cert.pem')),

  // mTLS configuration
  requestCert:       true,  // Ask the client for a certificate
  rejectUnauthorized: true, // Reject clients without valid certs

  // The CA that signed the client certificates
  ca: fs.readFileSync(path.join(certDir, 'client-ca.pem')),

}, (req, res) => {
  const clientCert = req.socket.getPeerCertificate();

  if (!req.socket.authorized) {
    res.writeHead(401);
    res.end('Client certificate not authorized');
    return;
  }

  const clientInfo = {
    subject:     clientCert.subject.CN,
    issuer:      clientCert.issuer.CN,
    fingerprint: clientCert.fingerprint256,
    valid:       req.socket.authorized,
  };

  console.log('Authenticated client:', clientInfo.subject);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    message: `Hello, ${clientInfo.subject}!`,
    client:  clientInfo,
  }, null, 2));
});

server.listen(8443, () => {
  console.log('mTLS server running on https://localhost:8443');
});
```

### mTLS Client

```js
'use strict';

const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');

const certDir = path.join(__dirname, 'certs');

const options = {
  hostname: 'localhost',
  port:     8443,
  path:     '/',
  method:   'GET',

  // Client certificate for mTLS
  key:  fs.readFileSync(path.join(certDir, 'client-key.pem')),
  cert: fs.readFileSync(path.join(certDir, 'client-cert.pem')),

  // Trust the server's CA
  ca: fs.readFileSync(path.join(certDir, 'server-ca.pem')),
};

const req = https.request(options, (res) => {
  let body = '';
  res.on('data', (chunk) => { body += chunk; });
  res.on('end', () => {
    console.log('Status:', res.statusCode);
    console.log('Response:', body);
  });
});

req.on('error', (err) => {
  console.error('Request failed:', err.message);
});

req.end();
```

## SNI — Server Name Indication

SNI allows one server to present different certificates for different hostnames. This is how shared hosting works — one IP address serves `site-a.com` and `site-b.com` with different certificates.

```js
'use strict';

const tls = require('node:tls');
const fs = require('node:fs');
const path = require('node:path');

// Load certificates for each domain
const certs = {
  'api.example.com': {
    key:  fs.readFileSync(path.join(__dirname, 'certs', 'api-key.pem')),
    cert: fs.readFileSync(path.join(__dirname, 'certs', 'api-cert.pem')),
  },
  'app.example.com': {
    key:  fs.readFileSync(path.join(__dirname, 'certs', 'app-key.pem')),
    cert: fs.readFileSync(path.join(__dirname, 'certs', 'app-cert.pem')),
  },
};

const server = tls.createServer({
  // Default certificate (fallback)
  key:  certs['api.example.com'].key,
  cert: certs['api.example.com'].cert,

  SNICallback: (servername, callback) => {
    const domainCerts = certs[servername];

    if (!domainCerts) {
      console.warn(`No certificate for: ${servername}`);
      callback(new Error(`Unknown server name: ${servername}`));
      return;
    }

    const ctx = tls.createSecureContext({
      key:  domainCerts.key,
      cert: domainCerts.cert,
    });

    callback(null, ctx);
  },
}, (socket) => {
  console.log('SNI hostname:', socket.servername);
  socket.write(`Connected to ${socket.servername}\n`);
  socket.end();
});

server.listen(8443, () => {
  console.log('SNI-enabled TLS server on port 8443');
});
```

## Common TLS Errors

Every Node.js developer encounters these errors. Here is what they mean and how to fix them:

```js
'use strict';

// This code demonstrates handling common TLS errors

const https = require('node:https');
const fs = require('node:fs');

// Error: UNABLE_TO_VERIFY_LEAF_SIGNATURE
// Cause: The server's certificate was signed by a CA that is not
//        in Node's trust store.
// Fix:   Provide the CA certificate in the `ca` option.
//
// https.request({
//   ca: fs.readFileSync('custom-ca.pem'),
//   ...
// });

// Error: CERT_HAS_EXPIRED
// Cause: The server's certificate has passed its validTo date.
// Fix:   Renew the certificate on the server.

// Error: ERR_TLS_CERT_ALTNAME_INVALID
// Cause: The hostname you are connecting to does not match the
//        certificate's Subject Alternative Name (SAN) list.
// Fix:   Ensure the cert includes the correct hostname in SAN.
//        When generating: -addext 'subjectAltName=DNS:your-hostname'

// Error: DEPTH_ZERO_SELF_SIGNED_CERT
// Cause: The server uses a self-signed certificate.
// Fix:   Add the self-signed cert as the `ca` option.

// Error: SELF_SIGNED_CERT_IN_CHAIN
// Cause: An intermediate CA in the chain is self-signed and not trusted.
// Fix:   Add the root CA to the `ca` option.

function diagnoseError(err) {
  const fixes = {
    UNABLE_TO_VERIFY_LEAF_SIGNATURE:
      'Provide the CA cert: { ca: fs.readFileSync("ca.pem") }',
    CERT_HAS_EXPIRED:
      'Renew the server certificate',
    ERR_TLS_CERT_ALTNAME_INVALID:
      'Regenerate cert with correct SAN: -addext "subjectAltName=DNS:hostname"',
    DEPTH_ZERO_SELF_SIGNED_CERT:
      'Add self-signed cert as CA: { ca: fs.readFileSync("cert.pem") }',
    SELF_SIGNED_CERT_IN_CHAIN:
      'Add root CA to trusted list: { ca: fs.readFileSync("root-ca.pem") }',
  };

  const fix = fixes[err.code] || 'Check the certificate configuration';
  console.error(`TLS Error: ${err.code}`);
  console.error(`Fix: ${fix}`);
}
```

## The `NODE_TLS_REJECT_UNAUTHORIZED` Trap

```js
'use strict';

// NEVER DO THIS IN PRODUCTION:
// process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

// Why it is dangerous:
// 1. Disables ALL certificate verification for the ENTIRE process
// 2. Any HTTPS request — to your API, to payment providers, to auth
//    services — will accept ANY certificate, including attacker-issued ones
// 3. It is a global setting — you cannot scope it to one connection
// 4. Man-in-the-middle attacks become trivial

// What to do instead:
// - For self-signed certs: pass `ca` option with the cert
// - For testing: use a test CA and trust it explicitly
// - For development: generate proper self-signed certs with SAN

// The ONLY acceptable use:
// - Throwaway scripts that will never touch production
// - And even then, prefer the `ca` option
```

## Redirecting HTTP to HTTPS

A production pattern: run both HTTP and HTTPS, redirecting all HTTP traffic to HTTPS.

```js
'use strict';

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');

const certDir = path.join(__dirname, 'certs');

// HTTPS server (the real server)
const httpsServer = https.createServer({
  key:  fs.readFileSync(path.join(certDir, 'key.pem')),
  cert: fs.readFileSync(path.join(certDir, 'cert.pem')),
}, (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/plain',
    'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  });
  res.end('Secure connection established.\n');
});

// HTTP server (redirect only)
const httpServer = http.createServer((req, res) => {
  const host = req.headers.host || 'localhost';
  const redirectUrl = `https://${host}${req.url}`;

  res.writeHead(301, {
    Location: redirectUrl,
  });
  res.end(`Redirecting to ${redirectUrl}\n`);
});

httpsServer.listen(443, () => {
  console.log('HTTPS server on port 443');
});

httpServer.listen(80, () => {
  console.log('HTTP redirect server on port 80');
});
```

## Inspecting a TLS Connection Programmatically

```js
'use strict';

const tls = require('node:tls');

function inspectTLSConnection(host, port = 443) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host, port, servername: host }, () => {
      const cert = socket.getPeerX509Certificate();
      const cipher = socket.getCipher();

      const info = {
        host,
        protocol:    socket.getProtocol(),
        cipher:      cipher.name,
        cipherStd:   cipher.standardName,
        authorized:  socket.authorized,
        subject:     cert.subject,
        issuer:      cert.issuer,
        validFrom:   cert.validFrom,
        validTo:     cert.validTo,
        fingerprint: cert.fingerprint256,
        serialNumber: cert.serialNumber,
      };

      socket.end();
      resolve(info);
    });

    socket.on('error', reject);
    socket.setTimeout(5000, () => {
      socket.destroy(new Error('Connection timeout'));
    });
  });
}

// Usage:
// inspectTLSConnection('example.com').then(console.log);
```

## Key Takeaways

- TLS provides confidentiality, integrity, and authentication — it is the protocol that turns HTTP into HTTPS
- TLS 1.3 is faster (1 round trip vs 2), more secure (mandatory PFS, no RSA key exchange), and simpler (5 cipher suites vs 40+) than TLS 1.2
- Use `node:https` for standard HTTPS servers and clients; use `node:tls` when you need lower-level control over TLS sockets
- Mutual TLS (mTLS) authenticates both client and server — set `requestCert: true` and provide a `ca` option with the client CA
- Never set `NODE_TLS_REJECT_UNAUTHORIZED=0` in production — instead, provide the correct CA certificate via the `ca` option

## Next

Continue to [Lesson 08 — Zlib Compression](lesson-08-zlib-compression.md), where we explore compressing and decompressing data with Gzip, Deflate, and Brotli using the `node:zlib` module.
