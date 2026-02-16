# Track 02 / Lesson 05 — Secure Server Hardening

> A server that handles requests correctly is not the same as a server that handles attacks correctly. Hardening means anticipating every way an adversary can abuse your server — flooding it with requests, dripping bytes one at a time, smuggling hidden requests inside legitimate ones — and building defenses that cost nothing in normal operation but block abuse cold.

## Learning Objectives

- Implement sliding-window rate limiting using a `Map` of timestamp arrays with automatic cleanup
- Enforce request size limits via `Content-Length` validation and stream byte counting to prevent memory exhaustion
- Defend against slowloris attacks by configuring `server.headersTimeout`, `server.requestTimeout`, and per-connection timers
- Detect and prevent HTTP request smuggling by rejecting ambiguous `Transfer-Encoding` and `Content-Length` combinations
- Apply a production security hardening checklist: security headers, non-root execution, file permission auditing, environment variable hygiene, and secrets redaction in logs

---

## Rate Limiting with Map and Sliding Windows

Rate limiting prevents a single client from monopolizing server resources. The sliding window algorithm tracks timestamps of recent requests per client and rejects requests that exceed the allowed rate:

```js
'use strict';

const http = require('node:http');

class SlidingWindowRateLimiter {
  constructor(windowMs, maxRequests) {
    this.windowMs = windowMs;
    this.maxRequests = maxRequests;
    this.clients = new Map(); // key → [timestamp, timestamp, ...]

    // Periodically clean up expired entries to prevent memory leak
    this.cleanupInterval = setInterval(() => this.cleanup(), windowMs * 2);
    this.cleanupInterval.unref(); // Do not keep the process alive
  }

  // Returns { allowed: boolean, remaining: number, retryAfterMs: number }
  check(clientId) {
    const now = Date.now();
    const windowStart = now - this.windowMs;

    let timestamps = this.clients.get(clientId);

    if (!timestamps) {
      timestamps = [];
      this.clients.set(clientId, timestamps);
    }

    // Remove timestamps outside the current window
    // Since timestamps are appended in order, find the cutoff index
    let cutoff = 0;
    while (cutoff < timestamps.length && timestamps[cutoff] <= windowStart) {
      cutoff++;
    }
    if (cutoff > 0) {
      timestamps.splice(0, cutoff);
    }

    // Check if limit is exceeded
    if (timestamps.length >= this.maxRequests) {
      // Calculate when the oldest request in the window expires
      const retryAfterMs = timestamps[0] + this.windowMs - now;
      return {
        allowed: false,
        remaining: 0,
        retryAfterMs: Math.max(0, Math.ceil(retryAfterMs)),
      };
    }

    // Record this request
    timestamps.push(now);

    return {
      allowed: true,
      remaining: this.maxRequests - timestamps.length,
      retryAfterMs: 0,
    };
  }

  cleanup() {
    const now = Date.now();
    const windowStart = now - this.windowMs;

    for (const [clientId, timestamps] of this.clients) {
      // Remove all expired timestamps
      while (timestamps.length > 0 && timestamps[0] <= windowStart) {
        timestamps.shift();
      }
      // Remove empty entries
      if (timestamps.length === 0) {
        this.clients.delete(clientId);
      }
    }
  }

  destroy() {
    clearInterval(this.cleanupInterval);
    this.clients.clear();
  }
}

// Usage in an HTTP server
const limiter = new SlidingWindowRateLimiter(
  60 * 1000,  // 1 minute window
  100         // 100 requests per window
);

const server = http.createServer((req, res) => {
  // Use the remote IP as the client identifier
  // Behind a reverse proxy, use X-Forwarded-For (after validating the proxy)
  const clientId = req.socket.remoteAddress;

  const result = limiter.check(clientId);

  // Always set rate limit headers (even on allowed requests)
  res.setHeader('X-RateLimit-Limit', '100');
  res.setHeader('X-RateLimit-Remaining', String(result.remaining));

  if (!result.allowed) {
    const retryAfterSec = Math.ceil(result.retryAfterMs / 1000);
    res.setHeader('Retry-After', String(retryAfterSec));
    res.writeHead(429, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: 'Too many requests',
      retryAfterMs: result.retryAfterMs,
    }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'OK', remaining: result.remaining }));
});

server.listen(3000, () => {
  console.log('Rate-limited server on http://localhost:3000');
  console.log('Limit: 100 requests per 60 seconds per IP');
});
```

