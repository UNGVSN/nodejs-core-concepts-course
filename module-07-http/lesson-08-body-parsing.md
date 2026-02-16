# Module 07 / Lesson 08 — Body Parsing & File Uploads

> When a client sends data to your server — a JSON payload, a form submission, or a file upload — Node.js does not hand you a parsed object. The request body arrives as a raw stream of bytes across multiple `'data'` events. Understanding how to collect, validate, and parse that stream is fundamental to building any server that accepts input. Get it wrong and you open the door to memory exhaustion, injection attacks, and silent data corruption.

## Learning Objectives

- Collect a request body by listening to `'data'` and `'end'` events on the `IncomingMessage` readable stream
- Parse JSON and URL-encoded bodies with proper error handling and size limits
- Enforce `Content-Length` validation and reject oversized payloads with 413 status codes
- Understand multipart form data boundaries and parse file upload parts
- Apply security best practices: size limits, filename sanitization, and content-type validation

---

## Why Body Parsing Is Manual

In many frameworks, you call `req.body` and get a parsed object. Node.js does not do this. The `http.IncomingMessage` object (`req`) is a `Readable` stream. The body is not buffered — it flows through in chunks as the TCP packets arrive.

This design is intentional:

- **Memory efficiency** — a 2 GB file upload does not need to sit in memory
- **Backpressure** — you can pause the stream if you cannot keep up
- **Flexibility** — you decide whether to buffer, parse, or pipe the data directly to disk

```
Client                       Server (Node.js)
  │                              │
  │── TCP segment 1 ──────────▶ │  req emits 'data' (chunk 1)
  │── TCP segment 2 ──────────▶ │  req emits 'data' (chunk 2)
  │── TCP segment 3 ──────────▶ │  req emits 'data' (chunk 3)
  │── FIN ─────────────────────▶ │  req emits 'end'
  │                              │
```

---

## Collecting the Request Body

