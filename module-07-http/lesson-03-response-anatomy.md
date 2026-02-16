# Module 07 / Lesson 03 — Response Anatomy

> The server has received the request and done its work. Now it must answer. An HTTP response follows a rigid structure — status line, headers, empty line, body — and the status code it carries determines how every client, proxy, and cache in the chain will behave.

## Learning Objectives

- Identify the three parts of an HTTP response: status line, headers, and body
- Parse the status line to extract the HTTP version, status code, and reason phrase
- Categorize status codes by class (1xx through 5xx) and recall the most commonly used codes
- Construct a well-formed HTTP response from raw strings
- Understand how Node.js's `ServerResponse` maps to the raw response structure

---

## The Structure of an HTTP Response

An HTTP response mirrors the request structure:

```
HTTP/VERSION STATUS_CODE REASON_PHRASE\r\n   ← Status line
Header-Name: Header-Value\r\n               ← Response headers
Another-Header: Value\r\n
\r\n                                         ← Empty line (end of headers)
response body data                           ← Body
```

A concrete example:

```
HTTP/1.1 200 OK\r\n
Content-Type: application/json\r\n
Content-Length: 27\r\n
Date: Sat, 15 Feb 2026 12:00:00 GMT\r\n
Connection: keep-alive\r\n
\r\n
{"message":"Hello, World!"}
```

---

## Part 1: The Status Line

The status line is the first line of every HTTP response. It has three components:

```
HTTP/VERSION SP STATUS_CODE SP REASON_PHRASE CRLF
```

### HTTP Version

The version matches what the server supports, typically `HTTP/1.1`. This tells the client which features are available (persistent connections, chunked encoding, etc.).

### Status Code

A three-digit integer that classifies the response. The first digit defines the category:

| First digit | Category | Meaning |
|-------------|----------|---------|
| 1 | Informational | Request received, continuing |
| 2 | Success | Request successfully processed |
| 3 | Redirection | Further action needed |
| 4 | Client Error | Bad request from client |
| 5 | Server Error | Server failed to fulfill valid request |

### Reason Phrase

A human-readable description of the status code. `200 OK`, `404 Not Found`, `500 Internal Server Error`. The reason phrase is informational only — clients should rely on the numeric code, not the text. HTTP/2 removed it entirely.

---

## Part 2: Status Code Categories in Detail

### 1xx — Informational

These codes indicate the server has received the request and the client should continue or wait.

| Code | Name | When to use |
|------|------|-------------|
| 100 | Continue | Client sent `Expect: 100-continue` header; server says "go ahead and send the body" |
| 101 | Switching Protocols | Upgrading to WebSocket or HTTP/2 (via `Upgrade` header) |

```
'use strict';

const http = require('node:http');

// Node.js handles 100 Continue automatically by default.
// You can control this behavior with the 'checkContinue' event.
const server = http.createServer();

server.on('checkContinue', (req, res) => {
  // Inspect the request before allowing the body
  const contentLength = parseInt(req.headers['content-length'] || '0', 10);

  if (contentLength > 10 * 1024 * 1024) {
    // Reject bodies larger than 10 MB before they are sent
    res.writeHead(413, { 'Content-Type': 'text/plain' });
    res.end('Payload too large');
    return;
  }

  // Allow the client to proceed with sending the body
  res.writeContinue();

  // Now handle the request normally
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Received ${Buffer.concat(chunks).length} bytes`);
  });
});

server.listen(3000);
```

### 2xx — Success

The request was received, understood, and accepted.

| Code | Name | When to use |
|------|------|-------------|
| 200 | OK | Standard success. Body contains the requested resource or result |
| 201 | Created | A new resource was created (typically after POST). Include `Location` header |
| 204 | No Content | Success, but no body to return (common for DELETE) |
| 206 | Partial Content | Range request fulfilled. Response contains only the requested byte range |

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/api/items') {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const item = JSON.parse(Buffer.concat(chunks).toString());
      const id = Date.now(); // Simulated ID
      item.id = id;

      // 201 Created with Location header pointing to the new resource
      res.writeHead(201, {
        'Content-Type': 'application/json',
        'Location': `/api/items/${id}`,
      });
      res.end(JSON.stringify(item));
    });
    return;
  }

  if (req.method === 'DELETE' && req.url.startsWith('/api/items/')) {
    // 204 No Content — success, but nothing to send back
    res.writeHead(204);
    res.end();
    return;
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok' }));
});

server.listen(3000);
```