### Per-Route Rate Limiting

Different endpoints deserve different limits. Authentication endpoints need strict limits; health checks need loose ones:

```js
'use strict';

const http = require('node:http');

class PerRouteRateLimiter {
  constructor() {
    this.limiters = new Map(); // route → SlidingWindowRateLimiter
  }

  addRoute(route, windowMs, maxRequests) {
    this.limiters.set(route, {
      windowMs,
      maxRequests,
      clients: new Map(),
    });
  }

  check(route, clientId) {
    const config = this.limiters.get(route);
    if (!config) return { allowed: true, remaining: Infinity, retryAfterMs: 0 };

    const now = Date.now();
    const windowStart = now - config.windowMs;

    let timestamps = config.clients.get(clientId);
    if (!timestamps) {
      timestamps = [];
      config.clients.set(clientId, timestamps);
    }

    // Trim expired entries
    while (timestamps.length > 0 && timestamps[0] <= windowStart) {
      timestamps.shift();
    }

    if (timestamps.length >= config.maxRequests) {
      const retryAfterMs = timestamps[0] + config.windowMs - now;
      return { allowed: false, remaining: 0, retryAfterMs: Math.max(0, retryAfterMs) };
    }

    timestamps.push(now);
    return {
      allowed: true,
      remaining: config.maxRequests - timestamps.length,
      retryAfterMs: 0,
    };
  }
}

const rateLimiter = new PerRouteRateLimiter();

// Strict limits on authentication
rateLimiter.addRoute('/login', 15 * 60 * 1000, 5);    // 5 attempts per 15 min
rateLimiter.addRoute('/register', 60 * 60 * 1000, 3); // 3 per hour

// Moderate limits on API
rateLimiter.addRoute('/api', 60 * 1000, 60);           // 60 per minute

// Loose limits on static assets
rateLimiter.addRoute('/static', 60 * 1000, 500);       // 500 per minute

console.log('Per-route rate limiter configured');
console.log('  /login:    5 per 15 min');
console.log('  /register: 3 per hour');
console.log('  /api:      60 per minute');
console.log('  /static:   500 per minute');
```

---

## Request Size Limits

Without size limits, an attacker can send a multi-gigabyte POST body and exhaust server memory. Defense requires both `Content-Length` validation and stream-level byte counting:

```js
'use strict';

const http = require('node:http');

const MAX_BODY_BYTES = 1024 * 100; // 100 KB
const MAX_URL_LENGTH = 2048;
const MAX_HEADER_SIZE = 8192;       // Node.js default: 16 KB

function collectBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    // STEP 1: Check Content-Length header if present
    const contentLength = req.headers['content-length'];
    if (contentLength !== undefined) {
      const declaredSize = parseInt(contentLength, 10);
      if (Number.isNaN(declaredSize) || declaredSize < 0) {
        reject(new Error('Invalid Content-Length'));
        return;
      }
      if (declaredSize > maxBytes) {
        reject(new Error(`Content-Length ${declaredSize} exceeds limit of ${maxBytes}`));
        return;
      }
    }

    // STEP 2: Count actual bytes as they arrive
    // (Content-Length can be spoofed — always count)
    const chunks = [];
    let totalBytes = 0;

    req.on('data', (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        req.destroy();
        reject(new Error(`Request body exceeds limit of ${maxBytes} bytes`));
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      // STEP 3: Verify Content-Length matches actual bytes
      if (contentLength !== undefined) {
        const declared = parseInt(contentLength, 10);
        if (totalBytes !== declared) {
          reject(new Error(
            `Content-Length mismatch: declared ${declared}, received ${totalBytes}`
          ));
          return;
        }
      }
      resolve(Buffer.concat(chunks));
    });

    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  // Validate URL length
  if (req.url.length > MAX_URL_LENGTH) {
    res.writeHead(414, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'URI too long' }));
    return;
  }

  // Only collect body for methods that send one
  if (req.method === 'POST' || req.method === 'PUT' || req.method === 'PATCH') {
    try {
      const body = await collectBody(req, MAX_BODY_BYTES);

      let parsed;
      try {
        parsed = JSON.parse(body.toString());
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
        return;
      }

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ received: body.length, data: parsed }));
    } catch (err) {
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'OK' }));
});

// Limit maximum header size at the server level
server.maxHeaderSize = MAX_HEADER_SIZE;

server.listen(3000, () => {
  console.log('Server with size limits on http://localhost:3000');
  console.log(`  Max body:     ${MAX_BODY_BYTES} bytes`);
  console.log(`  Max URL:      ${MAX_URL_LENGTH} chars`);
  console.log(`  Max headers:  ${MAX_HEADER_SIZE} bytes`);
});
```

