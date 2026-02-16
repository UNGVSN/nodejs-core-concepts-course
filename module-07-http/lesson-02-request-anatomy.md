# Module 07 / Lesson 02 — Request Anatomy

> An HTTP request is just a formatted text message sent over a TCP connection. Once you can see its structure — request line, headers, empty line, body — you can parse any request from raw bytes and understand exactly what the client is asking for.

## Learning Objectives

- Identify the four parts of an HTTP request: request line, headers, blank line, and body
- Parse the request line to extract the method, path, and HTTP version
- Read and interpret common request headers
- Build a raw HTTP request parser that works on TCP socket data
- Understand how Node.js's `IncomingMessage` object maps to these raw components

---

## The Four Parts of an HTTP Request

Every HTTP request follows this exact structure:

```
METHOD PATH HTTP/VERSION\r\n      ← Request line
Header-Name: Header-Value\r\n    ← Headers (one per line)
Another-Header: Value\r\n
\r\n                              ← Empty line (end of headers)
optional body data                ← Body (only for POST, PUT, PATCH)
```

The `\r\n` (carriage return + line feed, also written as CRLF) is the line terminator in HTTP. Not `\n` alone. This matters when you parse raw bytes.

### A Real Example

Here is a complete `POST` request as it appears on the wire:

```
POST /api/users HTTP/1.1\r\n
Host: example.com\r\n
Content-Type: application/json\r\n
Content-Length: 45\r\n
Accept: application/json\r\n
Connection: keep-alive\r\n
\r\n
{"username":"alice","email":"alice@test.com"}
```

Let us break down each part.

---

## Part 1: The Request Line

The request line is always the first line of an HTTP request. It has exactly three components separated by spaces:

```
METHOD SP PATH SP HTTP/VERSION CRLF
```

### The Method

The method (also called the HTTP verb) tells the server what action the client wants to perform:

```
GET /users HTTP/1.1          ← Retrieve data
POST /users HTTP/1.1         ← Create data
PUT /users/42 HTTP/1.1       ← Replace data
PATCH /users/42 HTTP/1.1     ← Partially update data
DELETE /users/42 HTTP/1.1    ← Remove data
HEAD /users HTTP/1.1         ← Like GET but no body in response
OPTIONS /users HTTP/1.1      ← Ask what methods are allowed
```

Methods are case-sensitive. `GET` is valid; `get` is not (though many servers tolerate it).

### The Path (Request Target)

The path identifies the resource the client wants to interact with. It can include:

- **Path only:** `/api/users`
- **Path with query string:** `/api/users?role=admin&page=2`
- **Path with fragment:** `/docs#section-3` (though fragments are rarely sent to the server — browsers strip them)

The path is always absolute (starts with `/`). It is percent-encoded — spaces become `%20`, special characters become their hex equivalents.

### The HTTP Version

The version string is one of:

- `HTTP/1.0` — Legacy, one request per connection
- `HTTP/1.1` — Current standard, persistent connections
- `HTTP/2` — Binary framing (but you will never see this in raw text form — HTTP/2 is binary)

---

## Part 2: Headers

Headers are key-value pairs that provide metadata about the request. Each header occupies one line:

```
Header-Name: Header-Value\r\n
```

Header names are **case-insensitive** (`Content-Type`, `content-type`, and `CONTENT-TYPE` are all the same). Header values are case-sensitive (unless the specific header defines otherwise).

### Common Request Headers

```
Host: example.com                    ← Required in HTTP/1.1
Content-Type: application/json       ← MIME type of the body
Content-Length: 45                    ← Size of the body in bytes
Accept: application/json             ← What the client wants back
Authorization: Bearer eyJhbG...      ← Authentication credential
User-Agent: Mozilla/5.0 ...         ← Client identification
Cookie: session=abc123               ← Stored cookies
Cache-Control: no-cache              ← Caching directives
Connection: keep-alive               ← Connection management
Accept-Encoding: gzip, deflate       ← Compression the client supports
```

### Multi-Value Headers

Some headers can appear multiple times or contain comma-separated values:

```
Accept: text/html, application/json, */*
Set-Cookie: a=1                       ← Multiple Set-Cookie headers allowed
Set-Cookie: b=2
```

### Parsing Headers from Raw Text

```
'use strict';

/**
 * Parse raw header lines into a Map.
 * Each line is "Name: Value\r\n".
 * Header names are lowercased for case-insensitive lookup.
 */
function parseHeaders(headerLines) {
  const headers = new Map();

  for (const line of headerLines) {
    // Find the first colon — the header name cannot contain colons,
    // but the value can (e.g., "Host: localhost:3000")
    const colonIndex = line.indexOf(':');
    if (colonIndex === -1) continue;

    const name = line.slice(0, colonIndex).trim().toLowerCase();
    const value = line.slice(colonIndex + 1).trim();

    // Handle duplicate headers by appending with comma
    if (headers.has(name)) {
      headers.set(name, headers.get(name) + ', ' + value);
    } else {
      headers.set(name, value);
    }
  }

  return headers;
}

// Test it
const rawHeaders = [
  'Host: localhost:3000',
  'Content-Type: application/json',
  'Accept: text/html, application/json',
  'X-Custom: my-value',
  'Content-Length: 128',
];

const parsed = parseHeaders(rawHeaders);
console.log(parsed);
// Map {
//   'host' => 'localhost:3000',
//   'content-type' => 'application/json',
//   'accept' => 'text/html, application/json',
//   'x-custom' => 'my-value',
//   'content-length' => '128'
// }
```

---

## Part 3: The Empty Line

The empty line (`\r\n` on its own, with no content before it) signals the end of the headers section. This is how the parser knows "headers are done, body starts next."

```
Content-Length: 13\r\n
\r\n                      ← This empty line is the boundary
Hello, World!             ← Body starts here
```

Without this delimiter, the parser cannot know whether the next line is another header or the start of the body. The empty line is mandatory even when there is no body.

---

## Part 4: The Body

The body carries the payload of the request. Not all requests have a body:

| Method | Typically has body? |
|--------|-------------------|
| GET | No |
| HEAD | No |
| DELETE | Usually no |
| POST | Yes |
| PUT | Yes |
| PATCH | Yes |
| OPTIONS | Rarely |

### How the Server Knows the Body Length

There are two mechanisms:

**1. Content-Length header** — declares the exact byte count:

```
Content-Length: 45\r\n
\r\n
{"username":"alice","email":"alice@test.com"}
```

The server reads exactly 45 bytes after the empty line. No more, no less.

**2. Transfer-Encoding: chunked** — body arrives in chunks:

```
Transfer-Encoding: chunked\r\n
\r\n
1a\r\n
This is the first chunk.\r\n
0\r\n
\r\n
```

Each chunk starts with its size in hexadecimal, followed by `\r\n`, the data, and `\r\n`. A chunk of size `0` signals the end.

If neither header is present and the method typically has a body, the server must close the connection to signal the end (HTTP/1.0 behavior) or reject the request.

---

## Building a Raw HTTP Request Parser

Let us build a parser that takes raw TCP bytes and extracts a structured request object:

```
'use strict';

/**
 * Parse a raw HTTP request string into a structured object.
 * This is educational — production code should use Node.js's built-in llhttp parser.
 */
function parseHttpRequest(raw) {
  // Split on the empty line that separates headers from body
  const headerEndIndex = raw.indexOf('\r\n\r\n');
  if (headerEndIndex === -1) {
    throw new Error('Malformed request: no header-body separator found');
  }

  const headerSection = raw.slice(0, headerEndIndex);
  const body = raw.slice(headerEndIndex + 4); // Skip the \r\n\r\n

  // Split header section into lines
  const lines = headerSection.split('\r\n');

  // First line is the request line
  const requestLine = lines[0];
  const [method, path, version] = requestLine.split(' ');

  if (!method || !path || !version) {
    throw new Error(`Malformed request line: "${requestLine}"`);
  }

  // Remaining lines are headers
  const headers = {};
  for (let i = 1; i < lines.length; i++) {
    const colonIndex = lines[i].indexOf(':');
    if (colonIndex === -1) continue;

    const name = lines[i].slice(0, colonIndex).trim().toLowerCase();
    const value = lines[i].slice(colonIndex + 1).trim();
    headers[name] = value;
  }

  // Parse the URL for path and query string
  let pathname = path;
  let queryString = '';
  const queryIndex = path.indexOf('?');
  if (queryIndex !== -1) {
    pathname = path.slice(0, queryIndex);
    queryString = path.slice(queryIndex + 1);
  }

  return {
    method,
    path,
    pathname,
    queryString,
    version,
    headers,
    body: body || null,
  };
}

// Test with a raw GET request
const rawGet =
  'GET /api/users?role=admin HTTP/1.1\r\n' +
  'Host: localhost:3000\r\n' +
  'Accept: application/json\r\n' +
  'Connection: keep-alive\r\n' +
  '\r\n';

console.log('--- GET Request ---');
console.log(parseHttpRequest(rawGet));

// Test with a raw POST request
const rawPost =
  'POST /api/users HTTP/1.1\r\n' +
  'Host: localhost:3000\r\n' +
  'Content-Type: application/json\r\n' +
  'Content-Length: 45\r\n' +
  '\r\n' +
  '{"username":"alice","email":"alice@test.com"}';

console.log('\n--- POST Request ---');
console.log(parseHttpRequest(rawPost));
```

Expected output:

```
--- GET Request ---
{
  method: 'GET',
  path: '/api/users?role=admin',
  pathname: '/api/users',
  queryString: 'role=admin',
  version: 'HTTP/1.1',
  headers: {
    host: 'localhost:3000',
    accept: 'application/json',
    connection: 'keep-alive'
  },
  body: null
}

--- POST Request ---
{
  method: 'POST',
  path: '/api/users',
  pathname: '/api/users',
  queryString: '',
  version: 'HTTP/1.1',
  headers: {
    host: 'localhost:3000',
    'content-type': 'application/json',
    'content-length': '45'
  },
  body: '{"username":"alice","email":"alice@test.com"}'
}
```

---

## Parsing from a TCP Socket (Streaming)

In practice, HTTP requests arrive as a stream of bytes over TCP — possibly in multiple chunks. You cannot assume the entire request arrives in a single `data` event. Here is a more realistic approach:

```
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  let buffer = '';

  socket.on('data', (chunk) => {
    buffer += chunk.toString();

    // Check if we have received the complete headers
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) return; // Still waiting for more data

    // Parse the request line and headers
    const headerSection = buffer.slice(0, headerEnd);
    const lines = headerSection.split('\r\n');
    const [method, path, version] = lines[0].split(' ');

    const headers = {};
    for (let i = 1; i < lines.length; i++) {
      const colonIdx = lines[i].indexOf(':');
      if (colonIdx === -1) continue;
      headers[lines[i].slice(0, colonIdx).trim().toLowerCase()] =
        lines[i].slice(colonIdx + 1).trim();
    }

    // Determine body length
    const contentLength = parseInt(headers['content-length'] || '0', 10);
    const bodyStart = headerEnd + 4;
    const receivedBody = buffer.slice(bodyStart);

    // Check if we have the complete body
    if (receivedBody.length < contentLength) {
      return; // Still waiting for body data
    }

    const body = receivedBody.slice(0, contentLength);

    console.log(`${method} ${path} ${version}`);
    console.log('Headers:', headers);
    if (body) console.log('Body:', body);

    // Send a response
    const responseBody = JSON.stringify({ received: true, method, path });
    socket.write(
      'HTTP/1.1 200 OK\r\n' +
      'Content-Type: application/json\r\n' +
      `Content-Length: ${Buffer.byteLength(responseBody)}\r\n` +
      'Connection: close\r\n' +
      '\r\n' +
      responseBody
    );
    socket.end();
  });
});

server.listen(3000, () => {
  console.log('Raw HTTP parser listening on port 3000');
});
```

### Why Buffer.byteLength, Not String.length?

