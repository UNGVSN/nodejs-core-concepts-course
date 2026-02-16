# Track 02 / Lesson 01 — Threat Modeling for Node.js

> Before you can defend a system, you have to understand how an attacker sees it. Threat modeling is the disciplined practice of enumerating everything that can go wrong — and then deciding what to do about it before it does.

## Learning Objectives

- Apply the STRIDE threat classification framework to a Node.js HTTP server architecture
- Identify the six primary attack surfaces in a typical Node.js deployment: HTTP endpoints, file system, environment variables, child processes, IPC channels, and event loop
- Rank threats by severity and likelihood using a risk matrix
- Build a threat model document for a real Node.js application
- Recognize the most common Node.js-specific threats that static analysis and linting will never catch

---

## Why Threat Modeling Matters

Most security effort in Node.js projects goes to two places: installing npm audit and adding `helmet`. Neither constitutes a security strategy. Threat modeling is the activity that produces a strategy.

A threat model answers three questions:

1. **What are we building?** — Decompose the system into components, data flows, and trust boundaries.
2. **What can go wrong?** — Systematically enumerate threats against each component.
3. **What are we going to do about it?** — Accept, mitigate, transfer, or eliminate each threat.

Without a threat model, security work is reactive — you patch after the breach. With one, security work is proactive — you design defenses before writing a single route handler.

---

## The STRIDE Framework

STRIDE was developed at Microsoft in 1999 and remains the most widely used threat classification system. Each letter represents a category of threat:

```
┌───────────────────────┬─────────────────────────────────────────────┐
│  Category             │  Description                                │
├───────────────────────┼─────────────────────────────────────────────┤
│  S — Spoofing         │  Pretending to be someone or something else │
│  T — Tampering        │  Modifying data or code without authority   │
│  R — Repudiation      │  Denying an action without proof otherwise  │
│  I — Information      │  Exposing data to unauthorized parties      │
│      Disclosure       │                                             │
│  D — Denial of        │  Making the system unavailable              │
│      Service          │                                             │
│  E — Elevation of     │  Gaining capabilities beyond authorization  │
│      Privilege        │                                             │
└───────────────────────┴─────────────────────────────────────────────┘
```

Each category maps to a security property that it violates:

| Threat             | Security Property |
|--------------------|-------------------|
| Spoofing           | Authentication    |
| Tampering          | Integrity         |
| Repudiation        | Non-repudiation   |
| Info Disclosure    | Confidentiality   |
| Denial of Service  | Availability      |
| Elevation of Priv  | Authorization     |

---

## Decomposing a Node.js Application

Before applying STRIDE, you decompose the system into its components and data flows. Here is a minimal Node.js HTTP server with its trust boundaries:

```
┌────────────────────────────────────────────────────────────────┐
│  INTERNET (untrusted)                                          │
│                                                                │
│     Browser / API Client                                       │
│         │                                                      │
│         ▼                                                      │
│  ┌─── TRUST BOUNDARY ──────────────────────────────────────┐   │
│  │                                                          │  │
│  │  HTTP Server (node:http)                                 │  │
│  │    ├── Route Handler                                     │  │
│  │    ├── Body Parser                                       │  │
│  │    ├── Static File Server (node:fs)                      │  │
│  │    └── Logger (node:fs)                                  │  │
│  │                                                          │  │
│  │  ┌─── TRUST BOUNDARY ──────────────────────────────┐     │  │
│  │  │  Child Process (node:child_process)              │     │  │
│  │  │  Environment Variables (process.env)             │     │  │
│  │  │  File System (/etc, /tmp, app data)              │     │  │
│  │  └──────────────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Every arrow crossing a trust boundary is an attack surface.

---

## Applying STRIDE to Node.js

### S — Spoofing

Spoofing means impersonating another entity. In a Node.js server context:

```js
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

// THREAT: Spoofed authentication tokens
// An attacker sends a forged session cookie or JWT
// to impersonate a legitimate user.

