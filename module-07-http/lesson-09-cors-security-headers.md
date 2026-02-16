# Module 07 / Lesson 09 — CORS & Security Headers

> Your API works perfectly when you test it from the same origin. Then a frontend developer on a different domain tries to call it and gets a cryptic browser error: "blocked by CORS policy." Meanwhile, your server happily serves responses with no security headers, leaving users vulnerable to clickjacking, MIME sniffing, and cross-site scripting. This lesson teaches you to control cross-origin access deliberately and harden every response your server sends.

## Learning Objectives

- Explain the Same-Origin Policy and why browsers enforce it for JavaScript-initiated requests
- Distinguish simple requests from preflight requests and implement both CORS flows from scratch
- Configure CORS headers correctly for wildcard, specific-origin, and credentialed scenarios
- Apply a comprehensive set of security headers (HSTS, CSP, X-Frame-Options, and more) to every response
- Build a rate limiter using a sliding window Map to protect endpoints from abuse

---

## The Same-Origin Policy

The **Same-Origin Policy** (SOP) is a browser security mechanism. It prevents JavaScript on one origin from reading responses from a different origin.

Two URLs have the **same origin** if and only if they share the same **protocol**, **hostname**, and **port**:

| URL A | URL B | Same Origin? | Why |
|---|---|---|---|
| `https://app.com/api` | `https://app.com/users` | Yes | Same scheme, host, port |
| `https://app.com` | `http://app.com` | No | Different scheme |
| `https://app.com` | `https://api.app.com` | No | Different host |
| `https://app.com` | `https://app.com:8080` | No | Different port |
| `https://app.com:443` | `https://app.com` | Yes | 443 is default for HTTPS |

The SOP applies to:
- `fetch()` and `XMLHttpRequest` calls
- Canvas and WebGL cross-origin image reads
- Web fonts loaded via `@font-face`

The SOP does **not** block:
- `<img>` tags loading cross-origin images (but JS cannot read pixel data)
- `<script>` tags loading cross-origin scripts (JSONP exploits this)
- `<form>` submissions to cross-origin URLs (the browser navigates)
- `<link>` tags loading cross-origin stylesheets

---

## What Is CORS?

**CORS** (Cross-Origin Resource Sharing) is the mechanism that lets servers opt in to cross-origin access. The server tells the browser, through HTTP headers, which origins, methods, and headers are allowed.

Without CORS headers, the browser blocks the JavaScript code from reading the response. The request may still reach the server — CORS is enforced by the browser, not the server.

```
Browser (origin: https://frontend.com)           Server (https://api.com)
  │                                                  │
  │── GET /data ──────────────────────────────────▶  │
  │   Origin: https://frontend.com                   │
  │                                                  │
  │◀── 200 OK ───────────────────────────────────── │
  │   Access-Control-Allow-Origin: https://frontend.com
  │   { "data": "..." }                             │
  │                                                  │
  │   Browser checks: response origin header matches │
  │   ✓ JavaScript can read the response             │
```

---

## Simple Requests vs Preflight Requests

The browser categorizes cross-origin requests into two types.

### Simple Requests

A request is "simple" (no preflight) if all of these are true:

- Method is `GET`, `HEAD`, or `POST`
- Only "safe" headers: `Accept`, `Accept-Language`, `Content-Language`, `Content-Type`
- `Content-Type` is one of: `application/x-www-form-urlencoded`, `multipart/form-data`, `text/plain`

### Preflight Requests

If any condition above is violated — custom headers (`Authorization`, `X-Request-Id`), methods like `PUT` or `DELETE`, or `Content-Type: application/json` — the browser sends a **preflight** `OPTIONS` request first:

```
Browser                                          Server
  │                                                │
  │── OPTIONS /api/users ────────────────────────▶ │  Preflight
  │   Origin: https://frontend.com                 │
  │   Access-Control-Request-Method: DELETE        │
  │   Access-Control-Request-Headers: Authorization│
  │                                                │
  │◀── 204 No Content ─────────────────────────── │
  │   Access-Control-Allow-Origin: https://frontend.com
  │   Access-Control-Allow-Methods: GET, POST, DELETE
  │   Access-Control-Allow-Headers: Authorization  │
  │   Access-Control-Max-Age: 86400                │
  │                                                │
  │── DELETE /api/users/42 ──────────────────────▶ │  Actual request
  │   Origin: https://frontend.com                 │
  │   Authorization: Bearer token123               │
  │                                                │
  │◀── 200 OK ───────────────────────────────────  │
  │   Access-Control-Allow-Origin: https://frontend.com
  │   { "deleted": true }                          │
```

---

## CORS Headers Reference

| Header | Direction | Purpose |
|---|---|---|
| `Access-Control-Allow-Origin` | Response | Which origin(s) can read the response |
| `Access-Control-Allow-Methods` | Response (preflight) | Which HTTP methods are allowed |
| `Access-Control-Allow-Headers` | Response (preflight) | Which request headers are allowed |
| `Access-Control-Max-Age` | Response (preflight) | How long (seconds) to cache the preflight |
| `Access-Control-Allow-Credentials` | Response | Whether cookies/auth headers are allowed |
| `Access-Control-Expose-Headers` | Response | Which response headers JS can read |
| `Origin` | Request | The requesting page's origin (set by browser) |
| `Access-Control-Request-Method` | Request (preflight) | The method the actual request will use |
| `Access-Control-Request-Headers` | Request (preflight) | The headers the actual request will send |

---

## Building CORS Middleware from Scratch

```javascript
'use strict';

const http = require('node:http');

/**
 * CORS configuration.
 */
const corsConfig = {
  allowedOrigins: new Set([
    'https://frontend.com',
    'https://admin.frontend.com',
    'http://localhost:3001',
  ]),
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-Id'],
  exposedHeaders: ['X-Request-Id', 'X-Response-Time'],
  maxAge: 86400,         // 24 hours
  credentials: true,
};

/**
 * Apply CORS headers to the response.
 * Returns true if this was a preflight request (caller should stop processing).
 */
function handleCORS(req, res) {
  const origin = req.headers.origin;

  // No Origin header = same-origin request or non-browser client
  if (!origin) return false;

  // Check if the origin is allowed
  if (!corsConfig.allowedOrigins.has(origin)) {
    // Do NOT set any CORS headers — browser will block the response
    return req.method === 'OPTIONS';
  }

  // Set the origin (never use * when credentials are true)
  res.setHeader('Access-Control-Allow-Origin', origin);

  // Vary by Origin so caches do not serve wrong CORS headers
  res.setHeader('Vary', 'Origin');

  // Allow credentials (cookies, Authorization header)
  if (corsConfig.credentials) {
    res.setHeader('Access-Control-Allow-Credentials', 'true');
  }

  // Expose headers that JavaScript can read
  if (corsConfig.exposedHeaders.length > 0) {
    res.setHeader('Access-Control-Expose-Headers', corsConfig.exposedHeaders.join(', '));
  }

  // Handle preflight
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', corsConfig.allowedMethods.join(', '));
    res.setHeader('Access-Control-Allow-Headers', corsConfig.allowedHeaders.join(', '));
    res.setHeader('Access-Control-Max-Age', String(corsConfig.maxAge));

    // End the preflight with 204 No Content
    res.writeHead(204);
    res.end();
    return true; // Signal that the response is complete
  }

  return false;
}

const server = http.createServer((req, res) => {
  // Apply CORS first
  const isPreflight = handleCORS(req, res);
  if (isPreflight) return;

  // Normal request handling
  if (req.url === '/api/data' && req.method === 'GET') {
    const body = JSON.stringify({ message: 'Cross-origin data', timestamp: Date.now() });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  if (req.url === '/api/data' && req.method === 'DELETE') {
    const body = JSON.stringify({ deleted: true });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found\n');
});

server.listen(3000, () => {
  console.log('CORS-enabled server on port 3000');
});
```

---

## Wildcard vs Specific Origins

