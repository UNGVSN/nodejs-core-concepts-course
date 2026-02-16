# Track 02 / Lesson 03 — Timing Attacks & Side Channels

> Your encryption is flawless, your certificates are valid, your firewall is airtight — and an attacker recovers your API keys by measuring how long your server takes to say "no." Timing attacks exploit the physical reality that computation takes time, and that time leaks information about the data being processed.

## Learning Objectives

- Explain why the `===` operator leaks secret values through early termination timing
- Implement constant-time comparison using `crypto.timingSafeEqual()` and understand its constraints
- Measure timing differences between naive and constant-time comparison to prove the vulnerability
- Identify and defend against cache timing side channels in Node.js applications
- Build a practical timing attack demonstration that recovers a secret one character at a time

---

## Why === Is Dangerous for Secrets

JavaScript's strict equality operator compares strings character by character and returns `false` at the first mismatch:

```js
'use strict';

// Demonstrating early termination in string comparison

function naiveCompare(a, b) {
  if (a.length !== b.length) return false;

  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      // Returns immediately on first mismatch
      // An attacker can measure this timing difference
      return false;
    }
  }
  return true;
}

// When comparing "abcdef" against the secret "xyznop":
// - "a" !== "x" → returns after 1 comparison
//
// When comparing "xbcdef" against the secret "xyznop":
// - "x" === "x" → continue
// - "b" !== "y" → returns after 2 comparisons
//
// The second comparison takes measurably longer.
// After thousands of measurements, the attacker can distinguish
// the timing difference and deduce the first correct character.
```

This is not theoretical. In 2009, researchers demonstrated a remote timing attack against HMAC verification in the Keyczar cryptographic library, recovering the key byte by byte across a network.

---

## The Physics of Timing

Modern CPUs run at billions of cycles per second, but timing differences as small as a few nanoseconds can be measured statistically:

```js
'use strict';

const { performance } = require('node:perf_hooks');

// Measure the timing difference between matching and non-matching prefixes
function measureComparisonTime(a, b, iterations = 100000) {
  // Warmup — JIT compilation affects early measurements
  for (let i = 0; i < 1000; i++) {
    a === b;
  }

  const times = [];

  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    a === b;
    const end = performance.now();
    times.push(end - start);
  }

  // Use median to reduce noise
  times.sort((a, b) => a - b);
  return {
    median: times[Math.floor(times.length / 2)],
    mean: times.reduce((s, t) => s + t, 0) / times.length,
    p95: times[Math.floor(times.length * 0.95)],
    min: times[0],
    max: times[times.length - 1],
  };
}

const secret = 'a'.repeat(1000);

// Zero characters match
const timing0 = measureComparisonTime(secret, 'b'.repeat(1000));

// All characters match except the last
const almostRight = 'a'.repeat(999) + 'b';
const timing999 = measureComparisonTime(secret, almostRight);

// Perfect match
const timingAll = measureComparisonTime(secret, 'a'.repeat(1000));

console.log('Timing comparison (median nanoseconds):');
console.log(`  0 chars match:    ${(timing0.median * 1e6).toFixed(0)} ns`);
console.log(`  999 chars match:  ${(timing999.median * 1e6).toFixed(0)} ns`);
console.log(`  1000 chars match: ${(timingAll.median * 1e6).toFixed(0)} ns`);
console.log();
console.log('The difference is small per call, but statistically');
console.log('significant over thousands of measurements.');
```

In practice, network jitter overwhelms individual measurements. Attackers compensate by making thousands of requests per character position and using statistical analysis to extract the signal from the noise.

---

## crypto.timingSafeEqual()

Node.js provides `crypto.timingSafeEqual()` for constant-time comparison. It compares two Buffers byte by byte, always examining every byte regardless of where mismatches occur:

```js
'use strict';

const crypto = require('node:crypto');

// Basic usage of timingSafeEqual
function safeCompare(a, b) {
  // CRITICAL: timingSafeEqual requires both inputs to be the same length.
  // If lengths differ, you must handle that without leaking which
  // input was shorter.

  // Convert strings to Buffers
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');

  // If lengths differ, compare against a dummy of matching length
  // to avoid leaking the length of the secret
  if (bufA.length !== bufB.length) {
    // Compare bufB against itself to consume the same time
    // as a real comparison, then return false
    crypto.timingSafeEqual(bufB, bufB);
    return false;
  }

  return crypto.timingSafeEqual(bufA, bufB);
}

// Test it
const secret = 'my-api-key-abc123';

console.log('Correct key: ', safeCompare(secret, 'my-api-key-abc123'));   // true
console.log('Wrong key:   ', safeCompare(secret, 'wrong-key'));           // false
console.log('Close key:   ', safeCompare(secret, 'my-api-key-abc124'));   // false
console.log('Empty key:   ', safeCompare(secret, ''));                    // false
```

### How timingSafeEqual Works Internally

Under the hood, `timingSafeEqual` uses a bitwise OR accumulator:

```js
'use strict';

// Simplified version of what timingSafeEqual does internally
// (The real implementation is in C++ for consistent timing)
function constantTimeEqual(bufA, bufB) {
  if (bufA.length !== bufB.length) {
    throw new RangeError('Input buffers must have the same byte length');
  }

  let result = 0;

  // XOR each byte pair and OR into the accumulator
  // If any bytes differ, result becomes non-zero
  // But we ALWAYS check every byte — no early return
  for (let i = 0; i < bufA.length; i++) {
    result |= bufA[i] ^ bufB[i];
  }

  // result is 0 if and only if all bytes are equal
  return result === 0;
}

// Demonstrate
const a = Buffer.from('hello');
const b = Buffer.from('hello');
const c = Buffer.from('hellp');

console.log(constantTimeEqual(a, b)); // true
console.log(constantTimeEqual(a, c)); // false
```

The key insight: the loop always runs `bufA.length` iterations. The XOR and OR operations take constant time per byte. There is no branch that could cause early termination.

---

## HMAC-Based Token Verification

The most common real-world scenario for timing attacks is token verification. Here is the safe pattern:

```js
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

const SECRET = crypto.randomBytes(32);

// Generate a token for a given payload
function generateToken(payload) {
  const data = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto
    .createHmac('sha256', SECRET)
    .update(data)
    .digest('base64url');

  return `${data}.${signature}`;
}

// Verify a token — constant-time comparison of the signature
function verifyToken(token) {
  const dotIndex = token.indexOf('.');
  if (dotIndex === -1) return null;

  const data = token.substring(0, dotIndex);
  const providedSig = token.substring(dotIndex + 1);

  // Recompute the expected signature
  const expectedSig = crypto
    .createHmac('sha256', SECRET)
    .update(data)
    .digest('base64url');

  // Convert both to Buffers for timingSafeEqual
  const providedBuf = Buffer.from(providedSig, 'base64url');
  const expectedBuf = Buffer.from(expectedSig, 'base64url');

  // Length check — HMAC-SHA256 always produces 32 bytes,
  // so length differences indicate a malformed token, not a timing leak
  if (providedBuf.length !== expectedBuf.length) {
    return null;
  }

  if (!crypto.timingSafeEqual(providedBuf, expectedBuf)) {
    return null;
  }

  // Signature is valid — parse the payload
  try {
    return JSON.parse(Buffer.from(data, 'base64url').toString());
  } catch {
    return null;
  }
}

// HTTP server using safe token verification
const server = http.createServer((req, res) => {
  const authHeader = req.headers['authorization'];

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing authorization' }));
    return;
  }

  const token = authHeader.substring(7);
  const payload = verifyToken(token);

  if (!payload) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Invalid token' }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ user: payload, message: 'Authenticated' }));
});

server.listen(3000, () => {
  // Generate a test token
  const token = generateToken({ userId: 42, role: 'admin' });
  console.log('Server running on http://localhost:3000');
  console.log('Test with:');
  console.log(`  curl -H "Authorization: Bearer ${token}" http://localhost:3000`);
});
```

---

## Practical Demo: Timing-Based Secret Recovery

This demonstration shows how an attacker recovers a secret character by character using timing measurements. **This is an educational tool — use it only against your own test servers.**

```js
'use strict';

const { performance } = require('node:perf_hooks');

