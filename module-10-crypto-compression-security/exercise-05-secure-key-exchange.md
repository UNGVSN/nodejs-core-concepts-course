# E05: Secure Key Exchange

## Objective

Implement a secure communication channel between two Node.js processes — a parent and a child connected via `child_process.fork()`. The processes perform an Elliptic-Curve Diffie-Hellman (ECDH) key exchange to derive a shared secret without ever transmitting the secret itself, then use `scrypt` to derive an AES-256-GCM encryption key from that secret. All subsequent IPC messages are encrypted and authenticated. This is the same fundamental protocol that underpins TLS, Signal, and every modern secure communication system.

## Prerequisites

- Module 10 / Lesson 05 — Diffie-Hellman & ECDH
- Module 10 / Lesson 03 — Symmetric Encryption (AES)
- Module 08 — Unix Processes (child_process.fork)

## Instructions

1. **Create two files:** `parent.js` (the orchestrator) and `child-worker.js` (the child process). Add `'use strict';` to both. In `parent.js`, require:

```javascript
'use strict';

const crypto = require('node:crypto');
const { fork } = require('node:child_process');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
```

2. **Implement ECDH in the parent.** Create an ECDH key pair using the `prime256v1` curve (also called P-256, the most widely deployed NIST curve):

```javascript
const ecdh = crypto.createECDH('prime256v1');
ecdh.generateKeys();
const parentPublicKey = ecdh.getPublicKey('hex');
console.log('[Parent] Public key generated:', parentPublicKey.slice(0, 32) + '...');
```

3. **Fork the child and exchange public keys.** Send the parent's public key to the child, then wait for the child's public key in response:

```javascript
const child = fork(path.join(__dirname, 'child-worker.js'));

child.send({ type: 'publicKey', key: parentPublicKey });

child.on('message', (msg) => {
  if (msg.type === 'publicKey') {
    const sharedSecret = ecdh.computeSecret(msg.key, 'hex');
    console.log('[Parent] Shared secret:', sharedSecret.slice(0, 32) + '...');
    // Derive AES key from shared secret...
  }
});
```

4. **Implement ECDH in the child.** In `child-worker.js`, create its own ECDH instance, generate keys, and compute the shared secret upon receiving the parent's public key:

```javascript
'use strict';

const crypto = require('node:crypto');

const ecdh = crypto.createECDH('prime256v1');
ecdh.generateKeys();
const childPublicKey = ecdh.getPublicKey('hex');

process.on('message', (msg) => {
  if (msg.type === 'publicKey') {
    const sharedSecret = ecdh.computeSecret(msg.key, 'hex');
    console.log('[Child]  Shared secret:', sharedSecret.slice(0, 32) + '...');
    // Send our public key back
    process.send({ type: 'publicKey', key: childPublicKey });
    // Derive AES key from shared secret...
  }
});
```

The mathematical property of ECDH guarantees both sides compute the identical shared secret — without either side ever transmitting it.

5. **Derive an AES key from the shared secret.** Both processes independently derive the same AES-256 key using `crypto.scrypt()`. Use a fixed application-specific salt for this exercise (in production, negotiate a random salt during the handshake):

```javascript
function deriveAESKey(sharedSecret) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(sharedSecret, 'key-exchange-exercise-salt', 32, (err, key) => {
      err ? reject(err) : resolve(key);
    });
  });
}
```

6. **Implement `encryptMessage(plaintext, key)`.** Generate a random 12-byte IV, encrypt with AES-256-GCM, and return a serializable object:

```javascript
function encryptMessage(plaintext, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  let ciphertext = cipher.update(plaintext, 'utf8', 'hex');
  ciphertext += cipher.final('hex');
  const tag = cipher.getAuthTag().toString('hex');
  return { iv: iv.toString('hex'), ciphertext, tag };
}
```

7. **Implement `decryptMessage(encrypted, key)`.** Reconstruct the decipher from the IV and auth tag, then decrypt:

```javascript
function decryptMessage({ iv, ciphertext, tag }, key) {
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm', key, Buffer.from(iv, 'hex')
  );
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  let plaintext = decipher.update(ciphertext, 'hex', 'utf8');
  plaintext += decipher.final('utf8');
  return plaintext;
}
```

8. **Exchange encrypted messages.** After the key exchange completes on both sides:
   - Parent sends 5 encrypted messages: `"Message 1 from parent"` through `"Message 5 from parent"`
   - Child decrypts each, logs the plaintext, and sends an encrypted reply: `"Acknowledged message N"`
   - Parent decrypts and logs each reply
   - Use `{ type: 'encrypted', payload: encryptMessage(text, key) }` as the IPC message format

9. **Verify shared secret agreement.** Both processes print the first 32 hex characters of their computed shared secret. These must be identical. If they differ, the key exchange failed and all encrypted messages will fail to decrypt.

10. **Implement graceful shutdown.** After all 5 round-trips complete, the parent sends an encrypted `"SHUTDOWN"` command. The child decrypts it, logs "Shutting down gracefully", and calls `process.exit(0)`. The parent listens for the child's `'exit'` event and prints the total elapsed time for the entire key exchange + messaging session.

## Break-Then-Harden Challenge

### Scenario 1 — Man-in-the-Middle Simulation

