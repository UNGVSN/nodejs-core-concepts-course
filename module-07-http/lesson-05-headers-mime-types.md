# Module 07 / Lesson 05 — Headers & MIME Types

> HTTP headers are the metadata layer of every request and response. They control caching, authentication, content negotiation, security, and connection management — all without touching the body. Understanding headers is the difference between building a server that works and building one that works correctly with the entire web infrastructure.

## Learning Objectives

- Categorize HTTP headers by function: content, caching, authentication, connection, and security
- Implement content negotiation using `Accept`, `Content-Type`, and `Accept-Encoding` headers
- Configure caching behavior with `Cache-Control`, `ETag`, and `Last-Modified` headers
- Work with the MIME type registry and correctly set `Content-Type` for common formats
- Create and consume custom headers following naming conventions

---

## What Is a Header?

A header is a key-value pair in the HTTP message:

```
Header-Name: Header-Value\r\n
```

Rules:
- Header names are **case-insensitive** (`Content-Type` = `content-type` = `CONTENT-TYPE`)
- Header values are **case-sensitive** (unless the specific header says otherwise)
- Multiple values can be comma-separated: `Accept: text/html, application/json`
- Some headers can appear multiple times: `Set-Cookie` often does
- Node.js lowercases all header names in `req.headers` for consistency

---

## Content Headers

These headers describe what is in the body and how to interpret it.

### Content-Type

The most important header. It tells the recipient the MIME type of the body.

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // Different Content-Types for different responses
  if (url.pathname === '/json') {
    const data = JSON.stringify({ message: 'Hello' });
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(data),
    });
    return res.end(data);
  }

  if (url.pathname === '/html') {
    const html = '<html><body><h1>Hello</h1></body></html>';
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(html),
    });
    return res.end(html);
  }

  if (url.pathname === '/text') {
    const text = 'Plain text response';
    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Content-Length': Buffer.byteLength(text),
    });
    return res.end(text);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found');
});

server.listen(3000);
```

The `charset=utf-8` parameter is important for text types. Without it, the client may guess the wrong encoding. For `application/json`, UTF-8 is the default by specification, but including it explicitly does no harm.

### Content-Length

The body size in **bytes** (not characters). Required for non-chunked responses.

```
'use strict';

// WRONG: string length !== byte length for non-ASCII
const body = 'Cafe\u0301'; // "Café" with combining accent
console.log('String length:', body.length);           // 5
console.log('Byte length:', Buffer.byteLength(body));  // 6

// Always use Buffer.byteLength for Content-Length
```

### Content-Encoding

Indicates compression applied to the body. The client decompresses after receiving.

```
Content-Encoding: gzip          ← Body is gzip-compressed
Content-Encoding: br            ← Body is Brotli-compressed
Content-Encoding: deflate       ← Body uses deflate
```

This is different from `Transfer-Encoding`, which describes the encoding of the transfer (chunked), not the content itself.

### Content-Disposition

Controls how the client presents the body — inline or as a download:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  if (req.url === '/download') {
    const csv = 'name,email\nAlice,alice@example.com\nBob,bob@example.com\n';
    res.writeHead(200, {
      'Content-Type': 'text/csv',
      'Content-Disposition': 'attachment; filename="users.csv"',
      'Content-Length': Buffer.byteLength(csv),
    });
    return res.end(csv);
  }

  if (req.url === '/inline') {
    const csv = 'name,email\nAlice,alice@example.com\n';
    res.writeHead(200, {
      'Content-Type': 'text/csv',
      'Content-Disposition': 'inline', // Browser displays it
      'Content-Length': Buffer.byteLength(csv),
    });
    return res.end(csv);
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('GET /download or /inline');
});

server.listen(3000);
```

---

## Content Negotiation Headers

Content negotiation lets the client tell the server what formats, languages, and encodings it can handle. The server picks the best match.

### Accept

What response body formats the client can process:

```
Accept: application/json                           ← JSON only
Accept: text/html, application/xhtml+xml, */*      ← HTML preferred, anything accepted
Accept: application/json;q=0.9, text/xml;q=0.1     ← JSON preferred (90%), XML fallback (10%)
```

The `q` parameter (quality factor, 0.0 to 1.0) indicates preference. Default is 1.0.