The fundamental pattern: listen for `'data'` events, push each chunk into an array, concatenate on `'end'`.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  const chunks = [];

  req.on('data', (chunk) => {
    // Each chunk is a Buffer
    chunks.push(chunk);
  });

  req.on('end', () => {
    // Concatenate all chunks into a single Buffer, then decode
    const body = Buffer.concat(chunks).toString('utf8');
    console.log('Received body:', body);
    console.log('Total bytes:', Buffer.byteLength(body));

    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Received ${Buffer.byteLength(body)} bytes\n`);
  });

  req.on('error', (err) => {
    console.error('Request stream error:', err.message);
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('Bad request\n');
  });
});

server.listen(3000, () => {
  console.log('Body collector on port 3000');
});
```

A common mistake is calling `chunk.toString()` on each chunk and concatenating strings. This breaks when a multi-byte UTF-8 character is split across two chunks. Always concatenate Buffers first, then decode once.

---

## Content-Type Dispatch

The `Content-Type` header tells you how to interpret the body. Your server must check it before parsing.

| Content-Type | Format | Common Use |
|---|---|---|
| `application/json` | JSON string | API payloads |
| `application/x-www-form-urlencoded` | `key=value&key2=value2` | HTML form submissions |
| `multipart/form-data` | Boundary-delimited parts | File uploads, mixed forms |
| `text/plain` | Raw text | Webhooks, simple payloads |

```javascript
'use strict';

const http = require('node:http');

function getContentType(req) {
  const header = req.headers['content-type'] || '';
  // Strip parameters like charset: "application/json; charset=utf-8" → "application/json"
  return header.split(';')[0].trim().toLowerCase();
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    return res.end('Method not allowed\n');
  }

  const contentType = getContentType(req);

  collectBody(req, (err, raw) => {
    if (err) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: err.message }));
    }

    let parsed;

    switch (contentType) {
      case 'application/json':
        parsed = parseJSON(raw);
        break;
      case 'application/x-www-form-urlencoded':
        parsed = parseURLEncoded(raw);
        break;
      case 'text/plain':
        parsed = { text: raw };
        break;
      default:
        res.writeHead(415, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: `Unsupported content type: ${contentType}` }));
    }

    if (parsed.error) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: parsed.error }));
    }

    const body = JSON.stringify({ contentType, parsed });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  });
});

function collectBody(req, callback) {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => callback(null, Buffer.concat(chunks).toString('utf8')));
  req.on('error', (err) => callback(err));
}

function parseJSON(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return { error: 'Invalid JSON' };
  }
}

function parseURLEncoded(raw) {
  const params = new URLSearchParams(raw);
  const result = {};
  for (const [key, value] of params) {
    result[key] = value;
  }
  return result;
}

server.listen(3000);
```

---

## JSON Body Parsing with Error Handling

JSON is the most common body format for APIs. Robust parsing requires more than `JSON.parse()`:

```javascript
'use strict';

const http = require('node:http');

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

function parseJSONBody(req) {
  return new Promise((resolve, reject) => {
    const contentType = (req.headers['content-type'] || '').split(';')[0].trim();

    if (contentType !== 'application/json') {
      return reject(new Error('Expected Content-Type: application/json'));
    }

    // Check Content-Length before reading any data
    const contentLength = parseInt(req.headers['content-length'], 10);
    if (!Number.isNaN(contentLength) && contentLength > MAX_BODY_SIZE) {
      return reject(Object.assign(new Error('Payload too large'), { statusCode: 413 }));
    }

    const chunks = [];
    let received = 0;

    req.on('data', (chunk) => {
      received += chunk.length;

      // Enforce size limit even if Content-Length was missing or lied
      if (received > MAX_BODY_SIZE) {
        req.destroy();
        return reject(Object.assign(new Error('Payload too large'), { statusCode: 413 }));
      }

      chunks.push(chunk);
    });

    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');

      if (raw.length === 0) {
        return reject(new Error('Empty body'));
      }

      try {
        const parsed = JSON.parse(raw);
        resolve(parsed);
      } catch {
        reject(new Error('Malformed JSON'));
      }
    });

    req.on('error', (err) => reject(err));
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    return res.end('Method not allowed\n');
  }

  try {
    const data = await parseJSONBody(req);
    const body = JSON.stringify({ received: data });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  } catch (err) {
    const status = err.statusCode || 400;
    const body = JSON.stringify({ error: err.message });
    res.writeHead(status, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  }
});

server.listen(3000, () => {
  console.log('JSON body parser on port 3000');
});
```

Key points:

- **Double size check** — first against `Content-Length` (fast reject before reading), then against actual bytes received (defense against lying headers)
- **`req.destroy()`** — stops the stream immediately when the limit is exceeded
- **Empty body guard** — `JSON.parse('')` throws; check explicitly
- **Error status codes** — 413 for too large, 400 for malformed

---

## URL-Encoded Body Parsing

HTML forms with `method="POST"` and no `enctype` attribute send bodies in `application/x-www-form-urlencoded` format. The body looks like a query string: `username=alice&password=secret123`.

```javascript
'use strict';

const http = require('node:http');

const MAX_FORM_SIZE = 64 * 1024; // 64 KB — forms should not be massive

function parseFormBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let received = 0;

    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > MAX_FORM_SIZE) {
        req.destroy();
        return reject(Object.assign(new Error('Form data too large'), { statusCode: 413 }));
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const params = new URLSearchParams(raw);
      const result = {};

      for (const [key, value] of params) {
        // Handle duplicate keys: if a key appears multiple times, collect as array
        if (result[key] !== undefined) {
          if (Array.isArray(result[key])) {
            result[key].push(value);
          } else {
            result[key] = [result[key], value];
          }
        } else {
          result[key] = value;
        }
      }

      resolve(result);
    });

    req.on('error', (err) => reject(err));
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/') {
    const html = `<!DOCTYPE html>
<html><body>
  <form method="POST" action="/submit">
    <input name="username" placeholder="Username" />
    <input name="email" placeholder="Email" />
    <select name="role" multiple>
      <option value="admin">Admin</option>
      <option value="editor">Editor</option>
      <option value="viewer">Viewer</option>
    </select>
    <button type="submit">Submit</button>
  </form>
</body></html>`;

    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': Buffer.byteLength(html),
    });
    return res.end(html);
  }

  if (req.method === 'POST' && req.url === '/submit') {
    try {
      const data = await parseFormBody(req);
      console.log('Form data:', data);

      const body = JSON.stringify({ formData: data }, null, 2);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      });
      return res.end(body);
    } catch (err) {
      res.writeHead(err.statusCode || 400, { 'Content-Type': 'text/plain' });
      return res.end(err.message);
    }
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found\n');
});

server.listen(3000, () => {
  console.log('Form parser on port 3000');
});
```

---

## Content-Length Validation

The `Content-Length` header declares the body size in bytes. You should validate it in both directions: reject payloads that are too large, and detect incomplete transfers where the actual bytes do not match the declared length.

```javascript
'use strict';

const http = require('node:http');

const MAX_SIZE = 512 * 1024; // 512 KB

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    return res.end('Method not allowed\n');
  }

  // Pre-flight size check
  const declaredLength = parseInt(req.headers['content-length'], 10);

  if (!Number.isNaN(declaredLength) && declaredLength > MAX_SIZE) {
    // Reject before reading any data — save bandwidth
    res.writeHead(413, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({
      error: 'Payload too large',
      maxSize: MAX_SIZE,
      declaredSize: declaredLength,
    }));
  }

  const chunks = [];
  let received = 0;

  req.on('data', (chunk) => {
    received += chunk.length;

    if (received > MAX_SIZE) {
      req.destroy();
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Payload too large (streaming check)' }));
      return;
    }

    chunks.push(chunk);
  });

  req.on('end', () => {
    // Validate actual vs declared length
    if (!Number.isNaN(declaredLength) && received !== declaredLength) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        error: 'Content-Length mismatch',
        declared: declaredLength,
        received,
      }));
    }

    const body = Buffer.concat(chunks).toString('utf8');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ received, bodyPreview: body.slice(0, 100) }));
  });

  req.on('error', () => {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('Request error\n');
  });
});

server.listen(3000, () => {
  console.log('Content-Length validator on port 3000');
});
```

---

## Chunked Transfer Encoding

When the sender does not know the body size in advance (streaming data, server-sent events, large file processing), it uses `Transfer-Encoding: chunked` instead of `Content-Length`. Node.js handles the chunked decoding transparently — your `'data'` event handler receives decoded chunks automatically.

```javascript
'use strict';

const http = require('node:http');

// Server that accepts chunked requests
const server = http.createServer((req, res) => {
  const isChunked = (req.headers['transfer-encoding'] || '').includes('chunked');
  const hasContentLength = req.headers['content-length'] !== undefined;

  console.log('Transfer encoding:', req.headers['transfer-encoding'] || 'none');
  console.log('Content-Length:', req.headers['content-length'] || 'absent');
  console.log('Is chunked:', isChunked);

  const chunks = [];
  let chunkCount = 0;

  req.on('data', (chunk) => {
    chunkCount += 1;
    chunks.push(chunk);
    console.log(`  Chunk ${chunkCount}: ${chunk.length} bytes`);
  });

  req.on('end', () => {
    const total = Buffer.concat(chunks);
    console.log(`Total: ${chunkCount} chunks, ${total.length} bytes`);

    const body = JSON.stringify({
      chunked: isChunked,
      hasContentLength,
      chunkCount,
      totalBytes: total.length,
    });

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  });
});

server.listen(3000, () => {
  console.log('Chunked transfer server on port 3000');
});
```

---

## Understanding Multipart Form Data

File uploads use `multipart/form-data`. The `Content-Type` header includes a **boundary** string that separates each part:

```
Content-Type: multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW
```

The body looks like this:

```
------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n
Content-Disposition: form-data; name="username"\r\n
\r\n
alice\r\n
------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n
Content-Disposition: form-data; name="avatar"; filename="photo.png"\r\n
Content-Type: image/png\r\n
\r\n
<binary file data>\r\n
------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n
```

Structure of each part:

```
--<boundary>\r\n
<part headers>\r\n
\r\n
<part body>\r\n
```

The final boundary has `--` appended: `--<boundary>--`.

---

## Building a Simple Multipart Parser

This parser handles the most common multipart use case: text fields and file uploads.

```javascript
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

function extractBoundary(contentType) {
  const match = contentType.match(/boundary=(.+?)(?:;|$)/);
  return match ? match[1].trim() : null;
}

function parseMultipart(buffer, boundary) {
  const parts = [];
  const delimiter = Buffer.from(`--${boundary}`);
  const end = Buffer.from(`--${boundary}--`);

  // Split the buffer by the boundary delimiter
  let start = buffer.indexOf(delimiter) + delimiter.length + 2; // skip \r\n

  while (start < buffer.length) {
    const nextDelimiter = buffer.indexOf(delimiter, start);
    if (nextDelimiter === -1) break;

    // Extract the part (minus trailing \r\n before next boundary)
    const partBuffer = buffer.subarray(start, nextDelimiter - 2);

    // Split headers from body (separated by \r\n\r\n)
    const headerEnd = partBuffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;

    const headerStr = partBuffer.subarray(0, headerEnd).toString('utf8');
    const body = partBuffer.subarray(headerEnd + 4);

    // Parse part headers
    const headers = {};
    for (const line of headerStr.split('\r\n')) {
      const colonIdx = line.indexOf(':');
      if (colonIdx !== -1) {
        const key = line.slice(0, colonIdx).trim().toLowerCase();
        const value = line.slice(colonIdx + 1).trim();
        headers[key] = value;
      }
    }

    // Extract name and filename from Content-Disposition
    const disposition = headers['content-disposition'] || '';
    const nameMatch = disposition.match(/name="([^"]+)"/);
    const filenameMatch = disposition.match(/filename="([^"]+)"/);

    parts.push({
      name: nameMatch ? nameMatch[1] : null,
      filename: filenameMatch ? filenameMatch[1] : null,
      contentType: headers['content-type'] || null,
      data: body,
    });

    // Move past the delimiter + \r\n
    start = nextDelimiter + delimiter.length + 2;

    // Check if we hit the end boundary
    if (buffer.subarray(nextDelimiter, nextDelimiter + end.length).equals(end)) {
      break;
    }
  }

  return parts;
}

const UPLOAD_DIR = path.join(__dirname, 'uploads');

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/upload') {
    const contentType = req.headers['content-type'] || '';
    const boundary = extractBoundary(contentType);

    if (!boundary) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      return res.end('Missing multipart boundary\n');
    }

    const chunks = [];
    let received = 0;
    const MAX_UPLOAD = 10 * 1024 * 1024; // 10 MB

    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > MAX_UPLOAD) {
        req.destroy();
        res.writeHead(413, { 'Content-Type': 'text/plain' });
        return res.end('Upload too large\n');
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      const buffer = Buffer.concat(chunks);
      const parts = parseMultipart(buffer, boundary);

      const result = { fields: {}, files: [] };

      for (const part of parts) {
        if (part.filename) {
          result.files.push({
            fieldName: part.name,
            filename: part.filename,
            contentType: part.contentType,
            size: part.data.length,
          });
        } else {
          result.fields[part.name] = part.data.toString('utf8');
        }
      }

      const body = JSON.stringify(result, null, 2);
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      });
      res.end(body);
    });

    return;
  }

  // Serve the upload form
  const html = `<!DOCTYPE html>
<html><body>
  <h2>File Upload</h2>
  <form method="POST" action="/upload" enctype="multipart/form-data">
    <input name="username" placeholder="Username" /><br/><br/>
    <input name="avatar" type="file" /><br/><br/>
    <button type="submit">Upload</button>
  </form>
</body></html>`;

  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
  });
  res.end(html);
});

server.listen(3000, () => {
  console.log('Multipart upload server on port 3000');
});
```

---

## Writing Uploaded Files to Disk

Once you have parsed the parts, writing files to disk should use streams for memory efficiency:

```javascript
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const UPLOAD_DIR = path.join(__dirname, 'uploads');

/**
 * Sanitize a user-provided filename to prevent path traversal and other attacks.
 */
function sanitizeFilename(original) {
  // Remove path separators and null bytes
  let safe = original
    .replace(/[/\\]/g, '')        // no directory traversal
    .replace(/\0/g, '')           // no null bytes
    .replace(/\.\./g, '')         // no parent directory references
    .trim();

  // If empty after sanitization, generate a random name
  if (!safe || safe === '.') {
    safe = crypto.randomUUID();
  }

  // Prepend a timestamp to avoid collisions
  const ext = path.extname(safe);
  const base = path.basename(safe, ext);
  return `${Date.now()}-${base}${ext}`;
}

/**
 * Validate the content type against an allow-list.
 */
const ALLOWED_TYPES = new Set([
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'application/pdf',
  'text/plain',
]);

function isAllowedType(contentType) {
  return ALLOWED_TYPES.has(contentType);
}

/**
 * Save a file part to disk.
 */
function saveFile(part) {
  return new Promise((resolve, reject) => {
    if (!part.filename) {
      return reject(new Error('Not a file part'));
    }

    if (part.contentType && !isAllowedType(part.contentType)) {
      return reject(new Error(`Disallowed file type: ${part.contentType}`));
    }

    const safeName = sanitizeFilename(part.filename);
    const filePath = path.join(UPLOAD_DIR, safeName);

    // Ensure the resolved path is still within the upload directory
    if (!filePath.startsWith(UPLOAD_DIR)) {
      return reject(new Error('Path traversal detected'));
    }

    const writeStream = fs.createWriteStream(filePath);

    writeStream.on('finish', () => {
      resolve({ originalName: part.filename, savedAs: safeName, size: part.data.length });
    });

    writeStream.on('error', (err) => {
      reject(err);
    });

    writeStream.end(part.data);
  });
}

// Usage after parsing multipart parts:
// const result = await saveFile(filePart);
// console.log('Saved:', result);

console.log('Upload directory:', UPLOAD_DIR);
console.log('Allowed types:', [...ALLOWED_TYPES]);
```

---

## Handling Client Disconnects

Clients can disconnect mid-upload. If you do not handle this, your server accumulates partial data and wasted resources.

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('POST some data\n');
  }

  const chunks = [];
  let received = 0;
  let aborted = false;

  req.on('data', (chunk) => {
    received += chunk.length;
    chunks.push(chunk);
    console.log(`Received ${received} bytes so far...`);
  });

  // 'close' fires when the underlying connection is closed — even abnormally
  req.on('close', () => {
    if (!res.writableFinished) {
      aborted = true;
      console.log(`Client disconnected after ${received} bytes (incomplete upload)`);
      // Clean up: delete any partial files, release resources
    }
  });

  req.on('end', () => {
    if (aborted) return;

    const total = Buffer.concat(chunks);
    console.log(`Upload complete: ${total.length} bytes`);

    const body = JSON.stringify({ status: 'ok', bytes: total.length });
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
  });

  req.on('error', (err) => {
    console.error('Request error:', err.message);
    if (!res.headersSent) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Request error\n');
    }
  });
});