---

## Slowloris Protection

Slowloris is a denial-of-service attack that opens many connections and sends data very slowly — one byte at a time — to keep connections open indefinitely. Since Node.js has a limited number of sockets (determined by `server.maxConnections` and OS `ulimit`), this can exhaust all available connections.

```js
'use strict';

const http = require('node:http');
const net = require('node:net');

// DEFENSE: Configure all timeout parameters

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

// --- Timeout Configuration ---

// headersTimeout: Maximum time to receive the complete HTTP headers.
// If the client has not sent all headers within this time, the connection
// is destroyed. This is the primary defense against slowloris.
server.headersTimeout = 10 * 1000; // 10 seconds (default: 60000)

// requestTimeout: Maximum time for the ENTIRE request (headers + body).
// Protects against slow body attacks where headers arrive quickly
// but the body trickles in.
server.requestTimeout = 30 * 1000; // 30 seconds (default: 300000)

// keepAliveTimeout: How long to wait for a new request on a keep-alive
// connection after the previous request is complete.
server.keepAliveTimeout = 5 * 1000; // 5 seconds (default: 5000)

// timeout: General socket-level inactivity timeout.
// If no data is received or sent for this duration, the socket is destroyed.
server.timeout = 60 * 1000; // 60 seconds (default: 0 — no timeout!)

// maxHeadersCount: Maximum number of headers. Prevents attacks that send
// thousands of small headers to consume memory.
server.maxHeadersCount = 50; // (default: 2000)

// --- Connection Tracking ---

// Track active connections for monitoring and graceful shutdown
const connections = new Set();

server.on('connection', (socket) => {
  connections.add(socket);

  // Set a per-socket timeout as defense in depth
  socket.setTimeout(30 * 1000, () => {
    console.log(`Socket timeout: ${socket.remoteAddress}`);
    socket.destroy();
  });

  socket.on('close', () => {
    connections.delete(socket);
  });
});

// Log connection count every 10 seconds
setInterval(() => {
  console.log(`Active connections: ${connections.size}`);
}, 10000).unref();

server.listen(3000, () => {
  console.log('Hardened server on http://localhost:3000');
  console.log('Timeout configuration:');
  console.log(`  headersTimeout:   ${server.headersTimeout}ms`);
  console.log(`  requestTimeout:   ${server.requestTimeout}ms`);
  console.log(`  keepAliveTimeout: ${server.keepAliveTimeout}ms`);
  console.log(`  timeout:          ${server.timeout}ms`);
  console.log(`  maxHeadersCount:  ${server.maxHeadersCount}`);
});
```

### Simulating a Slowloris Attack (Educational)

```js
'use strict';

const net = require('node:net');

// This demonstrates what a slowloris attack looks like.
// Use ONLY against your own test servers.
function simulateSlowloris(host, port, connectionCount = 50) {
  console.log(`Simulating slowloris: ${connectionCount} slow connections to ${host}:${port}`);

  const sockets = [];

  for (let i = 0; i < connectionCount; i++) {
    const socket = net.createConnection({ host, port }, () => {
      // Send a partial HTTP request — headers never complete
      socket.write(`GET / HTTP/1.1\r\nHost: ${host}\r\n`);

      // Send one header every 5 seconds — just enough to keep alive
      const interval = setInterval(() => {
        try {
          socket.write(`X-Slowloris-${Date.now()}: ${i}\r\n`);
        } catch {
          clearInterval(interval);
        }
      }, 5000);

      socket.on('close', () => {
        clearInterval(interval);
        console.log(`Connection ${i} closed by server (defense worked)`);
      });

      socket.on('error', () => {
        clearInterval(interval);
      });
    });

    sockets.push(socket);
  }

  // Cleanup after 60 seconds
  setTimeout(() => {
    console.log('Cleaning up slowloris connections');
    for (const s of sockets) {
      s.destroy();
    }
  }, 60000);
}

// Uncomment to test against your hardened server:
// simulateSlowloris('localhost', 3000, 50);
// With headersTimeout = 10s, all connections will be killed within 10 seconds.
```