// Vulnerable comparison function (DO NOT use in production)
function vulnerableCompare(input, secret) {
  if (input.length !== secret.length) return false;
  for (let i = 0; i < input.length; i++) {
    // Artificial delay to make timing difference measurable
    // In real servers, the difference is much smaller but still exploitable
    let sum = 0;
    for (let j = 0; j < 10000; j++) sum += j;

    if (input[i] !== secret[i]) return false;
  }
  return true;
}

// The attacker's timing oracle
function measureAttempt(input, secret, samples = 50) {
  const times = [];

  for (let s = 0; s < samples; s++) {
    const start = performance.now();
    vulnerableCompare(input, secret);
    const end = performance.now();
    times.push(end - start);
  }

  // Use median for noise reduction
  times.sort((a, b) => a - b);
  return times[Math.floor(times.length / 2)];
}

// Recover the secret one character at a time
function recoverSecret(secret, charset = 'abcdefghijklmnopqrstuvwxyz0123456789') {
  console.log(`Secret length: ${secret.length} (assume attacker knows this)`);
  console.log('Recovering secret character by character...\n');

  let recovered = '';

  for (let pos = 0; pos < secret.length; pos++) {
    let bestChar = '';
    let bestTime = 0;

    // Try every possible character at this position
    for (const ch of charset) {
      const attempt = recovered + ch + 'a'.repeat(secret.length - recovered.length - 1);
      const time = measureAttempt(attempt, secret);

      if (time > bestTime) {
        bestTime = time;
        bestChar = ch;
      }
    }

    recovered += bestChar;
    console.log(
      `  Position ${pos}: '${bestChar}' ` +
      `(${bestTime.toFixed(3)} ms) → recovered so far: "${recovered}"`
    );
  }

  console.log(`\nRecovered secret: "${recovered}"`);
  console.log(`Actual secret:    "${secret}"`);
  console.log(`Match: ${recovered === secret}`);
}

// Run the attack
const SECRET = 'key42x';
recoverSecret(SECRET);
```

---

## Constant-Time Helpers for Common Patterns

Beyond raw comparison, several common operations need constant-time treatment:

```js
'use strict';

const crypto = require('node:crypto');

// Constant-time string comparison (wraps timingSafeEqual)
function constantTimeStringEqual(a, b) {
  // Hash both strings so length differences do not leak information.
  // Two different-length strings that hash to the same digest
  // would be a hash collision — practically impossible with SHA-256.
  const hashA = crypto.createHash('sha256').update(a).digest();
  const hashB = crypto.createHash('sha256').update(b).digest();

  // Now both buffers are always 32 bytes — no length leak
  return crypto.timingSafeEqual(hashA, hashB);
}

// Constant-time selection: return valueA if condition is true, valueB if false
// WITHOUT branching (no if/else that could be timed)
function constantTimeSelect(condition, valueA, valueB) {
  // Convert boolean to bitmask: true → 0xFF...FF, false → 0x00...00
  const mask = -Number(!!condition); // -1 (all bits set) or 0

  // For numeric values:
  // (valueA & mask) | (valueB & ~mask)
  // This works for integers but not for objects/strings.
  // For general use, the branch is unavoidable — but keep
  // the branches doing equal amounts of work.
  return condition ? valueA : valueB;
}

// Constant-time password verification with scrypt
async function verifyPassword(inputPassword, storedHash, storedSalt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(inputPassword, storedSalt, 64, (err, derivedKey) => {
      if (err) return reject(err);

      const storedBuf = Buffer.from(storedHash, 'hex');
      const derivedBuf = derivedKey;

      if (storedBuf.length !== derivedBuf.length) {
        // This should never happen if the stored hash was generated
        // with the same key length. If it does, it is a data corruption issue.
        resolve(false);
        return;
      }

      resolve(crypto.timingSafeEqual(derivedBuf, storedBuf));
    });
  });
}

