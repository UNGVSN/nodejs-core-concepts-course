# E02: File Encryptor/Decryptor

## Objective

Build a streaming file encryption and decryption tool using AES-256-GCM. The encryptor derives an encryption key from a user-provided password using `crypto.scrypt()`, generates a random IV, and pipes the input file through a cipher stream. The encrypted file format prepends the salt, IV, and authentication tag as a fixed-size header. The decryptor reads the header, derives the same key, and streams through a decipher. This handles files of any size without loading them entirely into memory.

## Prerequisites

- Module 10 / Lesson 01 — Cryptography Fundamentals
- Module 10 / Lesson 03 — Symmetric Encryption (AES)
- Module 05 / Lesson 03 — Readable and Writable Streams (or basic familiarity with `stream.pipeline`)

## Instructions

1. **Create `file-encryptor.js`** with `'use strict';` at the top. Require:

```javascript
'use strict';

const crypto    = require('node:crypto');
const fs        = require('node:fs');
const path      = require('node:path');
const { pipeline } = require('node:stream/promises');
const { performance } = require('node:perf_hooks');
```

2. **Define the encrypted file format.** Document the binary layout with constants:

```javascript
const ALGORITHM   = 'aes-256-gcm';
const SALT_LEN    = 32;   // bytes 0-31:  salt for scrypt key derivation
const IV_LEN      = 12;   // bytes 32-43: initialization vector (nonce)
const TAG_LEN     = 16;   // bytes 44-59: GCM authentication tag
const HEADER_LEN  = SALT_LEN + IV_LEN + TAG_LEN;  // 60 bytes total
const KEY_LEN     = 32;   // 256-bit AES key
```

The file layout is: `[salt 32B][iv 12B][tag 16B][ciphertext...]`. The tag is written after encryption completes by seeking back to byte 44.

3. **Implement `deriveKey(password, salt)`** that wraps `crypto.scrypt()` in a Promise:

```javascript
function deriveKey(password, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, KEY_LEN, { N: 16384, r: 8, p: 1 }, (err, key) => {
      err ? reject(err) : resolve(key);
    });
  });
}
```

4. **Implement `encrypt(inputPath, outputPath, password)`.** This function:
   - Generates a 32-byte random salt and a 12-byte random IV
   - Derives the AES key from password + salt
   - Opens the output file and writes 60 bytes of header: salt (32B) + IV (12B) + placeholder zeros for tag (16B)
   - Creates a cipher with `crypto.createCipheriv(ALGORITHM, key, iv)`
   - Streams the input file through the cipher into the output file (starting at byte 60)
   - After the pipeline completes, reads the auth tag with `cipher.getAuthTag()` and writes it to bytes 44-59 of the output file using `fs.writeSync` with a file descriptor at offset 44
   - Returns metadata: `{ salt, iv, tag, inputSize, outputSize, elapsed }`

```javascript
async function encrypt(inputPath, outputPath, password) {
  const salt = crypto.randomBytes(SALT_LEN);
  const iv   = crypto.randomBytes(IV_LEN);
  const key  = await deriveKey(password, salt);

  const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
  const header = Buffer.alloc(HEADER_LEN);
  salt.copy(header, 0);
  iv.copy(header, SALT_LEN);
  // Tag placeholder at offset SALT_LEN + IV_LEN (zeros for now)

  // Write header, then stream ciphertext
  const fd = fs.openSync(outputPath, 'w');
  fs.writeSync(fd, header, 0, HEADER_LEN, 0);
  const input  = fs.createReadStream(inputPath);
  const output = fs.createWriteStream(null, { fd, start: HEADER_LEN, autoClose: false });

  await pipeline(input, cipher, output);

  // Write auth tag back to header position
  const tag = cipher.getAuthTag();
  fs.writeSync(fd, tag, 0, TAG_LEN, SALT_LEN + IV_LEN);
  fs.closeSync(fd);

  return { salt, iv, tag };
}
```

5. **Implement `decrypt(inputPath, outputPath, password)`.** This function:
   - Reads the first 60 bytes of the encrypted file to extract salt, IV, and auth tag
   - Derives the key using the extracted salt + provided password
   - Creates a decipher with `crypto.createDecipheriv(ALGORITHM, key, iv)`
   - Sets the auth tag: `decipher.setAuthTag(tag)`
   - Streams from byte 60 onward through the decipher to the output file
   - Catches the `ERR_OSSL_EVP_UNABLE_TO_DECRYPT` error (wrong password or corrupted file) and handles it gracefully

```javascript
async function decrypt(inputPath, outputPath, password) {
  const fd = fs.openSync(inputPath, 'r');
  const header = Buffer.alloc(HEADER_LEN);
  fs.readSync(fd, header, 0, HEADER_LEN, 0);
  fs.closeSync(fd);

  const salt = header.subarray(0, SALT_LEN);
  const iv   = header.subarray(SALT_LEN, SALT_LEN + IV_LEN);
  const tag  = header.subarray(SALT_LEN + IV_LEN, HEADER_LEN);

  const key = await deriveKey(password, salt);
  const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(tag);

  const input  = fs.createReadStream(inputPath, { start: HEADER_LEN });
  const output = fs.createWriteStream(outputPath);

  await pipeline(input, decipher, output);
}
```