```
'use strict';

const http = require('node:http');

/**
 * Parse the Accept header into an ordered array of media types.
 */
function parseAccept(acceptHeader) {
  if (!acceptHeader) return [{ type: '*/*', quality: 1.0 }];

  return acceptHeader
    .split(',')
    .map((entry) => {
      const parts = entry.trim().split(';');
      const type = parts[0].trim();
      const qParam = parts.find((p) => p.trim().startsWith('q='));
      const quality = qParam ? parseFloat(qParam.split('=')[1]) : 1.0;
      return { type, quality };
    })
    .sort((a, b) => b.quality - a.quality); // Highest quality first
}

const server = http.createServer((req, res) => {
  const accepted = parseAccept(req.headers.accept);
  console.log('Client accepts:', accepted);

  const data = { message: 'Hello', timestamp: Date.now() };

  // Find the best match
  for (const { type } of accepted) {
    if (type === 'application/json' || type === 'application/*' || type === '*/*') {
      const body = JSON.stringify(data);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      });
      return res.end(body);
    }

    if (type === 'text/html' || type === 'text/*') {
      const body = `<html><body><pre>${JSON.stringify(data, null, 2)}</pre></body></html>`;
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
      });
      return res.end(body);
    }

    if (type === 'text/plain') {
      const body = `message: ${data.message}\ntimestamp: ${data.timestamp}`;
      res.writeHead(200, {
        'Content-Type': 'text/plain',
        'Content-Length': Buffer.byteLength(body),
      });
      return res.end(body);
    }
  }

  // 406 Not Acceptable — server cannot produce what the client wants
  res.writeHead(406, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Cannot produce requested content type' }));
});

server.listen(3000);
```

### Accept-Encoding

What compression algorithms the client supports:

```
Accept-Encoding: gzip, deflate, br    ← Client supports all three
Accept-Encoding: identity              ← No compression
```

The server chooses one (or none) and sets `Content-Encoding` in the response.

### Accept-Language

What languages the client prefers:

```
Accept-Language: en-US,en;q=0.9,es;q=0.8
```

Useful for internationalized APIs or server-rendered HTML.

---

## Caching Headers

Caching headers control how responses are stored and revalidated by browsers, CDNs, and proxies.

### Cache-Control

The primary caching directive. Common directives:

```
Cache-Control: public, max-age=3600           ← Cacheable by anyone for 1 hour
Cache-Control: private, max-age=600           ← Cacheable only by the browser (not CDN)
Cache-Control: no-cache                       ← Cache must revalidate with server every time
Cache-Control: no-store                       ← Never cache (sensitive data)
Cache-Control: must-revalidate, max-age=0     ← Always check with server
```

| Directive | Meaning |
|-----------|---------|
| `public` | Any cache (browser, CDN, proxy) can store this |
| `private` | Only the browser can cache (not shared caches) |
| `max-age=N` | Cache is valid for N seconds |
| `no-cache` | Cache it, but always revalidate before using |
| `no-store` | Do not cache at all |
| `must-revalidate` | Once stale, must check with server before using |
| `immutable` | Will never change (for versioned assets like `app.abc123.js`) |

### ETag (Entity Tag)

A fingerprint for the response content. The server generates an ETag (often a hash) and sends it with the response. The client sends it back with `If-None-Match` to check if the content changed.

```
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const articles = {
  '/article/1': { title: 'HTTP Basics', body: 'HTTP is a text protocol...' },
};

function generateETag(data) {
  const hash = crypto.createHash('md5').update(JSON.stringify(data)).digest('hex');
  return `"${hash}"`;
}

const server = http.createServer((req, res) => {
  const article = articles[req.url];
  if (!article) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }

  const etag = generateETag(article);

  // Check if the client has a cached version
  if (req.headers['if-none-match'] === etag) {
    // Content has not changed — return 304 with no body
    res.writeHead(304);
    return res.end();
  }

  // Send the full response with ETag
  const body = JSON.stringify(article);
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'ETag': etag,
    'Cache-Control': 'no-cache', // Always revalidate, but cache the response
  });
  res.end(body);
});

server.listen(3000, () => {
  console.log('ETag server on port 3000');
  console.log('First request: full 200 response');
  console.log('Second request with If-None-Match: 304 No body');
});
```

### Last-Modified / If-Modified-Since