function verifyToken(token, secret) {
  // BAD: Simple string match — does not verify cryptographic signature
  // return token === expectedToken;

  // GOOD: HMAC-based token verification
  const [payload, signature] = token.split('.');
  if (!payload || !signature) return null;

  const expected = crypto
    .createHmac('sha256', secret)
    .update(payload)
    .digest('hex');

  // Use timing-safe comparison (covered in Lesson 03)
  const sigBuf = Buffer.from(signature, 'hex');
  const expBuf = Buffer.from(expected, 'hex');

  if (sigBuf.length !== expBuf.length) return null;
  if (!crypto.timingSafeEqual(sigBuf, expBuf)) return null;

  return JSON.parse(Buffer.from(payload, 'base64url').toString());
}

// THREAT: IP address spoofing via X-Forwarded-For
// Attackers inject fake IP addresses in proxy headers.
function getClientIp(req) {
  // BAD: Trusting X-Forwarded-For blindly
  // return req.headers['x-forwarded-for']?.split(',')[0];

  // BETTER: Only trust the header if behind a known reverse proxy
  const trustedProxies = new Set(['127.0.0.1', '10.0.0.1']);
  const remoteAddr = req.socket.remoteAddress;

  if (trustedProxies.has(remoteAddr)) {
    const forwarded = req.headers['x-forwarded-for'];
    if (forwarded) {
      return forwarded.split(',').map(s => s.trim()).pop();
    }
  }

  return remoteAddr;
}
```

Spoofing threats in Node.js include:
- Forged authentication cookies/tokens
- Spoofed `X-Forwarded-For` headers
- DNS rebinding attacks
- Self-signed certificates accepted without verification

### T — Tampering

Tampering means unauthorized modification of data in transit or at rest:

```js
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');

// THREAT: Tampered request body
// Attacker modifies JSON payload in transit (without TLS)
// or tampers with data stored on disk.

// Mitigation: HMAC-sign critical data before storing
function signData(data, key) {
  const payload = JSON.stringify(data);
  const hmac = crypto
    .createHmac('sha256', key)
    .update(payload)
    .digest('hex');

  return { payload, hmac };
}

function verifyData(payload, hmac, key) {
  const expected = crypto
    .createHmac('sha256', key)
    .update(payload)
    .digest('hex');

  const hmacBuf = Buffer.from(hmac, 'hex');
  const expectedBuf = Buffer.from(expected, 'hex');

  if (hmacBuf.length !== expectedBuf.length) return false;
  return crypto.timingSafeEqual(hmacBuf, expectedBuf);
}

// THREAT: File system tampering — symlink attacks
// An attacker creates a symlink at /tmp/app-cache pointing to /etc/passwd.
// If the application follows symlinks, it reads or overwrites sensitive files.
function safeReadFile(filePath, rootDir) {
  const resolved = path.resolve(rootDir, filePath);

  // Verify the resolved path is inside the root directory
  if (!resolved.startsWith(path.resolve(rootDir) + path.sep)) {
    throw new Error('Path traversal detected');
  }

  // Use lstat to detect symlinks before following them
  const stats = fs.lstatSync(resolved);
  if (stats.isSymbolicLink()) {
    throw new Error('Symlink detected — refusing to follow');
  }

  return fs.readFileSync(resolved);
}
```

### R — Repudiation

Repudiation means an attacker (or user) can deny performing an action because no audit trail exists:

```js
'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');

// THREAT: No audit log — users deny performing actions
// Mitigation: Structured, tamper-evident audit logging

class AuditLogger {
  constructor(logPath) {
    this.logPath = logPath;
    this.stream = fs.createWriteStream(logPath, { flags: 'a' });
    this.prevHash = '0'.repeat(64);
  }

  log(action, userId, details) {
    const entry = {
      timestamp: new Date().toISOString(),
      action,
      userId,
      details,
      prevHash: this.prevHash,
    };

    // Chain hashes so tampering with any entry breaks the chain
    const entryStr = JSON.stringify(entry);
    const hash = crypto
      .createHash('sha256')
      .update(entryStr)
      .digest('hex');

    this.prevHash = hash;

    this.stream.write(JSON.stringify({ ...entry, hash }) + '\n');
  }