6. **Build the CLI interface.** Parse `process.argv` for two commands:
   - `node file-encryptor.js encrypt <input> <output> --password <pw>`
   - `node file-encryptor.js decrypt <input> <output> --password <pw>`

   Print usage and exit with code 1 if arguments are missing.

7. **Verify round-trip integrity.** After decryption, compute SHA-256 hashes of both the original and decrypted files. Print whether they match. This confirms no data was lost or corrupted during the encrypt-decrypt cycle.

8. **Test with various file types.** In the demo, encrypt and decrypt:
   - A plain text file (create one with `fs.writeFileSync`)
   - A binary file (e.g., a copy of the script itself)
   - An empty file (0 bytes)

   Verify all three produce identical output after round-trip.

## Break-Then-Harden Challenge

### Scenario 1 — Wrong Password

Attempt to decrypt with the wrong password. The GCM authentication check will fail with `Unsupported state or unable to authenticate data`. Catch this error gracefully: print "Decryption failed: incorrect password or corrupted file", delete the partial output file with `fs.unlinkSync()`, and exit with code 1. Verify that no partial plaintext is written.

### Scenario 2 — IV Reuse

Hardcode the IV to 12 bytes of zeros instead of generating a random one. Encrypt two different files with the same password. An attacker who XORs the two ciphertexts can recover information about the plaintexts (two-time pad attack). Worse, with GCM specifically, IV reuse leaks the authentication key, allowing the attacker to forge valid ciphertexts. Fix it by always generating a random IV with `crypto.randomBytes(12)`.

### Scenario 3 — Truncated Ciphertext

Truncate the encrypted file by removing the last 100 bytes (simulate network corruption or incomplete download). Attempt decryption. Observe that GCM detects the tampering via the authentication tag and throws an error — this is authenticated encryption working as designed. Note that unauthenticated modes like AES-CBC would silently produce garbage output without any error.

## Expected Output

```
$ echo "This is a secret message for the exercise." > secret.txt

$ node file-encryptor.js encrypt secret.txt secret.enc --password "myS3cur3Pa$$"
Encrypting: secret.txt -> secret.enc
  Algorithm:      aes-256-gcm
  Salt:           a7b3c9...f2e1 (32 bytes)
  IV:             3d8f1a...c4b2 (12 bytes)
  Key derivation: 89.4 ms (scrypt N=16384)
  Input:          44 bytes
  Output:         104 bytes (60-byte header + 44-byte ciphertext)
  Auth tag:       e2f1a8...b3c7 (16 bytes)
Encryption complete.

$ node file-encryptor.js decrypt secret.enc secret.dec --password "myS3cur3Pa$$"
Decrypting: secret.enc -> secret.dec
  Header read:    salt (32B) + IV (12B) + tag (16B)
  Key derivation: 88.7 ms
  Ciphertext:     44 bytes
  Decrypted:      44 bytes recovered
  SHA-256 check:  MATCH (original == decrypted)
Decryption complete.

$ diff secret.txt secret.dec
(no output — files are identical)

$ node file-encryptor.js decrypt secret.enc bad.dec --password "wrongpassword"
Decrypting: secret.enc -> bad.dec
  Header read:    salt (32B) + IV (12B) + tag (16B)
  Key derivation: 87.9 ms
  ERROR: Decryption failed — incorrect password or corrupted file.
  Cleaned up partial output.
```

## Bonus

1. **Large file stress test.** Generate a 500 MB file with `crypto.randomBytes()` written in 1 MB chunks. Encrypt and decrypt it, measuring throughput in MB/s. Monitor `process.memoryUsage().rss` during the operation — it should stay under 50 MB, proving the streaming approach works without loading the file into memory.

2. **Multiple recipients.** Encrypt the symmetric AES key with each recipient's RSA public key (using `crypto.publicEncrypt()`). Prepend the encrypted key blocks to the file header. Any recipient can decrypt with their private key to recover the AES key, then decrypt the file. This is how PGP/GPG hybrid encryption works.

## Hints

1. `crypto.createCipheriv('aes-256-gcm', key, iv)` requires exactly a 32-byte key (256 bits) and a 12-byte IV (96 bits) for GCM mode. Other IV lengths work but 12 bytes is the recommended size for performance and security.

2. The auth tag is only available after all data has been processed. Call `cipher.getAuthTag()` only after the pipeline finishes or after `cipher.final()`. Calling it too early returns an incomplete tag.

3. For reading from a specific offset, use `fs.createReadStream(path, { start: 60 })` to skip the 60-byte header and stream only the ciphertext portion.

4. `crypto.scrypt(password, salt, 32, callback)` derives a 32-byte key deterministically. Same password + same salt always produces the same key — this is how the decryptor can reconstruct the encryption key.

5. GCM (Galois/Counter Mode) provides both confidentiality and integrity. If a single bit of the ciphertext or tag is flipped, `decipher.final()` throws an authentication error. This is why AES-GCM is the recommended mode for file encryption — CBC provides no integrity guarantee.