---

## HTTP Request Smuggling Defenses

HTTP request smuggling exploits ambiguity between `Content-Length` and `Transfer-Encoding: chunked` headers. If a front-end proxy and back-end server disagree on where one request ends and the next begins, an attacker can "smuggle" a hidden request:

```
POST / HTTP/1.1
Content-Length: 13
Transfer-Encoding: chunked

0\r\n
\r\n
GET /admin HTTP/1.1
Host: internal
```

The proxy might read `Content-Length: 13` and forward 13 bytes. The backend reads `Transfer-Encoding: chunked`, sees `0\r\n\r\n` (end of chunked), and treats the remaining bytes as a new request — `GET /admin`.

### Defense: Reject Ambiguous Requests

```js
'use strict';

const http = require('node:http');

function detectSmugglingAttempt(req) {
  const headers = req.rawHeaders;
  const transferEncoding = [];
  const contentLength = [];

  // Scan raw headers (not parsed headers) to catch duplicates
  for (let i = 0; i < headers.length; i += 2) {
    const name = headers[i].toLowerCase();
    const value = headers[i + 1];

    if (name === 'transfer-encoding') {
      transferEncoding.push(value);
    }
    if (name === 'content-length') {
      contentLength.push(value);
    }
  }

  // RULE 1: Reject requests with both Transfer-Encoding and Content-Length
  // RFC 7230 Section 3.3.3: If both are present, Transfer-Encoding wins,
  // but different implementations disagree. Reject to be safe.
  if (transferEncoding.length > 0 && contentLength.length > 0) {
    return 'Both Transfer-Encoding and Content-Length present';
  }

  // RULE 2: Reject duplicate Content-Length with different values
  if (contentLength.length > 1) {
    const unique = new Set(contentLength);
    if (unique.size > 1) {
      return 'Multiple Content-Length headers with different values';
    }
  }

  // RULE 3: Reject Transfer-Encoding values other than "chunked"
  for (const te of transferEncoding) {
    const normalized = te.trim().toLowerCase();
    if (normalized !== 'chunked') {
      return `Unexpected Transfer-Encoding value: ${te}`;
    }
  }

  // RULE 4: Reject Transfer-Encoding with obfuscation
  // Attackers try: "chunked ", " chunked", "Chunked", "chunk\ted"
  for (const te of transferEncoding) {
    if (te !== 'chunked') {
      return `Non-canonical Transfer-Encoding: "${te}"`;
    }
  }

  return null; // No smuggling detected
}

const server = http.createServer((req, res) => {
  const smuggling = detectSmugglingAttempt(req);

  if (smuggling) {
    console.error(`[SMUGGLING] ${req.socket.remoteAddress}: ${smuggling}`);
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Bad request' }));
    req.socket.destroy(); // Kill the connection entirely
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

server.listen(3000, () => {
  console.log('Smuggling-resistant server on http://localhost:3000');
});
```

---

## Security Headers Checklist

Every HTTP response should include security headers that instruct browsers to enable protections:

```js
'use strict';

const http = require('node:http');

// Apply all security headers as middleware
function addSecurityHeaders(res) {
  // Strict-Transport-Security: Force HTTPS for 1 year, including subdomains
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');

  // Content-Security-Policy: Restrict resource loading
  res.setHeader('Content-Security-Policy', [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; '));

  // X-Content-Type-Options: Prevent MIME sniffing
  res.setHeader('X-Content-Type-Options', 'nosniff');

  // X-Frame-Options: Prevent clickjacking (superseded by CSP frame-ancestors)
  res.setHeader('X-Frame-Options', 'DENY');

  // Referrer-Policy: Control referrer information leakage
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');

  // Permissions-Policy: Disable unnecessary browser features
  res.setHeader('Permissions-Policy', [
    'camera=()',
    'microphone=()',
    'geolocation=()',
    'payment=()',
    'usb=()',
  ].join(', '));

  // X-DNS-Prefetch-Control: Prevent DNS prefetching (privacy)
  res.setHeader('X-DNS-Prefetch-Control', 'off');

  // Cache-Control: Prevent caching of sensitive responses
  // (Override per-route for static assets that should be cached)
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, private');
  res.setHeader('Pragma', 'no-cache');

  // Remove headers that leak server information
  res.removeHeader('X-Powered-By');
}

const server = http.createServer((req, res) => {
  addSecurityHeaders(res);

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'secure' }));
});

server.listen(3000, () => {
  console.log('Server with security headers on http://localhost:3000');
  console.log('Test with: curl -I http://localhost:3000');
});
```