### 3xx — Redirection

The client must take additional action to complete the request.

| Code | Name | When to use |
|------|------|-------------|
| 301 | Moved Permanently | Resource has a new permanent URL. Caches update. Method may change to GET |
| 302 | Found | Temporary redirect. Method may change to GET (historical behavior) |
| 304 | Not Modified | Conditional request (If-None-Match / If-Modified-Since) — use cached version |
| 307 | Temporary Redirect | Like 302, but method and body MUST NOT change |
| 308 | Permanent Redirect | Like 301, but method and body MUST NOT change |

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Permanent redirect — old URL to new URL
  if (req.url === '/old-page') {
    res.writeHead(301, { 'Location': '/new-page' });
    res.end();
    return;
  }

  // Temporary redirect preserving the original method
  if (req.url === '/maintenance') {
    res.writeHead(307, { 'Location': '/maintenance-page' });
    res.end();
    return;
  }

  // 304 Not Modified — conditional GET with ETag
  if (req.url === '/data') {
    const etag = '"v1-abc123"';

    if (req.headers['if-none-match'] === etag) {
      // Client already has the current version
      res.writeHead(304);
      res.end();
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'ETag': etag,
    });
    res.end(JSON.stringify({ version: 1, data: 'expensive payload' }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

server.listen(3000);
```

### 4xx — Client Errors

The request contains an error that the client must fix.

| Code | Name | When to use |
|------|------|-------------|
| 400 | Bad Request | Malformed syntax, invalid JSON, missing required fields |
| 401 | Unauthorized | Authentication required (misleading name — it means "unauthenticated") |
| 403 | Forbidden | Authenticated but not authorized for this resource |
| 404 | Not Found | Resource does not exist |
| 405 | Method Not Allowed | Method not supported for this URL. Include `Allow` header |
| 409 | Conflict | Request conflicts with current state (duplicate resource, version conflict) |
| 413 | Payload Too Large | Request body exceeds server limit |
| 415 | Unsupported Media Type | Content-Type not supported |
| 422 | Unprocessable Entity | Well-formed but semantically invalid (validation errors) |
| 429 | Too Many Requests | Rate limit exceeded. Include `Retry-After` header |

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // 405 Method Not Allowed — must include Allow header
  if (req.url === '/api/readonly' && req.method !== 'GET') {
    res.writeHead(405, {
      'Allow': 'GET',
      'Content-Type': 'application/json',
    });
    res.end(JSON.stringify({ error: `Method ${req.method} not allowed. Use GET.` }));
    return;
  }

  // 429 Too Many Requests
  if (req.url === '/api/limited') {
    res.writeHead(429, {
      'Retry-After': '60',
      'Content-Type': 'application/json',
    });
    res.end(JSON.stringify({ error: 'Rate limit exceeded. Try again in 60 seconds.' }));
    return;
  }

  // 422 Unprocessable Entity — validation failure
  if (req.method === 'POST' && req.url === '/api/users') {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString());
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
        return;
      }

      const errors = [];
      if (!body.email) errors.push('email is required');
      if (!body.name) errors.push('name is required');

      if (errors.length > 0) {
        res.writeHead(422, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Validation failed', details: errors }));
        return;
      }

      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ id: 1, ...body }));
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### 5xx — Server Errors

The server failed to fulfill a valid request.

| Code | Name | When to use |
|------|------|-------------|
| 500 | Internal Server Error | Unhandled exception, bug in server code |
| 502 | Bad Gateway | Upstream server returned an invalid response (reverse proxy scenario) |
| 503 | Service Unavailable | Server overloaded or in maintenance. Include `Retry-After` header |
| 504 | Gateway Timeout | Upstream server did not respond in time |

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  try {
    // Simulate a handler that might fail
    if (req.url === '/api/crash') {
      throw new Error('Something went wrong');
    }

    if (req.url === '/api/maintenance') {
      res.writeHead(503, {
        'Content-Type': 'application/json',
        'Retry-After': '300', // Try again in 5 minutes
      });
      res.end(JSON.stringify({ error: 'Service temporarily unavailable' }));
      return;
    }

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
  } catch (err) {
    // Catch-all error handler — never leak stack traces to clients
    console.error('Unhandled error:', err.message);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Internal server error' }));
  }
});

server.listen(3000);
```

---

## Part 3: Response Headers

Response headers provide metadata about the response. Some are informational, some control caching, some are required for correctness.

### Essential Response Headers

```
Content-Type: application/json          ← MIME type of the body
Content-Length: 256                      ← Body size in bytes
Date: Sat, 15 Feb 2026 12:00:00 GMT   ← When the response was generated
Server: node                            ← Server software (optional, often omitted for security)
Connection: keep-alive                  ← Connection management
Cache-Control: max-age=3600             ← Caching directives
ETag: "abc123"                          ← Entity tag for conditional requests
Last-Modified: Fri, 14 Feb 2026 ...    ← When the resource was last changed
Location: /new-url                      ← Redirect target (with 3xx codes)
Set-Cookie: session=xyz; HttpOnly       ← Set a cookie on the client
```

### Building a Response from Scratch

```
'use strict';

const net = require('node:net');

/**
 * Build a raw HTTP response string.
 */
function buildResponse(statusCode, reasonPhrase, headers, body) {
  let response = `HTTP/1.1 ${statusCode} ${reasonPhrase}\r\n`;

  // Add Date header (required by HTTP/1.1 spec for origin servers)
  headers['Date'] = new Date().toUTCString();

  // Calculate Content-Length from the body
  if (body) {
    headers['Content-Length'] = Buffer.byteLength(body).toString();
  }

  // Serialize headers
  for (const [name, value] of Object.entries(headers)) {
    response += `${name}: ${value}\r\n`;
  }

  // Empty line separates headers from body
  response += '\r\n';

  // Append body
  if (body) {
    response += body;
  }

  return response;
}

// Use it in a raw TCP server
const server = net.createServer((socket) => {
  socket.on('data', () => {
    const body = JSON.stringify({ message: 'Built from scratch' });
    const raw = buildResponse(200, 'OK', {
      'Content-Type': 'application/json',
      'X-Powered-By': 'raw-tcp',
    }, body);

    console.log('--- Raw Response ---');
    console.log(raw.replace(/\r\n/g, '\\r\\n\n')); // Visualize CRLFs

    socket.write(raw);
    socket.end();
  });
});

server.listen(3000, () => {
  console.log('Raw response builder listening on port 3000');
});
```

---

## Part 4: The Response Body

The response body contains the actual content: HTML, JSON, image bytes, a file download. Like the request body, its length is communicated via `Content-Length` or `Transfer-Encoding: chunked`.

### Content-Length Responses

When you know the full response size upfront:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const body = JSON.stringify({ users: [{ id: 1, name: 'Alice' }] });
  const bodyBytes = Buffer.byteLength(body);

  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': bodyBytes,
  });
  res.end(body);
});