Create a third file, `proxy.js`, that sits between parent and child. The proxy forks the real child but intercepts all IPC messages. When it receives the parent's public key, it performs its own ECDH exchange with the parent (substituting its own public key). When the child sends its key, the proxy performs a separate exchange with the child. Now the proxy can decrypt messages from both sides, read them, and re-encrypt for the other side. Both parent and child believe they are communicating securely. Discuss why raw ECDH is vulnerable to MITM — you need authentication (e.g., digital signatures on the public keys) to fix this.

### Scenario 2 — Replay Attack

Capture one encrypted message `{ iv, ciphertext, tag }` from the parent. After the normal exchange completes, replay (re-send) the captured message. The child decrypts it successfully — GCM provides integrity but not replay protection. Fix it by adding a monotonically increasing sequence number to each plaintext before encryption: `"001:Message 1 from parent"`. The receiver tracks the last seen sequence number and rejects any message with a number that is not strictly greater.

### Scenario 3 — Curve Mismatch

Change the parent to use `'secp384r1'` while the child uses `'prime256v1'`. Observe the `ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY` error when `computeSecret` is called — the public key from one curve is invalid on the other. Fix it by having both processes agree on the curve before key generation: the parent sends `{ type: 'hello', curve: 'prime256v1' }` as the first message, and the child validates and uses the same curve.

## Expected Output

```
$ node parent.js

[Parent] ECDH key pair generated (prime256v1)
[Parent] Forked child process (PID: 48291)
[Parent] Sent public key to child

[Child]  ECDH key pair generated (prime256v1)
[Child]  Received parent's public key
[Child]  Computed shared secret: a7b3c9d1e5f28a4b...
[Child]  Sent public key to parent

[Parent] Received child's public key
[Parent] Computed shared secret: a7b3c9d1e5f28a4b...
[Parent] Shared secrets match: YES

[Parent] Deriving AES-256 key from shared secret...
[Child]  Deriving AES-256 key from shared secret...

[Parent] >>> Sending encrypted: "Message 1 from parent"
[Child]  <<< Decrypted: "Message 1 from parent"
[Child]  >>> Sending encrypted reply: "Acknowledged message 1"
[Parent] <<< Decrypted reply: "Acknowledged message 1"

[Parent] >>> Sending encrypted: "Message 2 from parent"
[Child]  <<< Decrypted: "Message 2 from parent"
[Child]  >>> Sending encrypted reply: "Acknowledged message 2"
[Parent] <<< Decrypted reply: "Acknowledged message 2"

[Parent] >>> Sending encrypted: "Message 3 from parent"
[Child]  <<< Decrypted: "Message 3 from parent"
[Child]  >>> Sending encrypted reply: "Acknowledged message 3"
[Parent] <<< Decrypted reply: "Acknowledged message 3"

[Parent] >>> Sending encrypted: "Message 4 from parent"
[Child]  <<< Decrypted: "Message 4 from parent"
[Child]  >>> Sending encrypted reply: "Acknowledged message 4"
[Parent] <<< Decrypted reply: "Acknowledged message 4"

[Parent] >>> Sending encrypted: "Message 5 from parent"
[Child]  <<< Decrypted: "Message 5 from parent"
[Child]  >>> Sending encrypted reply: "Acknowledged message 5"
[Parent] <<< Decrypted reply: "Acknowledged message 5"

[Parent] >>> Sending encrypted shutdown command
[Child]  <<< Decrypted: "SHUTDOWN"
[Child]  Shutting down gracefully.
[Parent] Child exited (code: 0)

Session complete: key exchange + 5 encrypted round-trips in 412.8 ms
```

## Bonus

1. **Forward secrecy via key ratcheting.** After every 3 messages, perform a new ECDH key exchange and derive a fresh AES key. Old keys are discarded. This way, compromising one key exposes at most 3 messages. This is a simplified version of the Signal Protocol's Double Ratchet algorithm.

2. **X25519 key exchange.** Replace `prime256v1` with `X25519` using the newer `crypto.generateKeyPairSync('x25519')` and `crypto.diffieHellman({ privateKey, publicKey })` API. X25519 is faster than NIST P-256 and is considered safer against certain implementation attacks. Compare key exchange timing between the two curves.

## Hints

1. `crypto.createECDH('prime256v1')` creates an ECDH instance for the P-256 curve. Call `.generateKeys()` to create the key pair, `.getPublicKey('hex')` to export, and `.computeSecret(otherPubKey, 'hex')` to derive the shared secret.

2. The shared secret from ECDH should not be used directly as an AES key — it is a raw elliptic curve point with non-uniform entropy. Pass it through `scrypt` to derive a key with the correct length and entropy distribution.

3. `child_process.fork()` automatically creates a JSON-serialized IPC channel. Use `child.send(obj)` and `process.on('message', handler)` — objects are cloned, not shared.

4. Each encrypted message must use its own random 12-byte IV. GCM with a repeated IV and the same key is catastrophically broken — it leaks the authentication key and enables plaintext recovery.

5. The mathematical guarantee: if Alice computes `aliceECDH.computeSecret(bobPublicKey)` and Bob computes `bobECDH.computeSecret(alicePublicKey)`, both get the same shared secret. Neither side ever transmits this secret — they only exchange public keys.