---

## Running as Non-Root

Node.js servers should never run as root. If an attacker achieves code execution, running as root gives them full system access.

```js
'use strict';

const http = require('node:http');
const os = require('node:os');

// Check and report process privileges
function auditProcessPrivileges() {
  const info = {
    uid: process.getuid?.() ?? 'N/A (Windows)',
    gid: process.getgid?.() ?? 'N/A (Windows)',
    username: os.userInfo().username,
    isRoot: process.getuid?.() === 0,
    pid: process.pid,
    platform: process.platform,
  };

  console.log('Process Privilege Audit:');
  console.log(`  User:     ${info.username} (uid=${info.uid}, gid=${info.gid})`);
  console.log(`  PID:      ${info.pid}`);
  console.log(`  Platform: ${info.platform}`);

  if (info.isRoot) {
    console.error('\n  WARNING: Running as root!');
    console.error('  This is a security risk. Use a non-root user.');
    console.error('  Solution: Create a dedicated service user:');
    console.error('    useradd --system --no-create-home --shell /usr/sbin/nologin nodeapp');
    console.error('    chown -R nodeapp:nodeapp /app');
    console.error('    su -s /bin/sh nodeapp -c "node server.js"');
  } else {
    console.log('  Status:   Non-root (good)');
  }

  return info;
}

// Drop privileges after binding to a privileged port
// (Some servers need to bind to port 80/443, which requires root)
function dropPrivileges(uid, gid) {
  if (process.getuid?.() !== 0) {
    console.log('Not running as root — no privileges to drop');
    return;
  }

  try {
    // Set group before user (setting user first may remove permission to set group)
    process.setgid(gid);
    process.setuid(uid);
    console.log(`Dropped privileges to uid=${uid}, gid=${gid}`);
  } catch (err) {
    console.error('Failed to drop privileges:', err.message);
    process.exit(1);
  }
}

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end('OK');
});

server.listen(3000, () => {
  auditProcessPrivileges();
  // If running as root to bind to port 80:
  // dropPrivileges(1001, 1001); // Use the uid/gid of your service user
});
```

---

## File Permission Auditing

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');

// Audit file permissions in a directory
function auditPermissions(dir) {
  const issues = [];

  function scan(currentDir) {
    let entries;
    try {
      entries = fs.readdirSync(currentDir, { withFileTypes: true });
    } catch (err) {
      issues.push({ path: currentDir, issue: `Cannot read: ${err.message}` });
      return;
    }

    for (const entry of entries) {
      const fullPath = path.join(currentDir, entry.name);

      // Skip node_modules and .git
      if (entry.name === 'node_modules' || entry.name === '.git') continue;

      try {
        const stats = fs.statSync(fullPath);
        const mode = stats.mode;

        // Check for world-writable files (o+w)
        if (mode & 0o002) {
          issues.push({ path: fullPath, issue: 'World-writable', mode: modeToString(mode) });
        }

        // Check for world-readable sensitive files
        const sensitive = ['.env', 'config.json', 'secrets.json', 'private.key'];
        if (sensitive.includes(entry.name) && (mode & 0o004)) {
          issues.push({ path: fullPath, issue: 'Sensitive file is world-readable', mode: modeToString(mode) });
        }

        // Check for executable permissions on non-script files
        if (entry.isFile() && (mode & 0o111) && !entry.name.endsWith('.sh')) {
          const ext = path.extname(entry.name);
          if (['.json', '.env', '.key', '.pem', '.crt'].includes(ext)) {
            issues.push({ path: fullPath, issue: 'Sensitive file has execute permission', mode: modeToString(mode) });
          }
        }

        // Recurse into directories
        if (entry.isDirectory()) {
          scan(fullPath);
        }
      } catch (err) {
        issues.push({ path: fullPath, issue: `stat failed: ${err.message}` });
      }
    }
  }

  scan(dir);
  return issues;
}