Using `Access-Control-Allow-Origin: *` (wildcard) means any origin can read the response. This has important restrictions:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const origin = req.headers.origin;

  if (req.method === 'OPTIONS') {
    // Wildcard preflight — open to all origins
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Max-Age': '3600',
    });
    return res.end();
  }

  // Wildcard for simple GET requests
  res.setHeader('Access-Control-Allow-Origin', '*');

  const body = JSON.stringify({ public: true });
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(3000);
```

**Wildcard limitations:**

| Feature | `*` (wildcard) | Specific origin |
|---|---|---|
| Cookies sent | No | Yes (with `Allow-Credentials: true`) |
| `Authorization` header | No (preflight fails) | Yes |
| `Set-Cookie` in response | Ignored by browser | Respected |
| Caching | Safe (no Vary needed) | Must set `Vary: Origin` |

**Rule of thumb:** Use `*` only for truly public, read-only APIs. For anything involving authentication, always reflect the specific origin.

---

## Credentialed Requests

When the frontend uses `credentials: 'include'` with `fetch()`, the browser sends cookies and checks stricter CORS rules:

```javascript
'use strict';

const http = require('node:http');

const ALLOWED_ORIGINS = new Set([
  'https://app.example.com',
  'http://localhost:3001',
]);

const server = http.createServer((req, res) => {
  const origin = req.headers.origin;

  if (origin && ALLOWED_ORIGINS.has(origin)) {
    // For credentialed requests:
    // 1. Origin MUST be specific (not *)
    // 2. Allow-Credentials MUST be 'true'
    // 3. Vary MUST include Origin
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }

  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Max-Age', '86400');
    res.writeHead(204);
    return res.end();
  }

  // Read cookies from the request
  const cookies = parseCookies(req.headers.cookie || '');
  const sessionId = cookies.session_id;

  if (req.url === '/api/profile' && req.method === 'GET') {
    if (!sessionId) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'No session' }));
    }

    const body = JSON.stringify({ user: 'alice', session: sessionId });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  if (req.url === '/api/login' && req.method === 'POST') {
    // Set a session cookie
    res.setHeader('Set-Cookie', 'session_id=abc123; HttpOnly; SameSite=None; Secure; Path=/');
    const body = JSON.stringify({ loggedIn: true });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found\n');
});

function parseCookies(cookieHeader) {
  const cookies = {};
  for (const pair of cookieHeader.split(';')) {
    const [key, ...rest] = pair.trim().split('=');
    if (key) cookies[key] = rest.join('=');
  }
  return cookies;
}

server.listen(3000, () => {
  console.log('Credentialed CORS server on port 3000');
});
```

---

## Security Headers Beyond CORS

CORS controls who can read your responses. Security headers control how browsers treat your content. Every production server should set these.

### The Headers

```
┌──────────────────────────────────────────────────────────────┐
│  Security Header                  │  Protects Against        │
├──────────────────────────────────────────────────────────────┤
│  Strict-Transport-Security (HSTS) │  Protocol downgrade      │
│  X-Content-Type-Options           │  MIME type sniffing      │
│  X-Frame-Options                  │  Clickjacking            │
│  Content-Security-Policy (CSP)    │  XSS, injection          │
│  X-XSS-Protection                │  Reflected XSS (legacy)  │
│  Referrer-Policy                  │  URL leakage             │
│  Permissions-Policy               │  Feature abuse           │
└──────────────────────────────────────────────────────────────┘
```

### Strict-Transport-Security (HSTS)

Tells the browser to only use HTTPS for this domain, even if the user types `http://`.

```javascript
'use strict';

// HSTS: browser will use HTTPS for 1 year, including subdomains
// max-age is in seconds: 31536000 = 365 days
res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
```

- `max-age=31536000` — enforce HTTPS for one year
- `includeSubDomains` — apply to all subdomains too
- `preload` — eligible for browser preload lists (browsers never try HTTP at all)

**Warning:** Only set HSTS after you have confirmed HTTPS works correctly. A misconfiguration can lock users out.

### X-Content-Type-Options

Prevents the browser from "sniffing" the MIME type and ignoring the `Content-Type` header.