  // Verify the entire log chain has not been tampered with
  verifyChain() {
    const lines = fs.readFileSync(this.logPath, 'utf8')
      .trim()
      .split('\n')
      .map(line => JSON.parse(line));

    let expectedPrev = '0'.repeat(64);

    for (const entry of lines) {
      if (entry.prevHash !== expectedPrev) {
        return { valid: false, brokenAt: entry.timestamp };
      }

      const { hash, ...rest } = entry;
      const computed = crypto
        .createHash('sha256')
        .update(JSON.stringify(rest))
        .digest('hex');

      if (computed !== hash) {
        return { valid: false, brokenAt: entry.timestamp };
      }

      expectedPrev = hash;
    }

    return { valid: true, entries: lines.length };
  }
}
```

### I — Information Disclosure

Information disclosure happens when the application leaks sensitive data:

```js
'use strict';

const http = require('node:http');

// THREAT: Stack traces in error responses
// Default behavior: exceptions leak file paths, line numbers, and internal state.

const server = http.createServer((req, res) => {
  try {
    // Application logic that may throw
    handleRoute(req, res);
  } catch (err) {
    // BAD: Sending the raw error to the client
    // res.writeHead(500);
    // res.end(err.stack);

    // GOOD: Log internally, return generic message
    console.error(`[${new Date().toISOString()}] Internal error:`, err.message);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Internal server error' }));
  }
});

// THREAT: Server header reveals Node.js version
// By default, Node.js does not add a Server header,
// but many frameworks do. Verify yours does not.

// THREAT: Environment variables leaked via process inspection
// Never log process.env — it often contains secrets.
function safeLogEnv() {
  const SAFE_KEYS = ['NODE_ENV', 'PORT', 'LOG_LEVEL'];
  const filtered = {};
  for (const key of SAFE_KEYS) {
    if (process.env[key]) {
      filtered[key] = process.env[key];
    }
  }
  console.log('Environment:', filtered);
}

// THREAT: Directory listing exposes file structure
// Never serve directory listings in production.
// Always check that a requested path resolves to a file, not a directory.

function handleRoute(req, res) {
  res.writeHead(200);
  res.end('OK');
}
```

### D — Denial of Service

Denial of service in Node.js is particularly dangerous because a single thread processes all requests:

```js
'use strict';

const http = require('node:http');

// THREAT: Event loop starvation
// A single synchronous computation blocks ALL other requests.

// BAD: Synchronous regex on user input
function isValidEmail_BAD(email) {
  // Catastrophic backtracking regex — a single crafted input
  // can block the event loop for minutes
  return /^([a-zA-Z0-9]+\.)*[a-zA-Z0-9]+@([a-zA-Z0-9]+\.)+[a-zA-Z]{2,}$/.test(email);
}

// GOOD: Simple, non-backtracking check
function isValidEmail_GOOD(email) {
  if (typeof email !== 'string') return false;
  if (email.length > 254) return false;  // RFC 5321 limit
  const atIndex = email.indexOf('@');
  if (atIndex < 1 || atIndex === email.length - 1) return false;
  if (email.indexOf('@', atIndex + 1) !== -1) return false;
  return true;
}

// THREAT: Unbounded request body
// Without size limits, an attacker sends a 10 GB POST body
// and exhausts server memory.

// THREAT: Slowloris — keep connections open indefinitely
// Attacker opens hundreds of connections, sends headers one byte at a time,
// never completing the request. The server holds all connections open.

// Mitigation: Set explicit timeouts
const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('OK');
});

server.headersTimeout = 20000;   // 20s to receive all headers
server.requestTimeout = 30000;   // 30s for the entire request
server.keepAliveTimeout = 5000;  // 5s idle before closing keep-alive
server.maxHeadersCount = 50;     // Limit number of headers

server.listen(3000);
```

### E — Elevation of Privilege

Elevation of privilege means gaining capabilities the user should not have:

```js
'use strict';