function modeToString(mode) {
  const perms = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'];
  const owner = perms[(mode >> 6) & 7];
  const group = perms[(mode >> 3) & 7];
  const other = perms[mode & 7];
  return `${owner}${group}${other}`;
}

// Run audit
const appDir = process.cwd();
const issues = auditPermissions(appDir);

if (issues.length === 0) {
  console.log('File permission audit: PASSED (no issues found)');
} else {
  console.log(`File permission audit: ${issues.length} issue(s) found\n`);
  for (const issue of issues) {
    console.log(`  [${issue.mode || '???'}] ${issue.path}`);
    console.log(`         ${issue.issue}`);
  }
}
```

---

## Environment Variable Hygiene

Environment variables are the most common secrets storage mechanism. Protect them:

```js
'use strict';

const crypto = require('node:crypto');

// RULE 1: Never log the full environment
function safeEnvLog() {
  // Whitelist of safe-to-log variables
  const SAFE_KEYS = new Set([
    'NODE_ENV', 'PORT', 'LOG_LEVEL', 'HOST', 'TZ',
  ]);

  const safeEnv = {};
  for (const key of Object.keys(process.env)) {
    if (SAFE_KEYS.has(key)) {
      safeEnv[key] = process.env[key];
    } else {
      // Indicate presence without revealing value
      safeEnv[key] = '***REDACTED***';
    }
  }

  console.log('Environment (redacted):', safeEnv);
}

// RULE 2: Validate required environment variables at startup
function validateEnv(required) {
  const missing = [];

  for (const { key, validate } of required) {
    const value = process.env[key];

    if (value === undefined || value === '') {
      missing.push(key);
      continue;
    }

    if (validate && !validate(value)) {
      console.error(`Invalid value for ${key}`);
      missing.push(key);
    }
  }

  if (missing.length > 0) {
    console.error(`Missing or invalid environment variables: ${missing.join(', ')}`);
    process.exit(1);
  }

  console.log(`All ${required.length} required environment variables are set`);
}

// RULE 3: Freeze process.env to prevent runtime modification
// (Optional — some libraries modify process.env)
function freezeEnv() {
  // Store a snapshot
  const envSnapshot = { ...process.env };

  // Periodically check for changes
  setInterval(() => {
    for (const key of Object.keys(process.env)) {
      if (process.env[key] !== envSnapshot[key]) {
        console.error(`WARNING: process.env.${key} was modified at runtime`);
      }
    }
    for (const key of Object.keys(envSnapshot)) {
      if (!(key in process.env)) {
        console.error(`WARNING: process.env.${key} was deleted at runtime`);
      }
    }
  }, 30000).unref();
}

// Example startup validation
validateEnv([
  { key: 'NODE_ENV', validate: v => ['production', 'staging', 'development'].includes(v) },
  { key: 'PORT', validate: v => /^\d+$/.test(v) && +v > 0 && +v < 65536 },
]);

safeEnvLog();
```

---

## Logging Secrets Redaction

Logs must never contain secrets. Build a redaction layer:

```js
'use strict';

// Redact sensitive fields from objects before logging
function createRedactedLogger() {
  const SENSITIVE_KEYS = new Set([
    'password', 'secret', 'token', 'apikey', 'api_key', 'apiKey',
    'authorization', 'cookie', 'session', 'creditcard', 'credit_card',
    'ssn', 'private_key', 'privateKey', 'accessToken', 'access_token',
    'refreshToken', 'refresh_token',
  ]);

  // Patterns to redact in string values
  const SENSITIVE_PATTERNS = [
    { pattern: /Bearer\s+[A-Za-z0-9\-._~+/]+=*/g, replacement: 'Bearer ***REDACTED***' },
    { pattern: /Basic\s+[A-Za-z0-9+/]+=*/g, replacement: 'Basic ***REDACTED***' },
    { pattern: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, replacement: '***EMAIL***' },
  ];

  function redact(obj, depth = 0) {
    if (depth > 10) return '[MAX_DEPTH]';
    if (obj === null || obj === undefined) return obj;

    if (typeof obj === 'string') {
      let result = obj;
      for (const { pattern, replacement } of SENSITIVE_PATTERNS) {
        result = result.replace(pattern, replacement);
      }
      return result;
    }

    if (Array.isArray(obj)) {
      return obj.map(item => redact(item, depth + 1));
    }

    if (typeof obj === 'object') {
      const result = {};
      for (const [key, value] of Object.entries(obj)) {
        if (SENSITIVE_KEYS.has(key.toLowerCase())) {
          result[key] = '***REDACTED***';
        } else {
          result[key] = redact(value, depth + 1);
        }
      }
      return result;
    }

    return obj;
  }

  return {
    info(message, data) {
      const timestamp = new Date().toISOString();
      const redacted = data ? redact(data) : '';
      console.log(`[${timestamp}] INFO: ${message}`, redacted ? JSON.stringify(redacted) : '');
    },
    error(message, data) {
      const timestamp = new Date().toISOString();
      const redacted = data ? redact(data) : '';
      console.error(`[${timestamp}] ERROR: ${message}`, redacted ? JSON.stringify(redacted) : '');
    },
    warn(message, data) {
      const timestamp = new Date().toISOString();
      const redacted = data ? redact(data) : '';
      console.warn(`[${timestamp}] WARN: ${message}`, redacted ? JSON.stringify(redacted) : '');
    },
  };
}