server.listen(3000);
```

### Chunked Transfer Encoding

When you do not know the size upfront — streaming data, generating content dynamically:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // When you call res.write() without setting Content-Length,
  // Node.js automatically uses chunked transfer encoding
  res.writeHead(200, { 'Content-Type': 'text/plain' });

  let count = 0;
  const interval = setInterval(() => {
    count++;
    res.write(`Chunk ${count}\n`);

    if (count >= 5) {
      clearInterval(interval);
      res.end('Done!\n'); // Final chunk + end signal
    }
  }, 500);
});

server.listen(3000, () => {
  console.log('Chunked response server on port 3000');
  console.log('Test with: curl -N http://localhost:3000');
});
```

On the wire, this produces:

```
HTTP/1.1 200 OK
Content-Type: text/plain
Transfer-Encoding: chunked
Date: Sat, 15 Feb 2026 12:00:00 GMT
Connection: keep-alive

8\r\n
Chunk 1\n\r\n
8\r\n
Chunk 2\n\r\n
...
6\r\n
Done!\n\r\n
0\r\n
\r\n
```

Node.js handles the chunk framing (size in hex, `\r\n` delimiters, zero-length terminator) for you when you use `res.write()` without `Content-Length`.

---

## Node.js ServerResponse Internals

The `ServerResponse` object (`res`) is a `Writable` stream with HTTP-specific additions:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // --- Status code ---
  res.statusCode = 200;           // Set status code (default is 200)
  res.statusMessage = 'OK';       // Set reason phrase (optional)

  // --- Headers ---
  res.setHeader('Content-Type', 'application/json');  // Set individual header
  res.setHeader('X-Request-Id', 'abc-123');
  console.log(res.getHeader('content-type'));          // 'application/json'
  console.log(res.hasHeader('x-request-id'));          // true
  res.removeHeader('x-request-id');                    // Remove before sending

  // --- writeHead (sets status + headers in one call) ---
  // writeHead() takes precedence over setHeader() for any overlapping headers
  res.writeHead(200, 'OK', {
    'Content-Type': 'text/plain',  // Overrides the setHeader above
    'Cache-Control': 'no-store',
  });

  // --- Headers sent check ---
  console.log('Headers sent?', res.headersSent);  // true (after writeHead)

  // After headers are sent, you cannot change them
  // res.setHeader('X-Too-Late', 'value'); // Would throw an error

  // --- Body ---
  res.write('Hello ');       // Sends a chunk
  res.write('World');        // Sends another chunk
  res.end('!\n');            // Sends final chunk and ends the response

  // res.end() must be called or the client hangs forever
});