const { execSync } = require('node:child_process');

// THREAT: Command injection via child_process.exec
// exec() runs input through a shell — any shell metacharacter
// in user input becomes a command.

function getFileSize_BAD(filename) {
  // If filename is "; rm -rf /", this executes arbitrary commands
  return execSync(`stat -f%z "${filename}"`).toString().trim();
}

function getFileSize_GOOD(filename) {
  // execFileSync bypasses the shell entirely — no metacharacters interpreted
  const { execFileSync } = require('node:child_process');
  return execFileSync('stat', ['-f%z', filename]).toString().trim();
}

// THREAT: Prototype pollution via __proto__
// Attacker sends JSON with __proto__ key, polluting Object.prototype.
function mergeConfig_BAD(defaults, userInput) {
  // If userInput is {"__proto__": {"isAdmin": true}},
  // every object in the process now has isAdmin === true
  return { ...defaults, ...userInput };
}

function mergeConfig_GOOD(defaults, userInput) {
  const result = Object.create(null); // No prototype chain
  for (const key of Object.keys(defaults)) {
    result[key] = defaults[key];
  }
  // Whitelist only expected keys from user input
  const ALLOWED_KEYS = ['theme', 'language', 'pageSize'];
  for (const key of ALLOWED_KEYS) {
    if (key in userInput && typeof userInput[key] === typeof defaults[key]) {
      result[key] = userInput[key];
    }
  }
  return result;
}
```

---

## Identifying Node.js Attack Surfaces

A Node.js process has six primary attack surfaces:

### 1. HTTP Endpoints

Every route is an entry point. Attack vectors include malformed headers, oversized bodies, path traversal in URLs, and HTTP request smuggling.

### 2. File System

Any `fs.readFile()` or `fs.writeFile()` call that incorporates user input is a potential path traversal attack. Symlinks, race conditions (TOCTOU), and file descriptor exhaustion are additional concerns.

### 3. Environment Variables

`process.env` is often the primary secrets store in production. If an attacker can read environment variables (via server-side template injection, `require` hijacking, or debug endpoints), they gain access to database credentials, API keys, and encryption secrets.

### 4. Child Processes

`exec()`, `execSync()`, and `spawn()` with `shell: true` interpret shell metacharacters. Any user-controlled string passed to these functions enables command injection.

### 5. IPC Channels

`process.send()` and `worker.postMessage()` pass serialized objects between processes or threads. Malicious or oversized messages can exhaust memory or exploit deserialization bugs.

### 6. Event Loop

The single-threaded event loop is itself an attack surface. Any operation that blocks synchronously — a heavy regex, a large `JSON.parse`, or a `readFileSync` on a slow mount — denies service to all other connections.

---

## Building a Threat Matrix

A threat matrix combines STRIDE categories with attack surfaces to systematically identify threats:

```js
'use strict';

// Build a threat matrix programmatically
// This is a documentation tool — run it to generate your threat model.

const STRIDE = ['Spoofing', 'Tampering', 'Repudiation',
                'Information Disclosure', 'Denial of Service',
                'Elevation of Privilege'];

const SURFACES = ['HTTP Endpoints', 'File System', 'Environment Variables',
                  'Child Processes', 'IPC Channels', 'Event Loop'];

