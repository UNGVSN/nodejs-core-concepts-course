# E01: Password Hasher & Verifier

## Objective

Build a complete password hashing and verification system using `crypto.scrypt()` for key derivation and `crypto.randomBytes()` for salt generation. Passwords are stored in the format `salt:hash` (both hex-encoded). Verification uses `crypto.timingSafeEqual()` to prevent timing attacks. This is the same approach used by production authentication systems — the exact functions recommended by OWASP.

## Prerequisites

- Module 10 / Lesson 01 — Cryptography Fundamentals
- Module 10 / Lesson 02 — Hashing (SHA, MD5, HMAC)
- Module 10 / Lesson 09 — Security Best Practices

## Instructions

1. **Create `password-hasher.js`** with `'use strict';` at the top. Require:

```javascript
'use strict';

const crypto = require('node:crypto');
const fs     = require('node:fs');
const path   = require('node:path');
const { performance } = require('node:perf_hooks');
```

2. **Define scrypt parameters.** Set the cost parameters as constants at the top of the file and document each:

```javascript
const SCRYPT_PARAMS = {
  N: 16384,   // CPU/memory cost — must be power of 2
  r: 8,       // Block size — affects memory per thread
  p: 1,       // Parallelization — number of threads
  maxmem: 64 * 1024 * 1024  // 64 MB memory limit
};
const SALT_LENGTH = 32;  // 256 bits of random salt
const KEY_LENGTH  = 64;  // 512-bit derived key
```

3. **Implement `hashPassword(password)`** that returns a Promise. Generate a random salt with `crypto.randomBytes(SALT_LENGTH)`. Derive a key using the async `crypto.scrypt()`:

```javascript
async function hashPassword(password) {
  const salt = crypto.randomBytes(SALT_LENGTH);
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, KEY_LENGTH, SCRYPT_PARAMS, (err, derivedKey) => {
      if (err) return reject(err);
      resolve(salt.toString('hex') + ':' + derivedKey.toString('hex'));
    });
  });
}
```

4. **Implement `verifyPassword(password, storedHash)`** that returns a Promise resolving to `true` or `false`. Split the stored hash on `:` to extract the hex salt and hex hash. Convert both back to Buffers. Derive a new key from the input password using the extracted salt. Compare with `crypto.timingSafeEqual()`:

```javascript
async function verifyPassword(password, storedHash) {
  const [saltHex, hashHex] = storedHash.split(':');
  const salt = Buffer.from(saltHex, 'hex');
  const expectedHash = Buffer.from(hashHex, 'hex');

  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, KEY_LENGTH, SCRYPT_PARAMS, (err, derivedKey) => {
      if (err) return reject(err);
      // Both buffers MUST be the same length for timingSafeEqual
      if (derivedKey.length !== expectedHash.length) return resolve(false);
      resolve(crypto.timingSafeEqual(derivedKey, expectedHash));
    });
  });
}
```

5. **Implement a user database.** Create a simple JSON file store at `./users.json`. Write `loadUsers()` that reads and parses the file (return `{}` if missing). Write `saveUsers(users)` that writes the object back. Implement:
   - `addUser(username, password)` — hash the password, store `{ [username]: { hash } }`
   - `authenticateUser(username, password)` — load the stored hash, call `verifyPassword()`
   - `listUsers()` — return usernames only (never expose hashes)

6. **Build the CLI interface.** Parse `process.argv` to support three commands:
   - `node password-hasher.js add <username> <password>`
   - `node password-hasher.js verify <username> <password>`
   - `node password-hasher.js list`

   Print usage information if no valid command is given. Exit with code 1 on errors.

7. **Demonstrate the timing attack.** Write a `naiveCompare(a, b)` function that compares two Buffers byte-by-byte with an early return on the first mismatch:

```javascript
function naiveCompare(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;  // leaks position of first difference
  }
  return true;
}
```

Run the naive comparison with hashes that match 0, 16, 32, 48, and 64 bytes. Time each with `performance.now()`. Show that longer prefixes take measurably longer. Then run the same test with `timingSafeEqual` and show that all comparisons take the same time within noise.

8. **Benchmark scrypt cost factors.** Test `N` values of 1024, 4096, 16384, 65536, and 131072. For each, hash the password "benchmark" and measure the elapsed time. Print a table showing the time-vs-security tradeoff. Note that each doubling of `N` roughly doubles the time and memory.

## Break-Then-Harden Challenge

### Scenario 1 — Salt Reuse

Hardcode the salt instead of generating a random one: `const salt = Buffer.alloc(32, 0)`. Hash the password "hello" twice. Observe identical output both times. In a database, an attacker would immediately see which users share the same password. Fix it by restoring `crypto.randomBytes(32)` and verify that the same password now produces different hashes every time.