server.listen(3000);
```

### The writeHead vs setHeader Distinction

This is a common source of confusion:

- `res.setHeader(name, value)` — queues a header to be sent later. You can call it multiple times, override values, remove headers. Headers are not sent until `res.writeHead()` or the first `res.write()`/`res.end()`.
- `res.writeHead(statusCode, headers)` — sends the status line and all headers immediately. After this call, headers are locked. Any headers set via `setHeader` that are not overridden by `writeHead` are included.

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // These are queued, not sent yet
  res.setHeader('X-From-SetHeader', 'yes');
  res.setHeader('Content-Type', 'text/html');

  // This sends immediately, overriding Content-Type but keeping X-From-SetHeader
  res.writeHead(200, { 'Content-Type': 'application/json' });

  // Final headers sent: X-From-SetHeader: yes, Content-Type: application/json
  res.end(JSON.stringify({ method: 'writeHead wins for overlapping headers' }));
});

server.listen(3000);
```

---

## Choosing the Right Status Code

A common anti-pattern is returning `200 OK` for everything and putting the real status in the JSON body. This breaks HTTP semantics, confuses caches and proxies, and makes debugging harder.

```
// BAD: 200 for everything
res.writeHead(200);
res.end(JSON.stringify({ success: false, error: 'User not found' }));

// GOOD: proper status code
res.writeHead(404, { 'Content-Type': 'application/json' });
res.end(JSON.stringify({ error: 'User not found' }));
```

Quick decision guide:

| Situation | Status Code |
|-----------|-------------|
| Everything worked | 200 |
| Resource created | 201 |
| Accepted for async processing | 202 |
| Success, no body to return | 204 |
| Client should use cached version | 304 |
| Bad JSON, missing fields | 400 |
| No auth token / invalid token | 401 |
| Valid token but insufficient permissions | 403 |
| Resource does not exist | 404 |
| Wrong HTTP method | 405 |
| Validation errors (well-formed but invalid data) | 422 |
| Rate limit hit | 429 |
| Unhandled server error | 500 |
| Upstream service down | 502 |
| Server overloaded / maintenance | 503 |

---

## Key Takeaways

- An HTTP response consists of a status line (`HTTP/VERSION STATUS_CODE REASON`), headers, an empty line, and an optional body — mirroring the request structure
- Status codes are grouped into five classes: 1xx (informational), 2xx (success), 3xx (redirection), 4xx (client error), and 5xx (server error) — always use the semantically correct code
- `Content-Length` declares a known body size while `Transfer-Encoding: chunked` enables streaming without knowing the total size upfront
- In Node.js, `res.setHeader()` queues headers for later while `res.writeHead()` sends them immediately — after headers are sent, they cannot be modified
- Never return 200 for errors — use proper status codes so that caches, proxies, monitoring tools, and clients can all behave correctly

## Next

In [Lesson 04 — HTTP Methods & Semantics](lesson-04-http-methods-semantics.md), we explore each HTTP method in depth — what safety, idempotency, and cacheability mean, and when to use each method.