```javascript
'use strict';

// Without this, a browser might execute a file served as text/plain
// if it "looks like" JavaScript
res.setHeader('X-Content-Type-Options', 'nosniff');
```

Always set this. There is no reason not to.

### X-Frame-Options

Controls whether your page can be embedded in an `<iframe>`. Prevents clickjacking attacks.

```javascript
'use strict';

// DENY: never allow framing
res.setHeader('X-Frame-Options', 'DENY');

// SAMEORIGIN: only allow framing from the same origin
// res.setHeader('X-Frame-Options', 'SAMEORIGIN');
```

### Content-Security-Policy (CSP)

The most powerful security header. It controls which resources the browser is allowed to load.

```javascript
'use strict';

// Strict CSP that blocks most XSS vectors
const csp = [
  "default-src 'self'",                        // Only load resources from same origin
  "script-src 'self'",                          // Only run scripts from same origin
  "style-src 'self' 'unsafe-inline'",           // Styles from same origin + inline
  "img-src 'self' data: https:",                // Images from same origin, data URIs, any HTTPS
  "font-src 'self'",                            // Fonts from same origin
  "connect-src 'self' https://api.example.com", // Fetch/XHR to same origin + specific API
  "frame-ancestors 'none'",                     // Same as X-Frame-Options: DENY
  "base-uri 'self'",                            // Restrict <base> tag
  "form-action 'self'",                         // Only submit forms to same origin
].join('; ');

res.setHeader('Content-Security-Policy', csp);
```

| Directive | Controls |
|---|---|
| `default-src` | Fallback for all resource types |
| `script-src` | JavaScript execution |
| `style-src` | CSS loading |
| `img-src` | Image loading |
| `connect-src` | Fetch, XHR, WebSocket connections |
| `font-src` | Font loading |
| `frame-ancestors` | Who can embed this page (replaces X-Frame-Options) |
| `base-uri` | `<base>` tag restrictions |
| `form-action` | Form submission targets |

### Referrer-Policy

Controls how much URL information is sent in the `Referer` header when navigating away.

```javascript
'use strict';

// Send the origin (not the full URL) for cross-origin requests
// Send the full URL for same-origin requests
res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
```

| Value | Behavior |
|---|---|
| `no-referrer` | Never send Referer |
| `same-origin` | Send only for same-origin navigations |
| `strict-origin` | Send origin only, and only over HTTPS |
| `strict-origin-when-cross-origin` | Full URL same-origin, origin-only cross-origin (recommended) |

### Permissions-Policy

Controls which browser features (camera, microphone, geolocation, etc.) your page can use.

```javascript
'use strict';

// Disable most sensitive APIs unless needed
const permissionsPolicy = [
  'camera=()',               // Disable camera
  'microphone=()',           // Disable microphone
  'geolocation=()',          // Disable geolocation
  'payment=()',              // Disable Payment Request API
  'usb=()',                  // Disable WebUSB
  'interest-cohort=()',      // Opt out of FLoC/Topics
].join(', ');

res.setHeader('Permissions-Policy', permissionsPolicy);
```

---

## Building a Security Headers Middleware

```javascript
'use strict';

const http = require('node:http');

/**
 * Apply a comprehensive set of security headers to every response.
 */
function applySecurityHeaders(res) {
  // Transport security
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');

  // Content type enforcement
  res.setHeader('X-Content-Type-Options', 'nosniff');

  // Clickjacking protection
  res.setHeader('X-Frame-Options', 'DENY');

  // XSS filter (legacy, but harmless)
  res.setHeader('X-XSS-Protection', '0'); // Disabled — CSP is the real protection

  // Content Security Policy
  res.setHeader('Content-Security-Policy', [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https:",
    "connect-src 'self'",
    "font-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; '));

  // Referrer control
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');

  // Feature restrictions
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');

  // Remove the default Server header that leaks Node.js version
  res.removeHeader('Server');
}

const server = http.createServer((req, res) => {
  // Apply security headers to every response
  applySecurityHeaders(res);

  if (req.url === '/' && req.method === 'GET') {
    const html = `<!DOCTYPE html>