Date-based validation. Less precise than ETag (only second-level granularity) but simpler:

```
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const server = http.createServer((req, res) => {
  const filePath = path.join(__dirname, 'public', req.url === '/' ? 'index.html' : req.url);

  fs.stat(filePath, (err, stats) => {
    if (err) {
      res.writeHead(404);
      return res.end('Not found');
    }

    const lastModified = stats.mtime.toUTCString();
    const ifModifiedSince = req.headers['if-modified-since'];

    if (ifModifiedSince && new Date(ifModifiedSince) >= stats.mtime) {
      res.writeHead(304);
      return res.end();
    }

    res.writeHead(200, {
      'Content-Type': 'text/html',
      'Content-Length': stats.size,
      'Last-Modified': lastModified,
      'Cache-Control': 'no-cache',
    });
    fs.createReadStream(filePath).pipe(res);
  });
});

server.listen(3000);
```

---

## Authentication Headers

### Authorization

The client sends credentials to the server:

```
Authorization: Basic dXNlcjpwYXNz                    ← Base64("user:pass")
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5c...  ← JWT or OAuth token
```

```
'use strict';

const http = require('node:http');

const VALID_TOKEN = 'my-secret-token-123';

const server = http.createServer((req, res) => {
  const authHeader = req.headers.authorization;

  if (!authHeader) {
    // 401 Unauthorized — include WWW-Authenticate to tell the client what to send
    res.writeHead(401, {
      'WWW-Authenticate': 'Bearer realm="API"',
      'Content-Type': 'application/json',
    });
    return res.end(JSON.stringify({ error: 'Authentication required' }));
  }

  // Parse the Authorization header
  const [scheme, token] = authHeader.split(' ');

  if (scheme !== 'Bearer' || token !== VALID_TOKEN) {
    res.writeHead(401, {
      'WWW-Authenticate': 'Bearer realm="API", error="invalid_token"',
      'Content-Type': 'application/json',
    });
    return res.end(JSON.stringify({ error: 'Invalid or expired token' }));
  }

  // Authenticated — proceed with the request
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'Welcome, authenticated user' }));
});

server.listen(3000);
```

### WWW-Authenticate

Sent by the server with a 401 response to tell the client what authentication scheme to use:

```
WWW-Authenticate: Basic realm="Admin Area"
WWW-Authenticate: Bearer realm="API", error="invalid_token"
```

---

## Connection Headers

### Connection

Controls whether the TCP connection stays open after the response:

```
Connection: keep-alive    ← Default in HTTP/1.1
Connection: close         ← Close after this response
```

### Keep-Alive

Additional parameters for persistent connections:

```
Keep-Alive: timeout=5, max=100
```

Means: keep the connection open for up to 5 seconds of idle time, and allow up to 100 requests on this connection.

---

## MIME Types

MIME (Multipurpose Internet Mail Extensions) types tell the recipient what kind of data the body contains. The format is `type/subtype`:

### Common MIME Types

| MIME Type | Extension | Use |
|-----------|-----------|-----|
| `text/html` | .html | Web pages |
| `text/plain` | .txt | Plain text |
| `text/css` | .css | Stylesheets |
| `text/javascript` | .js | JavaScript (modern standard) |
| `application/json` | .json | JSON data |
| `application/xml` | .xml | XML data |
| `application/pdf` | .pdf | PDF documents |
| `application/octet-stream` | (any) | Binary data (default/unknown) |
| `application/x-www-form-urlencoded` | — | HTML form submissions |
| `multipart/form-data` | — | File uploads via forms |
| `image/png` | .png | PNG images |
| `image/jpeg` | .jpg, .jpeg | JPEG images |
| `image/svg+xml` | .svg | SVG images |
| `image/webp` | .webp | WebP images |
| `audio/mpeg` | .mp3 | MP3 audio |
| `video/mp4` | .mp4 | MP4 video |
| `font/woff2` | .woff2 | WOFF2 fonts |

### MIME Type Lookup by Extension

