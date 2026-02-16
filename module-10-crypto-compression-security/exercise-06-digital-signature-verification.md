# E06: Digital Signature Verification

## Objective

Build a file signing and verification system using RSA-SHA256 digital signatures. The signer generates an RSA key pair, computes a signature over a file's contents with the private key, and saves the detached signature to a separate file. The verifier loads the public key and signature, checks the file's integrity, and reports whether the file is authentic and untampered. This is the exact mechanism behind npm package integrity, Linux package managers (apt, rpm), code signing, and software update systems.

## Prerequisites

- Module 10 / Lesson 04 — Asymmetric Encryption (RSA)
- Module 10 / Lesson 06 — Digital Signatures & Certificates
- Module 10 / Lesson 02 — Hashing (SHA, MD5, HMAC)

## Instructions

1. **Create `digital-signer.js`** with `'use strict';` at the top. Require:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs     = require('node:fs');
const path   = require('node:path');
const { performance } = require('node:perf_hooks');
```

2. **Implement key pair generation.** Write a `generateKeys(outputDir)` function that creates a 2048-bit RSA key pair using standard PEM formats:

```javascript
function generateKeys(outputDir = './keys') {
  fs.mkdirSync(outputDir, { recursive: true });

  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding:  { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });

  const privPath = path.join(outputDir, 'private-key.pem');
  const pubPath  = path.join(outputDir, 'public-key.pem');
  fs.writeFileSync(privPath, privateKey);
  fs.writeFileSync(pubPath, publicKey);

  return { privPath, pubPath, privateKey, publicKey };
}
```

Use `spki` for the public key and `pkcs8` for the private key — these are the standard formats that `crypto.createSign()` and `crypto.createVerify()` expect.

3. **Implement file signing.** Write a `signFile(filePath, privateKeyPath)` function that:
   - Reads the file contents as a Buffer with `fs.readFileSync(filePath)`
   - Reads the private key PEM with `fs.readFileSync(privateKeyPath, 'utf8')`
   - Creates a signer with `crypto.createSign('RSA-SHA256')`
   - Feeds the file contents to the signer with `.update(fileContents)`
   - Produces the signature with `.sign(privateKey, 'hex')`
   - Writes the hex-encoded signature to `<filePath>.sig`
   - Creates a manifest JSON file at `<filePath>.manifest.json`

```javascript
function signFile(filePath, privateKeyPath) {
  const fileContents = fs.readFileSync(filePath);
  const privateKey = fs.readFileSync(privateKeyPath, 'utf8');

  const signer = crypto.createSign('RSA-SHA256');
  signer.update(fileContents);
  const signature = signer.sign(privateKey, 'hex');

  const sigPath = filePath + '.sig';
  fs.writeFileSync(sigPath, signature);

  // Also compute SHA-256 hash for the manifest
  const hash = crypto.createHash('sha256').update(fileContents).digest('hex');

  const manifest = {
    file: path.basename(filePath),
    size: fileContents.length,
    sha256: hash,
    signatureFile: path.basename(sigPath),
    algorithm: 'RSA-SHA256',
    keySize: 2048,
    timestamp: new Date().toISOString()
  };
  fs.writeFileSync(filePath + '.manifest.json', JSON.stringify(manifest, null, 2));

  return { sigPath, signature, hash, manifest };
}
```

4. **Implement file verification.** Write a `verifyFile(filePath, signaturePath, publicKeyPath)` function that:
   - Reads the file contents, the hex-encoded signature string, and the public key PEM
   - Creates a verifier with `crypto.createVerify('RSA-SHA256')`
   - Updates with the file contents
   - Returns the boolean result of `verifier.verify(publicKey, signature, 'hex')`

```javascript
function verifyFile(filePath, signaturePath, publicKeyPath) {
  const fileContents = fs.readFileSync(filePath);
  const signature    = fs.readFileSync(signaturePath, 'utf8');
  const publicKey    = fs.readFileSync(publicKeyPath, 'utf8');

  const verifier = crypto.createVerify('RSA-SHA256');
  verifier.update(fileContents);
  return verifier.verify(publicKey, signature, 'hex');
}
```

5. **Build the CLI interface** with four commands:
   - `node digital-signer.js keygen [--dir ./keys]` — generate a new RSA key pair
   - `node digital-signer.js sign <file> --key <private-key-path>` — sign a file
   - `node digital-signer.js verify <file> --sig <signature-path> --key <public-key-path>` — verify a file
   - `node digital-signer.js check <file>` — convenience command that auto-detects `<file>.sig` and `./keys/public-key.pem`

   Parse `process.argv` to dispatch to the correct function. Print usage and exit with code 1 on invalid input.

6. **Demonstrate tamper detection.** In the demo section of the script (when no CLI arguments or `--demo` is passed):
   - Create a test file: `fs.writeFileSync('document.txt', 'This document is authentic and unmodified.')`
   - Generate keys, sign the file, verify it (should print VALID)
   - Modify one byte: `fs.appendFileSync('document.txt', '!')`
   - Verify again (should print INVALID)
   - Restore the original content, verify again (should print VALID)

7. **Sign multiple files.** Write a `signDirectory(dirPath, privateKeyPath, pattern)` function that reads all files matching a simple extension filter (e.g., all `.js` files) using `fs.readdirSync()` with a filter. Sign each file individually. Generate a combined manifest (`signatures.json`) listing all files with their individual signatures, hashes, and timestamps.

8. **Benchmark key size impact.** Generate RSA key pairs at 1024, 2048, and 4096-bit modulus lengths. For each, time three operations: key generation, signing a 1 KB file, and verifying the signature. Print a comparison table:

```javascript
const keySizes = [1024, 2048, 4096];
for (const bits of keySizes) {
  const start = performance.now();
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: bits,
    publicKeyEncoding:  { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  const keygenTime = performance.now() - start;
  // Sign and verify with each key size, measure times...
}
```

## Break-Then-Harden Challenge

### Scenario 1 — Wrong Key Pair

Generate two separate key pairs (A and B). Sign a file with private key A. Attempt to verify with public key B. Observe that `verifier.verify()` returns `false` — the signature is mathematically bound to key pair A. Display the error message: "Signature verification FAILED — file was signed with a different key." This proves that possession of the correct public key is essential for trust.

### Scenario 2 — Algorithm Mismatch

Sign a file with `'RSA-SHA256'` but verify with `'RSA-SHA512'`. Observe that `verify()` returns `false` even though the file is untampered — the verification recomputes the hash with SHA-512, which does not match the SHA-256 hash that was signed. Fix it by storing the algorithm in the manifest and using it during verification: `const algorithm = manifest.algorithm; const verifier = crypto.createVerify(algorithm);`.

### Scenario 3 — Signing the Hash Instead of the Content

Pre-hash the file with `crypto.createHash('sha256')` and pass the hash digest (not the original content) to `signer.update()`. This double-hashes because `createSign('RSA-SHA256')` internally computes SHA-256 before signing. The resulting signature is valid only for the hash, not for the original file. A verifier using the original file content will get `false`. Fix it by always passing raw file contents to `createSign` — never pre-hash.

## Expected Output

```
$ node digital-signer.js keygen --dir ./keys
Generating RSA key pair (2048-bit)...
  Key generation time: 187.4 ms
  Private key: ./keys/private-key.pem (1,704 bytes)
  Public key:  ./keys/public-key.pem  (451 bytes)

$ echo "This document is authentic and unmodified." > document.txt

$ node digital-signer.js sign document.txt --key ./keys/private-key.pem
Signing: document.txt (44 bytes)
  Algorithm:  RSA-SHA256
  SHA-256:    b4f9c2a1d7e83f06...
  Sign time:  1.2 ms
  Signature:  document.txt.sig (512 hex chars / 256 bytes)
  Manifest:   document.txt.manifest.json
File signed successfully.

$ node digital-signer.js verify document.txt --sig document.txt.sig --key ./keys/public-key.pem
Verifying: document.txt
  Signature:  document.txt.sig
  Public key: ./keys/public-key.pem
  Verify time: 0.2 ms
  Result:     VALID — file is authentic and untampered.

$ echo "tampered content" >> document.txt

$ node digital-signer.js verify document.txt --sig document.txt.sig --key ./keys/public-key.pem
Verifying: document.txt
  Signature:  document.txt.sig
  Public key: ./keys/public-key.pem
  Verify time: 0.2 ms
  Result:     INVALID — file has been modified or signature was forged!

--- Key Size Benchmark (1 KB file) ---
Key Size  | Keygen     | Sign     | Verify   | Sig Size
----------|------------|----------|----------|----------
1024-bit  |   38.2 ms  |  0.4 ms  |  0.1 ms  | 128 bytes
2048-bit  |  187.4 ms  |  1.2 ms  |  0.2 ms  | 256 bytes
4096-bit  | 1247.8 ms  |  4.7 ms  |  0.4 ms  | 512 bytes
```

## Bonus

1. **Timestamped signatures.** Concatenate the file contents with a precise ISO timestamp before signing: `signer.update(fileContents); signer.update(timestamp);`. Store the timestamp in the manifest. The verifier must read the timestamp from the manifest and include it in verification. This creates a basic proof that the file existed in its current form at a specific time.

2. **Chain of trust.** Generate a "CA" key pair and a "developer" key pair. Sign the developer's public key PEM file with the CA's private key (creating a certificate of authenticity). When verifying a file: first verify the developer's public key against the CA's signature (using the CA's public key), then verify the file against the developer's key. If either check fails, reject. This is a two-level certificate chain — the foundation of PKI.

## Hints

1. `crypto.createSign('RSA-SHA256')` creates a signing stream. Call `.update(data)` with the file contents (as a Buffer or string), then `.sign(privateKey, 'hex')` to produce the hex-encoded signature string.

2. `crypto.createVerify('RSA-SHA256')` creates a verification stream. Call `.update(data)` with the same file contents, then `.verify(publicKey, signature, 'hex')` which returns `true` or `false`.

3. Use `'spki'` (Subject Public Key Info) format for public keys and `'pkcs8'` for private keys — these are the standard PEM formats. Using `'pkcs1'` also works but `spki`/`pkcs8` are the modern defaults.

4. A digital signature does not encrypt the file — anyone can read the original content. It only proves (a) who signed it (authentication) and (b) that the content has not changed since signing (integrity). Only the private key holder can produce a valid signature, but anyone with the public key can verify one.

5. The signature size is determined by the RSA modulus length, not the file size. A 2048-bit key always produces a 256-byte (512 hex character) signature, whether the file is 1 byte or 1 GB. The internal SHA-256 hash reduces any file to a fixed 32-byte digest before the RSA operation.
