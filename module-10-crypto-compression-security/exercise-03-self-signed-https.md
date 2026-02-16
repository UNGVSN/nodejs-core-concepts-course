# E03: Self-Signed HTTPS Server

## Objective

Create an HTTPS server using Node.js core modules. Generate an RSA key pair with `crypto.generateKeyPairSync()`, use the OpenSSL CLI to create a self-signed X.509 certificate from that key, and serve encrypted HTTPS traffic with `node:https`. This exercise teaches the full certificate lifecycle — key generation, certificate creation, server configuration, and client verification — without any npm dependencies.

## Prerequisites

- Module 10 / Lesson 04 — Asymmetric Encryption (RSA)
- Module 10 / Lesson 06 — Digital Signatures & Certificates
- Module 10 / Lesson 07 — TLS/HTTPS Implementation
- Module 07 — HTTP (basic HTTP server knowledge)

## Instructions

1. **Create two files:** `https-server.js` (the server) and `test-client.js` (the programmatic client). Add `'use strict';` to both. In `https-server.js`, require:

```javascript
'use strict';

const crypto = require('node:crypto');
const https  = require('node:https');
const fs     = require('node:fs');
const path   = require('node:path');
const { execSync } = require('node:child_process');
```

2. **Generate an RSA key pair.** Write a `generateKeyPair()` function that creates a 2048-bit RSA key pair and saves both PEM files to a `./certs/` directory:

```javascript
function generateKeyPair() {
  const certsDir = path.join(__dirname, 'certs');
  fs.mkdirSync(certsDir, { recursive: true });

  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding:  { type: 'pkcs1', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs1', format: 'pem' }
  });

  fs.writeFileSync(path.join(certsDir, 'server-key.pem'), privateKey);
  fs.writeFileSync(path.join(certsDir, 'server-pub.pem'), publicKey);
  return { publicKey, privateKey };
}
```

3. **Generate a self-signed certificate.** Use `child_process.execSync()` to run the OpenSSL CLI command. Document each flag:

```javascript
function generateCertificate() {
  const certsDir = path.join(__dirname, 'certs');
  const keyPath  = path.join(certsDir, 'server-key.pem');
  const certPath = path.join(certsDir, 'server-cert.pem');

  execSync([
    'openssl', 'req',
    '-new',                          // new certificate request
    '-x509',                         // self-signed (no CA needed)
    '-key', keyPath,                 // sign with this private key
    '-out', certPath,                // write certificate here
    '-days', '365',                  // valid for 1 year
    '-subj', '"/CN=localhost/O=NodeJS Course/C=US"',  // subject fields
    '-addext', '"subjectAltName=DNS:localhost,IP:127.0.0.1"'  // SAN for IP access
  ].join(' '));

  return certPath;
}
```

Explain: `-x509` makes it self-signed (no CSR/CA workflow), `-subj` sets the Common Name to `localhost`, and `-addext subjectAltName` adds alternate names for both DNS and IP access.

4. **Create the HTTPS server.** Load the private key and certificate, pass them as options to `https.createServer()`, and implement a simple router:

```javascript
const PORT = 3443;
const key  = fs.readFileSync(path.join(__dirname, 'certs', 'server-key.pem'));
const cert = fs.readFileSync(path.join(__dirname, 'certs', 'server-cert.pem'));

const server = https.createServer({ key, cert }, (req, res) => {
  // Security headers on every response
  res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Content-Security-Policy', "default-src 'self'");

  if (req.url === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Hello, HTTPS!\n');
  } else if (req.url === '/info') {
    // Return certificate and cipher details as JSON
  } else if (req.url === '/headers') {
    // Echo request headers as JSON
  } else {
    res.writeHead(404);
    res.end('Not Found\n');
  }
});
```

5. **Implement the `/info` route.** Return a JSON object with the server's certificate details. Access TLS information via `req.socket.getCipher()` for the negotiated cipher suite:

```javascript
const cipher = req.socket.getCipher();
const info = {
  subject:   { CN: 'localhost', O: 'NodeJS Course', C: 'US' },
  issuer:    { CN: 'localhost', O: 'NodeJS Course', C: 'US' },
  selfSigned: true,
  cipher:    cipher.name,
  protocol:  cipher.version
};
res.writeHead(200, { 'Content-Type': 'application/json' });
res.end(JSON.stringify(info, null, 2) + '\n');
```

6. **Listen on port 3443.** Print the server URL and cipher information on startup.

7. **Document the curl test commands.** Include these in comments or printed instructions:
   - `curl -k https://localhost:3443/` — `-k` skips cert verification (insecure, for testing only)
   - `curl --cacert ./certs/server-cert.pem https://localhost:3443/` — explicitly trust the self-signed cert
   - `curl https://localhost:3443/` — no flags, shows the `SSL certificate problem: self-signed certificate` error