```
'use strict';

const path = require('node:path');

/**
 * Map file extensions to MIME types.
 * In production, you would use a more complete registry.
 */
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.mp3': 'audio/mpeg',
  '.mp4': 'video/mp4',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
};

function getMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_TYPES[ext] || 'application/octet-stream';
}

// Usage
console.log(getMimeType('index.html'));    // text/html; charset=utf-8
console.log(getMimeType('data.json'));     // application/json; charset=utf-8
console.log(getMimeType('photo.png'));     // image/png
console.log(getMimeType('archive.tar'));   // application/octet-stream (unknown)
```

### Using MIME Types in a Static File Server

```
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const PUBLIC_DIR = path.join(__dirname, 'public');

const server = http.createServer((req, res) => {
  // Prevent path traversal attacks
  const safePath = path.normalize(req.url).replace(/^(\.\.[\/\\])+/, '');
  const filePath = path.join(PUBLIC_DIR, safePath === '/' ? 'index.html' : safePath);

  // Ensure we are still within PUBLIC_DIR
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    return res.end('Forbidden');
  }

  const ext = path.extname(filePath).toLowerCase();
  const contentType = MIME_TYPES[ext] || 'application/octet-stream';

  fs.stat(filePath, (err, stats) => {
    if (err || !stats.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      return res.end('Not found');
    }

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': stats.size,
    });
    fs.createReadStream(filePath).pipe(res);
  });
});

server.listen(3000, () => {
  console.log('Static file server with MIME types on port 3000');
});
```

---

## Custom Headers

Custom headers allow you to pass application-specific metadata. By convention, custom headers use the `X-` prefix, though RFC 6648 deprecated this convention. Modern practice is to use a vendor prefix or just a descriptive name.

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const startTime = process.hrtime.bigint();

  // Read custom headers from the request
  const requestId = req.headers['x-request-id'] || crypto.randomUUID();
  const clientVersion = req.headers['x-client-version'];

  console.log(`[${requestId}] ${req.method} ${req.url} (client v${clientVersion || 'unknown'})`);

  // Process the request...
  const body = JSON.stringify({ status: 'ok' });

  const elapsed = Number(process.hrtime.bigint() - startTime) / 1e6; // ms

  // Set custom headers on the response
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'X-Request-Id': requestId,              // Echo back for correlation
    'X-Response-Time': `${elapsed.toFixed(2)}ms`,  // Processing time
    'X-Powered-By': 'node-from-scratch',    // Server identification
  });
  res.end(body);
});

server.listen(3000);
```

### Common Custom Headers in the Wild

| Header | Purpose |
|--------|---------|
| `X-Request-Id` | Unique identifier for request tracing across services |
| `X-Forwarded-For` | Original client IP when behind a proxy |
| `X-Forwarded-Proto` | Original protocol (http/https) when behind a proxy |
| `X-RateLimit-Limit` | Maximum requests per window |
| `X-RateLimit-Remaining` | Requests remaining in current window |
| `X-RateLimit-Reset` | Unix timestamp when the window resets |

---

## Header Security Considerations

Some headers should be removed or carefully controlled in production:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // DO NOT leak server details
  // res.setHeader('X-Powered-By', 'Express');  // Tells attackers what framework you use
  // res.setHeader('Server', 'Apache/2.4.41');  // Tells attackers your server version

  // DO set security headers (covered in detail in Lesson 09)
  res.setHeader('X-Content-Type-Options', 'nosniff');

  const body = JSON.stringify({ message: 'Secure headers example' });
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
});

server.listen(3000);
```

---

## Key Takeaways

- `Content-Type` is the most critical header — it tells the recipient how to interpret the body, and getting it wrong causes parsing failures, rendering issues, or security vulnerabilities
- Caching headers (`Cache-Control`, `ETag`, `Last-Modified`) dramatically reduce server load and improve latency — a 304 response is cheaper than regenerating content
- Content negotiation (`Accept`, `Accept-Encoding`) lets the server tailor responses to client capabilities — always check what the client can handle before choosing a format
- MIME types follow the `type/subtype` format, and you must set them correctly for static files — `application/octet-stream` is the safe fallback for unknown types
- Custom headers enable request tracing, rate limit communication, and application-specific metadata — but never expose server internals through headers like `Server` or `X-Powered-By`

## Next

In [Lesson 06 — The http Module](lesson-06-http-module.md), we explore Node.js's built-in `node:http` module — `http.createServer`, the `IncomingMessage` and `ServerResponse` objects, the request event lifecycle, and how to make outbound HTTP requests.