const logger = createRedactedLogger();

// Test redaction
logger.info('User login attempt', {
  username: 'alice',
  password: 'super-secret-123',
  headers: {
    authorization: 'Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature',
    'content-type': 'application/json',
  },
});
// password → ***REDACTED***
// authorization → Bearer ***REDACTED***

logger.info('API call', {
  url: '/api/users',
  apiKey: 'sk_live_abc123',
  response: { status: 200 },
});
// apiKey → ***REDACTED***
```

---

## Putting It All Together: Hardened Server

```js
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

// Combine all defenses into a single hardened server factory
function createHardenedServer(handler) {
  const server = http.createServer((req, res) => {
    // Security headers
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    res.setHeader('Cache-Control', 'no-store');

    // Request ID for tracing
    const requestId = crypto.randomUUID();
    res.setHeader('X-Request-Id', requestId);

    handler(req, res, requestId);
  });

  // Timeout configuration
  server.headersTimeout = 10000;
  server.requestTimeout = 30000;
  server.keepAliveTimeout = 5000;
  server.timeout = 60000;
  server.maxHeadersCount = 50;

  // Connection tracking
  const connections = new Set();
  server.on('connection', (socket) => {
    connections.add(socket);
    socket.on('close', () => connections.delete(socket));
  });

  // Graceful shutdown
  function shutdown(signal) {
    console.log(`Received ${signal} — shutting down gracefully`);
    server.close(() => {
      console.log('All connections closed');
      process.exit(0);
    });

    // Force close after 10 seconds
    setTimeout(() => {
      console.error('Forcing shutdown after timeout');
      for (const socket of connections) {
        socket.destroy();
      }
      process.exit(1);
    }, 10000).unref();
  }

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  return server;
}

const server = createHardenedServer((req, res, requestId) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'hardened', requestId }));
});

server.listen(3000, () => {
  console.log('Hardened server on http://localhost:3000');
});
```

---

## Key Takeaways

- Sliding-window rate limiting with `Map` and timestamp arrays provides per-client throttling without npm — configure different limits for authentication endpoints (strict) versus static assets (loose), and clean up expired entries periodically to prevent memory leaks
- Request size enforcement requires both `Content-Length` header validation AND stream-level byte counting — never trust the declared size alone, because attackers can lie about `Content-Length`
- Slowloris protection comes from aggressive timeout configuration: `headersTimeout` (10s), `requestTimeout` (30s), `keepAliveTimeout` (5s), and per-socket `setTimeout` — the defaults are too lenient for internet-facing servers
- HTTP request smuggling exploits ambiguity between `Transfer-Encoding` and `Content-Length` — reject any request that contains both headers, and reject non-canonical `Transfer-Encoding` values
- Defense in depth means combining rate limiting, size limits, timeouts, security headers, non-root execution, file permission auditing, environment variable validation, and log redaction — no single defense is sufficient on its own

## Next

This is the final lesson in Track 02 — Security Engineering. You now have a comprehensive security toolkit built entirely from Node.js core modules: threat modeling (STRIDE), TLS hardening, timing attack prevention, input validation, and server hardening. Apply these defenses together — a chain is only as strong as its weakest link.