Notice we use `Buffer.byteLength(responseBody)` rather than `responseBody.length`. `Content-Length` counts **bytes**, not characters. For ASCII-only strings they are the same, but for multibyte UTF-8 characters (emoji, accented characters, CJK), the byte count differs:

```
'use strict';

const ascii = 'Hello';
const emoji = 'Hello 👋';

console.log(`"${ascii}" — string length: ${ascii.length}, byte length: ${Buffer.byteLength(ascii)}`);
// "Hello" — string length: 5, byte length: 5

console.log(`"${emoji}" — string length: ${emoji.length}, byte length: ${Buffer.byteLength(emoji)}`);
// "Hello 👋" — string length: 8, byte length: 10
// (The emoji is 4 bytes in UTF-8 but 2 "characters" in JS due to surrogate pairs)
```

Getting `Content-Length` wrong causes the client to read too many or too few bytes, corrupting the response or hanging the connection.

---

## How Node.js Represents a Parsed Request

When you use `http.createServer`, Node.js parses the raw request and gives you an `IncomingMessage` object (`req`). Here is how the raw parts map to `req` properties:

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Request line components
  console.log('Method:', req.method);             // 'GET', 'POST', etc.
  console.log('URL:', req.url);                   // '/api/users?role=admin'
  console.log('HTTP Version:', req.httpVersion);   // '1.1'

  // Headers (lowercased keys)
  console.log('Headers:', req.headers);
  // { host: 'localhost:3000', accept: 'application/json', ... }

  // Raw headers (original casing, alternating name-value array)
  console.log('Raw headers:', req.rawHeaders);
  // ['Host', 'localhost:3000', 'Accept', 'application/json', ...]

  // The body is NOT parsed automatically — req is a Readable stream
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString();
    console.log('Body:', body);

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
  });
});

server.listen(3000);
```

Key observations:

- `req.method` and `req.httpVersion` come from the request line
- `req.url` is the raw path + query string (not parsed into components)
- `req.headers` has lowercased keys; `req.rawHeaders` preserves original casing
- The body is **not** automatically parsed — `req` is a `Readable` stream and you must collect the data yourself (or use middleware)

---

## Edge Cases to Watch For

### Percent-Encoded URLs

Clients encode special characters in URLs. Spaces become `%20`, slashes in query values become `%2F`:

```
'use strict';

const encoded = '/search?q=hello%20world&tag=node%2Fjs';
console.log('Raw:', encoded);
console.log('Decoded:', decodeURIComponent(encoded));
// Decoded: /search?q=hello world&tag=node/js
```

Be careful: decode the **value**, not the whole path. Decoding `/search%2Fpath` would turn it into `/search/path`, changing the route.

### Multiple Values for the Same Query Key

```
// /filter?color=red&color=blue&color=green
const url = new URL('http://localhost/filter?color=red&color=blue&color=green');
console.log(url.searchParams.get('color'));    // 'red' (first only)
console.log(url.searchParams.getAll('color')); // ['red', 'blue', 'green']
```

### Request Smuggling

If `Content-Length` and `Transfer-Encoding` headers conflict, attackers can exploit this to "smuggle" a second request inside the first. Node.js's llhttp parser handles this safely — it rejects ambiguous requests. A hand-rolled parser might not.

---

## Key Takeaways

- An HTTP request has four parts: the request line (`METHOD PATH VERSION`), headers (key-value pairs), an empty line separator, and an optional body
- The request line contains the method, path (with optional query string), and HTTP version — all separated by single spaces
- Headers are case-insensitive in their names, terminated by `\r\n`, and end at the first empty line (`\r\n\r\n`)
- Always use `Buffer.byteLength()` rather than `String.length` for `Content-Length` to correctly handle multibyte UTF-8 characters
- Node.js's `IncomingMessage` (`req`) gives you the parsed request line and headers, but leaves the body as a `Readable` stream you must collect yourself

## Next

In [Lesson 03 — Response Anatomy](lesson-03-response-anatomy.md), we flip to the server side and examine how HTTP responses are structured — the status line, status codes, headers, and body.