const threats = {
  'HTTP Endpoints': {
    'Spoofing':               'Forged auth tokens, IP spoofing via X-Forwarded-For',
    'Tampering':              'Modified request body without TLS, MITM',
    'Repudiation':            'No access logs, no request correlation IDs',
    'Information Disclosure': 'Stack traces in 500 responses, verbose headers',
    'Denial of Service':      'Slowloris, large bodies, ReDoS, request smuggling',
    'Elevation of Privilege': 'Missing authorization checks, IDOR',
  },
  'File System': {
    'Spoofing':               'Symlink following to impersonate files',
    'Tampering':              'TOCTOU race condition on file checks',
    'Repudiation':            'File changes without audit trail',
    'Information Disclosure': 'Path traversal reads /etc/passwd',
    'Denial of Service':      'fd exhaustion from leaked file handles',
    'Elevation of Privilege': 'Writing to executable paths or config files',
  },
  'Environment Variables': {
    'Spoofing':               'Injecting env vars via .env file manipulation',
    'Tampering':              'Overwriting NODE_OPTIONS to inject code',
    'Repudiation':            'No log of env var changes at runtime',
    'Information Disclosure': 'Logging process.env leaks secrets',
    'Denial of Service':      'Setting NODE_OPTIONS=--max-old-space-size=10',
    'Elevation of Privilege': 'NODE_OPTIONS=--require=malicious.js',
  },
  'Child Processes': {
    'Spoofing':               'N/A for most cases',
    'Tampering':              'Modifying PATH so exec resolves to wrong binary',
    'Repudiation':            'Child process output not logged',
    'Information Disclosure': 'Child inherits parent env (all secrets)',
    'Denial of Service':      'Fork bomb via uncontrolled child spawning',
    'Elevation of Privilege': 'Command injection via exec() with user input',
  },
  'IPC Channels': {
    'Spoofing':               'Unauthorized process connects to IPC socket',
    'Tampering':              'Modified messages in transit (local pipe)',
    'Repudiation':            'No message-level logging on IPC',
    'Information Disclosure': 'Sensitive data in IPC messages without encryption',
    'Denial of Service':      'Flooding IPC channel with large messages',
    'Elevation of Privilege': 'Deserialization of untrusted IPC payloads',
  },
  'Event Loop': {
    'Spoofing':               'N/A',
    'Tampering':              'Monkey-patching core modules at runtime',
    'Repudiation':            'N/A',
    'Information Disclosure': 'Timing side channels leak secret lengths',
    'Denial of Service':      'Blocking sync calls, ReDoS, JSON.parse bombs',
    'Elevation of Privilege': 'Prototype pollution via JSON.parse',
  },
};

// Generate readable threat matrix
function printThreatMatrix() {
  for (const surface of SURFACES) {
    console.log(`\n=== ${surface} ===`);
    for (const category of STRIDE) {
      const threat = threats[surface]?.[category] || 'N/A';
      console.log(`  [${category.padEnd(22)}] ${threat}`);
    }
  }
}

printThreatMatrix();
```

---

## Risk Ranking: Severity x Likelihood

Not every threat deserves equal attention. Rank each threat by two dimensions:

```
Severity:    1 (cosmetic) → 2 (degraded) → 3 (data loss) → 4 (breach) → 5 (total compromise)
Likelihood:  1 (theoretical) → 2 (difficult) → 3 (moderate) → 4 (easy) → 5 (trivial)

Risk Score = Severity × Likelihood
```

```js
'use strict';

// Example: Ranking threats for a Node.js REST API

const riskAssessment = [
  { threat: 'ReDoS on email validation',         severity: 4, likelihood: 4, score: 16 },
  { threat: 'Command injection via exec()',       severity: 5, likelihood: 3, score: 15 },
  { threat: 'Stack trace in 500 response',        severity: 3, likelihood: 5, score: 15 },
  { threat: 'Path traversal on static files',     severity: 4, likelihood: 3, score: 12 },
  { threat: 'Missing rate limiting',              severity: 3, likelihood: 4, score: 12 },
  { threat: 'Prototype pollution via JSON body',  severity: 5, likelihood: 2, score: 10 },
  { threat: 'Unbounded request body size',        severity: 3, likelihood: 3, score: 9  },
  { threat: 'Timing attack on token comparison',  severity: 4, likelihood: 2, score: 8  },
  { threat: 'TOCTOU race on file access',         severity: 3, likelihood: 2, score: 6  },
  { threat: 'DNS rebinding attack',               severity: 3, likelihood: 1, score: 3  },
];

// Sort by risk score descending — highest priority first
riskAssessment.sort((a, b) => b.score - a.score);