### Scenario 2 — Length Mismatch Crash

Manually create a stored hash with an incorrect key length (e.g., truncate the hash hex string). Call `verifyPassword()` with a valid password. Observe that `crypto.timingSafeEqual()` throws `Input buffers must have the same byte length`. Fix it by checking `derivedKey.length !== expectedHash.length` before calling `timingSafeEqual` and returning `false` instead of crashing.

### Scenario 3 — SHA-256 Instead of scrypt

Replace `crypto.scrypt()` with `crypto.createHash('sha256').update(salt + password).digest()`. Hash "password123" and measure the time — it completes in microseconds. Then hash with `scrypt(N=16384)` — it takes ~80ms. Calculate how many guesses/second an attacker could try with each approach. SHA-256: billions per second on a GPU. scrypt(N=16384): thousands per second. This is why fast hashes are catastrophically dangerous for passwords.

## Expected Output

```
$ node password-hasher.js add alice "secretpass123"
Hashing password for 'alice'...
  Salt:      7a3f9b2e...c4d1 (32 bytes, random)
  scrypt:    N=16384, r=8, p=1
  Time:      87.3 ms
  Stored as: 7a3f9b2e...c4d1:8e2f1a...b7c3
User 'alice' created successfully.

$ node password-hasher.js add bob "hunter2"
Hashing password for 'bob'...
  Time: 86.1 ms
User 'bob' created successfully.

$ node password-hasher.js verify alice "secretpass123"
Verifying password for 'alice'...
  Result:  CORRECT (87.4 ms)

$ node password-hasher.js verify alice "wrongpassword"
Verifying password for 'alice'...
  Result:  INCORRECT (86.9 ms)
  Note: verification time is constant regardless of correctness.

$ node password-hasher.js list
Registered users: alice, bob

--- Timing Attack Demonstration ---
Naive compare (0/64 bytes match):   0.003 ms
Naive compare (16/64 bytes match):  0.008 ms
Naive compare (32/64 bytes match):  0.014 ms
Naive compare (48/64 bytes match):  0.019 ms
Naive compare (64/64 bytes match):  0.025 ms  << correlates with match length!

timingSafeEqual (0/64 bytes match):  0.012 ms
timingSafeEqual (16/64 bytes match): 0.012 ms
timingSafeEqual (32/64 bytes match): 0.012 ms
timingSafeEqual (48/64 bytes match): 0.012 ms
timingSafeEqual (64/64 bytes match): 0.012 ms  << constant time!

--- scrypt Cost Benchmark (password: "benchmark") ---
N=1024:    12.4 ms   (fast but weak — crackable with moderate hardware)
N=4096:    38.7 ms   (minimum acceptable for low-security applications)
N=16384:   89.2 ms   (recommended default — OWASP baseline)
N=65536:  341.8 ms   (high security — suitable for master passwords)
N=131072: 678.3 ms   (maximum practical — perceptible delay for users)
```

## Bonus

1. **Password strength checker.** Before hashing, validate the password: minimum 8 characters, at least one uppercase, one lowercase, one digit, one special character. Reject the top 20 most common passwords (hardcode the list: "password", "123456", "qwerty", etc.). Return specific feedback about each weakness.

2. **Hash migration tool.** Write a `migrateHash(username, password, oldHash)` function that detects old-format hashes (e.g., plain SHA-256 with no salt, stored as a 64-character hex string). On successful verification against the old hash, re-hash with scrypt and update the store. This simulates upgrading a legacy database.

## Hints

1. `crypto.scrypt(password, salt, keyLength, [options], callback)` is asynchronous and non-blocking. Wrap it in a Promise: `new Promise((resolve, reject) => crypto.scrypt(..., (err, key) => err ? reject(err) : resolve(key)))`.

2. `crypto.randomBytes(32)` returns a 32-byte Buffer of cryptographically secure random data. Convert to hex for storage with `.toString('hex')` and back with `Buffer.from(hex, 'hex')`.

3. `crypto.timingSafeEqual(a, b)` always compares all bytes regardless of where the first mismatch occurs. This prevents an attacker from determining how much of the hash they guessed correctly by measuring response time.

4. The `salt:hash` storage format keeps the salt alongside the hash because you need the exact same salt to verify later. The salt is not secret — its purpose is to ensure every hash is unique, defeating precomputed rainbow tables.

5. The scrypt `N` parameter must be a power of 2 and controls the CPU/memory cost. Each doubling of `N` doubles both the time and the memory consumed. The `r` parameter controls block size (8 is standard), and `p` controls parallelism (1 is standard for server-side hashing).