8. **Write `test-client.js`.** Use `node:https` to make a GET request programmatically. Demonstrate two trust modes:

```javascript
'use strict';
const https = require('node:https');
const fs = require('node:fs');

// Option A: disable verification (not for production!)
// const options = { rejectUnauthorized: false };

// Option B: explicitly trust the self-signed cert
const options = {
  ca: fs.readFileSync('./certs/server-cert.pem'),
  hostname: 'localhost',
  port: 3443,
  path: '/',
  method: 'GET'
};

const req = https.request(options, (res) => {
  let body = '';
  res.on('data', (chunk) => { body += chunk; });
  res.on('end', () => {
    console.log(`Status: ${res.statusCode}`);
    console.log(`Body: ${body}`);
  });
});
req.on('error', (err) => console.error('Request failed:', err.message));
req.end();
```

9. **Display connection details.** In the server's request handler, log the cipher suite with `req.socket.getCipher()` and the TLS protocol version. On the `/info` route, include this in the JSON response.

10. **Add security headers.** Set these four headers on every response: `Strict-Transport-Security` (HSTS), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and `Content-Security-Policy: default-src 'self'`. Explain in comments what each header prevents.

## Break-Then-Harden Challenge

### Scenario 1 — Expired Certificate

Generate the certificate with `-days 0` (expired on creation). Start the server and connect with the test client using `ca` trust. Observe the `CERT_HAS_EXPIRED` error. Fix it by regenerating with `-days 365`. Document how certificate rotation works in production: monitor expiration, rotate before it expires, restart or hot-reload the server context.

### Scenario 2 — Key/Certificate Mismatch

Generate a new RSA key pair but keep the old certificate (which was signed with the previous key). Start the server and observe the `ERR_SSL_CERTIFICATE_VERIFY_FAILED` or TLS handshake failure. Fix it by always generating the certificate from the same private key that the server loads. Add a verification step that checks key-cert consistency before starting.

### Scenario 3 — Missing Subject Alternative Name

Remove the `-addext subjectAltName=...` from the OpenSSL command. Connect to `https://127.0.0.1:3443` instead of `https://localhost:3443`. Observe `ERR_TLS_CERT_ALTNAME_INVALID` because the certificate's CN is `localhost` but the client connected via IP. Fix it by always including SAN entries for both `DNS:localhost` and `IP:127.0.0.1`.

## Expected Output

```
$ node https-server.js

Generating RSA key pair (2048 bits)...
  Private key: ./certs/server-key.pem (1,704 bytes)
  Public key:  ./certs/server-pub.pem (451 bytes)

Generating self-signed certificate...
  Certificate: ./certs/server-cert.pem
  Subject:     CN=localhost, O=NodeJS Course, C=US
  SAN:         DNS:localhost, IP:127.0.0.1
  Valid:       2026-02-15 to 2027-02-15

HTTPS server listening on https://localhost:3443
Cipher: TLS_AES_256_GCM_SHA384 (TLSv1.3)

--- Test commands ---
  curl -k https://localhost:3443/
  curl -k https://localhost:3443/info
  curl --cacert ./certs/server-cert.pem https://localhost:3443/

--- Client test ---
$ node test-client.js
Status: 200
Body: Hello, HTTPS!
Certificate trusted: YES (via explicit CA)
Cipher: TLS_AES_256_GCM_SHA384
```

## Bonus

1. **Certificate hot-reload.** Watch the cert files with `fs.watchFile()`. When a new certificate is detected, call `server.setSecureContext({ key: newKey, cert: newCert })` to update the TLS context without restarting the server. Test by generating a new certificate while the server is running and verifying the client sees the new certificate details.

2. **Mutual TLS (mTLS).** Generate a separate client key pair and certificate. Configure the server with `requestCert: true, rejectUnauthorized: true, ca: [clientCACert]`. The client must present its certificate via `{ key: clientKey, cert: clientCert }` in the request options. Reject connections from clients without valid certificates.

## Hints

1. `crypto.generateKeyPairSync('rsa', options)` returns `{ publicKey, privateKey }` as PEM-encoded strings when you specify `format: 'pem'` in the encoding options.

2. The OpenSSL `-subj` flag sets certificate fields without interactive prompts. `/CN=localhost` is the Common Name that must match the hostname clients use. `/O=` is the Organization, `/C=` is the Country code.

3. `https.createServer({ key, cert }, handler)` is the TLS equivalent of `http.createServer(handler)`. The `key` is the private key PEM string and `cert` is the certificate PEM string.

4. `curl -k` (or `--insecure`) disables certificate verification entirely. In production, always configure proper trust — either a real CA or an explicit `--cacert` for internal services.

5. Self-signed certificates are not trusted by default because no Certificate Authority vouches for their identity. In development, explicitly trust them via the `ca` option. In production, use certificates from a real CA (e.g., Let's Encrypt, which is free and automated).