server.listen(3000, () => {
  console.log('Disconnect-aware server on port 3000');
});
```

---

## Complete Body Parser Module

Bringing it all together — a reusable body parser with size limits, content-type dispatch, and error handling:

```javascript
'use strict';

const http = require('node:http');

const LIMITS = {
  json: 1024 * 1024,       // 1 MB
  form: 64 * 1024,          // 64 KB
  text: 256 * 1024,          // 256 KB
  multipart: 10 * 1024 * 1024, // 10 MB
};

function bodyParser(req, options = {}) {
  return new Promise((resolve, reject) => {
    const contentType = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    const maxSize = options.maxSize || LIMITS[contentType] || LIMITS.text;

    const chunks = [];
    let received = 0;

    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > maxSize) {
        req.destroy();
        const err = new Error(`Body exceeds ${maxSize} byte limit`);
        err.statusCode = 413;
        return reject(err);
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      const raw = Buffer.concat(chunks);

      switch (contentType) {
        case 'application/json': {
          try {
            resolve({ type: 'json', data: JSON.parse(raw.toString('utf8')) });
          } catch {
            const err = new Error('Invalid JSON');
            err.statusCode = 400;
            reject(err);
          }
          break;
        }

        case 'application/x-www-form-urlencoded': {
          const params = new URLSearchParams(raw.toString('utf8'));
          const data = Object.fromEntries(params);
          resolve({ type: 'form', data });
          break;
        }

        case 'text/plain': {
          resolve({ type: 'text', data: raw.toString('utf8') });
          break;
        }

        default: {
          resolve({ type: 'raw', data: raw });
        }
      }
    });

    req.on('error', (err) => reject(err));
  });
}