console.log('THREAT PRIORITY LIST');
console.log('─'.repeat(70));
for (const item of riskAssessment) {
  const bar = '█'.repeat(item.score);
  console.log(
    `  [${String(item.score).padStart(2)}] ${item.threat.padEnd(42)} ${bar}`
  );
}
```

Threats with a score of 12 or above should be addressed before deployment. Threats scoring 6-11 belong in the next sprint. Threats below 6 are accepted risks — document them and revisit quarterly.

---

## Node.js-Specific Threats Beyond STRIDE

Some threats are unique to Node.js and do not map cleanly to STRIDE:

### Supply Chain Attacks (npm)

While this course uses zero npm packages, real-world projects depend on hundreds. A compromised dependency can execute arbitrary code during `npm install` (via `postinstall` scripts) or at runtime. This is outside STRIDE because the threat originates from trusted code.

### Event Loop Starvation

Unlike traditional thread-per-request servers, a single blocked callback in Node.js blocks every client. This makes DoS attacks disproportionately effective against Node.js.

### JSON.parse Bombs

A deeply nested JSON object (`{"a":{"a":{"a":...}}}` 1000 levels deep) can crash `JSON.parse` with a stack overflow. Limit nesting depth before parsing:

```js
'use strict';

function safeJsonParse(str, maxDepth = 20) {
  let depth = 0;
  for (let i = 0; i < str.length; i++) {
    if (str[i] === '{' || str[i] === '[') {
      depth++;
      if (depth > maxDepth) {
        throw new Error(`JSON nesting exceeds maximum depth of ${maxDepth}`);
      }
    } else if (str[i] === '}' || str[i] === ']') {
      depth--;
    }
  }
  return JSON.parse(str);
}

// Test with normal input
console.log(safeJsonParse('{"name": "Alice", "age": 30}'));

// Test with deeply nested input
try {
  const bomb = '{' .repeat(25) + '"x": 1' + '}'.repeat(25);
  safeJsonParse(bomb, 20);
} catch (err) {
  console.log('Blocked:', err.message);
  // Blocked: JSON nesting exceeds maximum depth of 20
}
```

---

## Putting It All Together: A Threat Model Document

Every production Node.js application should have a threat model document. Here is the template:

```
# Threat Model: [Application Name]
# Date: [YYYY-MM-DD]
# Author: [Name]
# Reviewed by: [Name]

## 1. System Description
   - What does the application do?
   - What data does it process?
   - What trust boundaries exist?

## 2. Data Flow Diagram
   - Components, data stores, external entities
   - Arrows showing data movement
   - Trust boundaries marked

## 3. Threat Enumeration (STRIDE per component)
   - Each component × each STRIDE category
   - Documented in threat matrix format

## 4. Risk Assessment
   - Each threat ranked by Severity × Likelihood
   - Priority list sorted by risk score

## 5. Mitigations
   - For each threat scoring >= 12: specific mitigation
   - Code references, configuration changes, architecture decisions
   - Owner and deadline for each mitigation

## 6. Accepted Risks
   - Threats below threshold with justification
   - Review schedule (quarterly)

## 7. Revision History
   - Date, author, changes
```

---

## Key Takeaways

- STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege) provides a systematic vocabulary for enumerating threats against any Node.js application
- Node.js has six primary attack surfaces: HTTP endpoints, file system, environment variables, child processes, IPC channels, and the event loop itself
- Risk ranking (Severity times Likelihood) transforms an overwhelming list of threats into a prioritized action plan
- Node.js-specific threats — event loop starvation, prototype pollution, JSON.parse bombs, and command injection via `exec()` — deserve special attention because of the single-threaded architecture
- A threat model is a living document: create it before v1, update it every quarter, and review it after every security incident

## Next

In [Lesson 02 — TLS Deep Dive](lesson-02-tls-deep-dive.md), we move from identifying threats to implementing the most important cryptographic defense: Transport Layer Security. You will learn how certificate chains work, how to configure cipher suites, and how TLS 1.3 eliminates an entire class of handshake attacks.