// Usage
async function demo() {
  // Hash a password
  const salt = crypto.randomBytes(16);
  const password = 'correct-horse-battery-staple';

  const hash = await new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (err, key) => {
      if (err) reject(err);
      else resolve(key.toString('hex'));
    });
  });

  console.log('Salt:', salt.toString('hex'));
  console.log('Hash:', hash);

  // Verify correct password
  const valid = await verifyPassword(password, hash, salt);
  console.log('Correct password:', valid); // true

  // Verify wrong password
  const invalid = await verifyPassword('wrong-password', hash, salt);
  console.log('Wrong password:', invalid); // false

  // Constant-time string comparison
  console.log('Same strings:', constantTimeStringEqual('hello', 'hello')); // true
  console.log('Diff strings:', constantTimeStringEqual('hello', 'world')); // false
  console.log('Diff lengths:', constantTimeStringEqual('ab', 'abcdef'));   // false
}

demo().catch(console.error);
```

---

## Cache Timing Side Channels

Beyond comparison timing, cache-based side channels can leak information. When data is in the CPU cache, accessing it is faster than fetching from main memory. An attacker who shares the CPU (cloud VMs, shared hosting) can exploit this:

```js
'use strict';

const { performance } = require('node:perf_hooks');

// Demonstration: Array access timing reveals which indices were recently accessed

function cacheTimingDemo() {
  // Create a large array (larger than L1 cache)
  const size = 1024 * 1024; // 1M entries
  const arr = new Float64Array(size);

  // Fill with data
  for (let i = 0; i < size; i++) {
    arr[i] = Math.random();
  }

  // Access specific indices (these will be in cache)
  const secretIndex = 42;
  let dummy = arr[secretIndex]; // Load into cache

  // Measure access time for all indices
  const accessTimes = [];

  // Measure the secret index (should be fast — in cache)
  const start1 = performance.now();
  for (let j = 0; j < 1000; j++) dummy = arr[secretIndex];
  const time1 = performance.now() - start1;

  // Measure a cold index (should be slower — not in cache)
  const coldIndex = 999999;
  const start2 = performance.now();
  for (let j = 0; j < 1000; j++) dummy = arr[coldIndex];
  const time2 = performance.now() - start2;

  console.log('Cache timing demonstration:');
  console.log(`  Cached index (${secretIndex}):  ${time1.toFixed(4)} ms for 1000 reads`);
  console.log(`  Cold index (${coldIndex}): ${time2.toFixed(4)} ms for 1000 reads`);
  console.log(`  Ratio: ${(time2 / time1).toFixed(2)}x`);
  console.log();
  console.log('Note: V8 JIT optimizations may obscure this in JavaScript.');
  console.log('Cache timing attacks are more practical at the native code level.');

  // Prevent dead code elimination
  if (dummy === -Infinity) console.log('never');
}

cacheTimingDemo();
```

### Defense Against Cache Timing

Cache timing attacks in pure JavaScript are difficult (V8's JIT obscures access patterns), but in native addons or when running on shared infrastructure:

1. **Avoid secret-dependent array indexing.** Do not use a secret value as an array index.
2. **Use constant-time lookup tables.** Access every element of the table on every lookup and select the right one with bitwise operations.
3. **Isolate sensitive computation.** Run cryptographic operations in dedicated worker threads or processes to reduce cache sharing.

---

## Timing Attack Defenses: A Checklist

```js
'use strict';

// Timing attack defense checklist for Node.js applications

const defenses = [
  {
    rule: 'Never compare secrets with === or ==',
    fix: 'Use crypto.timingSafeEqual() for all secret comparisons',
    applies: 'API keys, tokens, HMAC signatures, session IDs',
  },
  {
    rule: 'Never compare secrets of different lengths directly',
    fix: 'Hash both values first (SHA-256), then compare the fixed-length digests',
    applies: 'User-supplied tokens vs stored tokens',
  },
  {
    rule: 'Use HMAC for token verification, not raw comparison',
    fix: 'Recompute HMAC and compare digests, not token strings',
    applies: 'JWT signatures, API authentication',
  },
  {
    rule: 'Use scrypt/pbkdf2 for password verification',
    fix: 'Derive key from input, compare with timingSafeEqual',
    applies: 'Login endpoints, password change flows',
  },
  {
    rule: 'Do not leak existence of resources via timing',
    fix: 'Return the same response time for "user not found" and "wrong password"',
    applies: 'Login endpoints, user enumeration',
  },
  {
    rule: 'Avoid secret-dependent branches in hot paths',
    fix: 'Use branchless (bitwise) logic where possible',
    applies: 'Cryptographic routines, permission checks',
  },
  {
    rule: 'Add artificial random delay to authentication endpoints',
    fix: 'After verification, wait a random 50-200ms before responding',
    applies: 'Login, token refresh, API key validation',
  },
];