// Usage
const server = http.createServer(async (req, res) => {
  if (req.method === 'POST') {
    try {
      const { type, data } = await bodyParser(req);
      const body = JSON.stringify({ parsedAs: type, data });
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      });
      return res.end(body);
    } catch (err) {
      const status = err.statusCode || 500;
      res.writeHead(status, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: err.message }));
    }
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('POST with Content-Type: application/json or application/x-www-form-urlencoded\n');
});

server.listen(3000, () => {
  console.log('Universal body parser on port 3000');
});
```

---

## Security Checklist

| Threat | Mitigation |
|---|---|
| Memory exhaustion (huge body) | Enforce `Content-Length` check + streaming byte counter |
| Slow loris (trickle data) | Set `server.requestTimeout` and `server.headersTimeout` |
| Path traversal in filenames | Sanitize with `path.basename()`, strip `..`, `/`, `\`, null bytes |
| Malicious file types | Validate `Content-Type` against an allow-list |
| JSON injection | Always wrap `JSON.parse()` in try/catch |
| Encoding mismatch | Default to UTF-8; reject if declared charset is unsupported |
| Incomplete transfer | Handle `'close'` event to detect client disconnects |
| Duplicate keys in forms | Decide on policy: last-wins, array, or reject |

---

## Key Takeaways

- Node.js does not parse request bodies automatically — `req` is a Readable stream and you must listen for `'data'` and `'end'` events, concatenating Buffer chunks before decoding
- Always enforce body size limits at two levels: first by checking the `Content-Length` header (fast reject before reading), then by counting actual bytes received (defense against missing or lying headers)
- JSON parsing requires `try/catch` around `JSON.parse()` and validation of `Content-Type` — never assume the body is valid JSON just because the route expects it
- Multipart form data uses a boundary string to delimit parts, where each part has its own headers (including `Content-Disposition` with `name` and `filename`) and body separated by `\r\n\r\n`
- File upload security demands filename sanitization (strip path separators, null bytes, `..`), content-type allow-listing, size limits, and path traversal checks after joining the upload directory path

## Next

Continue to [Lesson 09 — CORS & Security Headers](lesson-09-cors-security-headers.md) where you will learn how browsers enforce the same-origin policy, how to implement CORS from scratch, and how to harden your server with security headers.