<html>
<head><title>Secure Page</title></head>
<body>
  <h1>Security Headers Active</h1>
  <p>Open DevTools → Network → click this request → check Response Headers.</p>
</body>
</html>`;

    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(html),
    });
    return res.end(html);
  }

  if (req.url === '/api/status' && req.method === 'GET') {
    const body = JSON.stringify({ status: 'ok', secure: true });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found\n');
});

server.listen(3000, () => {
  console.log('Secure server on port 3000');
  console.log('Check headers: curl -I http://localhost:3000/');
});
```

---

## Rate Limiting

Rate limiting protects your server from abuse — brute-force attacks, scraping, and denial of service. Here is a sliding window implementation using a `Map`:

```javascript
'use strict';

const http = require('node:http');

class RateLimiter {
  #windowMs;
  #maxRequests;
  #clients; // Map<string, number[]>  — IP → array of request timestamps

  constructor(windowMs, maxRequests) {
    this.#windowMs = windowMs;
    this.#maxRequests = maxRequests;
    this.#clients = new Map();

    // Periodically clean up expired entries to prevent memory leaks
    setInterval(() => this.#cleanup(), windowMs * 2).unref();
  }

  /**
   * Check if the request should be allowed.
   * Returns { allowed, remaining, resetMs }.
   */
  check(ip) {
    const now = Date.now();
    const windowStart = now - this.#windowMs;

    // Get or create the timestamp array
    let timestamps = this.#clients.get(ip);
    if (!timestamps) {
      timestamps = [];
      this.#clients.set(ip, timestamps);
    }

    // Remove timestamps outside the current window
    while (timestamps.length > 0 && timestamps[0] <= windowStart) {
      timestamps.shift();
    }

    if (timestamps.length >= this.#maxRequests) {
      const oldestInWindow = timestamps[0];
      const resetMs = oldestInWindow + this.#windowMs - now;
      return {
        allowed: false,
        remaining: 0,
        resetMs: Math.max(resetMs, 0),
      };
    }

    timestamps.push(now);
    return {
      allowed: true,
      remaining: this.#maxRequests - timestamps.length,
      resetMs: this.#windowMs,
    };
  }

  #cleanup() {
    const cutoff = Date.now() - this.#windowMs;
    for (const [ip, timestamps] of this.#clients) {
      // Remove expired timestamps
      while (timestamps.length > 0 && timestamps[0] <= cutoff) {
        timestamps.shift();
      }
      // Remove the entry entirely if empty
      if (timestamps.length === 0) {
        this.#clients.delete(ip);
      }
    }
  }
}

// Allow 100 requests per 60 seconds per IP
const limiter = new RateLimiter(60_000, 100);

function getClientIP(req) {
  // In production behind a reverse proxy, use X-Forwarded-For
  const forwarded = req.headers['x-forwarded-for'];
  if (forwarded) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket.remoteAddress;
}

const server = http.createServer((req, res) => {
  const ip = getClientIP(req);
  const result = limiter.check(ip);

  // Always include rate limit headers
  res.setHeader('X-RateLimit-Limit', '100');
  res.setHeader('X-RateLimit-Remaining', String(result.remaining));
  res.setHeader('X-RateLimit-Reset', String(Math.ceil(result.resetMs / 1000)));

  if (!result.allowed) {
    res.writeHead(429, {
      'Content-Type': 'application/json',
      'Retry-After': String(Math.ceil(result.resetMs / 1000)),
    });
    return res.end(JSON.stringify({
      error: 'Too many requests',
      retryAfter: Math.ceil(result.resetMs / 1000),
    }));
  }

  // Normal request handling
  const body = JSON.stringify({
    message: 'OK',
    remaining: result.remaining,
  });
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(3000, () => {
  console.log('Rate-limited server on port 3000');
  console.log('Try: for i in $(seq 1 105); do curl -s localhost:3000 | head -1; done');
});
```

---

## Combining CORS, Security Headers, and Rate Limiting

In production, you layer all three:

```javascript
'use strict';

const http = require('node:http');

// ── Configuration ─────────────────────────────────────────────

const ALLOWED_ORIGINS = new Set(['https://app.example.com', 'http://localhost:3001']);
const RATE_LIMIT = { windowMs: 60_000, max: 100 };

// ── Middleware Functions ──────────────────────────────────────

function cors(req, res) {
  const origin = req.headers.origin;
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Expose-Headers', 'X-RateLimit-Remaining');
  }

  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Max-Age', '86400');
    res.writeHead(204);
    res.end();
    return true;
  }
  return false;
}

function securityHeaders(res) {
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.setHeader('Content-Security-Policy', "default-src 'self'");
  res.setHeader('Permissions-Policy', 'camera=(), microphone=()');
}

const requestCounts = new Map();

function rateLimit(req, res) {
  const ip = req.socket.remoteAddress;
  const now = Date.now();
  let record = requestCounts.get(ip);

  if (!record || now - record.start > RATE_LIMIT.windowMs) {
    record = { start: now, count: 0 };
    requestCounts.set(ip, record);
  }

  record.count += 1;
  const remaining = Math.max(0, RATE_LIMIT.max - record.count);

  res.setHeader('X-RateLimit-Limit', String(RATE_LIMIT.max));
  res.setHeader('X-RateLimit-Remaining', String(remaining));

  if (record.count > RATE_LIMIT.max) {
    res.writeHead(429, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Too many requests' }));
    return true;
  }
  return false;
}

// ── Server ────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  // Layer 1: Security headers (always)
  securityHeaders(res);

  // Layer 2: CORS (returns true if preflight was handled)
  if (cors(req, res)) return;

  // Layer 3: Rate limiting (returns true if request was rejected)
  if (rateLimit(req, res)) return;

  // Layer 4: Application logic
  const body = JSON.stringify({ message: 'Secure, CORS-enabled, rate-limited response' });
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(3000, () => {
  console.log('Production-ready server on port 3000');
});
```

The order matters:

1. **Security headers** — always, before any response
2. **CORS** — must run before application logic to handle preflight
3. **Rate limiting** — reject abusive clients early
4. **Application logic** — only reached by legitimate, allowed, non-abusive requests

---

## Common CORS Mistakes

| Mistake | Problem | Fix |
|---|---|---|
| `Allow-Origin: *` with credentials | Browser rejects the response | Reflect the specific origin |
| Missing `Vary: Origin` | Caches serve wrong CORS headers | Always set `Vary: Origin` when reflecting |
| Not handling `OPTIONS` | Preflight fails, browser blocks request | Return 204 with CORS headers for OPTIONS |
| Setting CORS headers on errors | 500 responses without CORS headers confuse the frontend | Apply CORS headers to all responses, including errors |
| Allowing all origins in production | Any site can make authenticated requests | Use an explicit allow-list |

---

## Key Takeaways

- The Same-Origin Policy is a browser-enforced security boundary — CORS headers are the server's way of explicitly granting cross-origin access to specific origins, methods, and headers
- Preflight `OPTIONS` requests are triggered by non-simple methods (`PUT`, `DELETE`), custom headers (`Authorization`), or `Content-Type: application/json` — your server must respond with the correct `Access-Control-Allow-*` headers or the actual request will never be sent
- Never use `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true` — the browser will reject the response; always reflect the specific requesting origin and include `Vary: Origin`
- Security headers like HSTS, CSP, `X-Content-Type-Options`, and `X-Frame-Options` protect against entire classes of attacks (protocol downgrade, XSS, MIME sniffing, clickjacking) and should be applied to every response without exception
- Rate limiting with a sliding window per IP address is a critical defense layer — always return `429 Too Many Requests` with `Retry-After` and `X-RateLimit-*` headers so clients can back off gracefully

## Next

This concludes Module 07. Continue to [Module 08 — Unix, Processes & IPC](../module-08-unix-processes/lesson-01-unix-fundamentals.md) where you will learn how Node.js interacts with the operating system through processes, signals, and inter-process communication.