console.log('TIMING ATTACK DEFENSE CHECKLIST');
console.log('═'.repeat(60));
defenses.forEach((d, i) => {
  console.log(`\n${i + 1}. ${d.rule}`);
  console.log(`   Fix: ${d.fix}`);
  console.log(`   Applies to: ${d.applies}`);
});
```

### Adding Artificial Jitter to Authentication

```js
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

// Add random delay to authentication responses to frustrate timing analysis
function randomDelay(minMs = 50, maxMs = 200) {
  return new Promise((resolve) => {
    // Use crypto.randomInt for unbiased random number
    const delay = crypto.randomInt(minMs, maxMs + 1);
    setTimeout(resolve, delay);
  });
}

const server = http.createServer(async (req, res) => {
  const token = req.headers['authorization']?.replace('Bearer ', '');

  // Always perform the full verification — even if the token is missing
  const isValid = token ? verifyApiKey(token) : false;

  // Add random delay AFTER computation
  // This makes it impossible to distinguish "missing token" from
  // "wrong token" from "almost-right token" by timing
  await randomDelay();

  if (!isValid) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Forbidden' }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok' }));
});

function verifyApiKey(input) {
  const VALID_KEY = 'sk_live_abc123def456';
  const inputHash = crypto.createHash('sha256').update(input).digest();
  const keyHash = crypto.createHash('sha256').update(VALID_KEY).digest();
  return crypto.timingSafeEqual(inputHash, keyHash);
}

server.listen(3000, () => {
  console.log('Server with timing jitter on http://localhost:3000');
});
```

---

## Common Mistakes

### Mistake 1: timingSafeEqual with Different-Length Buffers

```js
'use strict';

const crypto = require('node:crypto');

// This throws RangeError — timingSafeEqual requires equal-length Buffers
try {
  const a = Buffer.from('short');
  const b = Buffer.from('much longer string');
  crypto.timingSafeEqual(a, b);
} catch (err) {
  console.log('Error:', err.message);
  // Error: Input buffers must have the same byte length
}

// Solution: Hash first, then compare
function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

console.log(safeEqual('hello', 'hello'));                // true
console.log(safeEqual('hello', 'world'));                // false
console.log(safeEqual('short', 'a very long string'));   // false
```

### Mistake 2: Timing-Safe Comparison but Length-Leaking Branch

```js
'use strict';

const crypto = require('node:crypto');

// BAD: Length check before timing-safe comparison leaks info
function badVerify(input, secret) {
  if (input.length !== secret.length) {
    return false; // LEAK: attacker can determine the secret's length
  }
  return crypto.timingSafeEqual(Buffer.from(input), Buffer.from(secret));
}

// GOOD: Hash both so length is always 32 bytes
function goodVerify(input, secret) {
  const h1 = crypto.createHash('sha256').update(input).digest();
  const h2 = crypto.createHash('sha256').update(secret).digest();
  return crypto.timingSafeEqual(h1, h2);
}
```

---

## Key Takeaways

- The `===` operator compares strings left to right and returns `false` at the first mismatch — this timing difference is measurable and exploitable, even over a network with statistical analysis
- `crypto.timingSafeEqual()` compares every byte using XOR and OR accumulation, taking the same time regardless of where mismatches occur — but it requires both Buffers to be the same length
- For strings of different lengths, hash both values with SHA-256 first to produce fixed-length 32-byte digests, then compare those with `timingSafeEqual`
- Password verification should always use `crypto.scrypt()` or `crypto.pbkdf2()` followed by `timingSafeEqual` — never compare password strings or hashes directly
- Adding random jitter (50-200ms) to authentication endpoints is a defense-in-depth measure that frustrates timing analysis, but it is not a substitute for constant-time comparison

## Next

In [Lesson 04 — Input Validation & Sanitization](lesson-04-input-validation.md), we shift from cryptographic side channels to the most common class of application-level attacks: malicious input. You will learn to defend against ReDoS, path traversal, CRLF injection, null byte attacks, and prototype pollution — all without a single npm package.
