# Module 07 / Lesson 04 — HTTP Methods & Semantics

> Choosing the right HTTP method is not just convention — it determines whether browsers cache the response, whether proxies retry failed requests, and whether intermediaries treat the operation as safe to repeat. Getting the semantics wrong causes bugs that are invisible in development and catastrophic in production.

## Learning Objectives

- Define safety, idempotency, and cacheability and explain why they matter for API design
- Describe the semantics and intended use of GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS
- Map real-world CRUD operations to the correct HTTP methods
- Implement a method-aware request handler in Node.js
- Identify common method misuse patterns and their consequences

---

## The Three Properties of HTTP Methods

Every HTTP method has three semantic properties defined by the HTTP specification (RFC 9110). These are not suggestions — they are contracts that clients, proxies, caches, and browsers rely on.

### Safety

A **safe** method does not modify server state. Calling it has no side effects. The server can log the request, update analytics, or increment a counter — but it must not change the resource itself.

Safe methods: **GET, HEAD, OPTIONS**

Why it matters: Browsers freely prefetch safe URLs, search engines crawl them, and proxies cache them. If your `GET /api/users` endpoint deletes a user, a search engine crawler will destroy your data.

### Idempotency

An **idempotent** method produces the same result whether you call it once or a hundred times. Repeating the request has no additional effect beyond the first call.

Idempotent methods: **GET, HEAD, OPTIONS, PUT, DELETE**

Why it matters: Network failures are inevitable. When a request times out, the client does not know whether the server processed it. For idempotent methods, the client can safely retry. For non-idempotent methods (like POST), retrying might create duplicate records.

### Cacheability

A **cacheable** method's response can be stored and reused by caches (browser cache, CDN, proxy) without asking the server again.

Cacheable methods: **GET, HEAD** (POST responses can be cached in theory, but almost never are in practice)

Why it matters: Caching is the most effective performance optimization on the web. If your API uses POST for read operations, you lose all caching benefits.

### Summary Table

| Method | Safe | Idempotent | Cacheable | Has Body (Request) | Has Body (Response) |
|--------|------|------------|-----------|-------------------|-------------------|
| GET | Yes | Yes | Yes | No | Yes |
| HEAD | Yes | Yes | Yes | No | No |
| OPTIONS | Yes | Yes | No | Rarely | Yes |
| POST | No | No | Rarely | Yes | Yes |
| PUT | No | Yes | No | Yes | May |
| PATCH | No | No | No | Yes | Yes |
| DELETE | No | Yes | No | Rarely | May |

---

## GET — Retrieve a Resource

GET requests a representation of the specified resource. It must not change server state.

```
'use strict';

const http = require('node:http');

// In-memory data store
const users = [
  { id: 1, name: 'Alice', email: 'alice@example.com' },
  { id: 2, name: 'Bob', email: 'bob@example.com' },
  { id: 3, name: 'Charlie', email: 'charlie@example.com' },
];

const server = http.createServer((req, res) => {
  if (req.method !== 'GET') {
    res.writeHead(405, { 'Allow': 'GET', 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Method not allowed' }));
    return;
  }

  // GET /api/users — list all users
  if (req.url === '/api/users') {
    const body = JSON.stringify(users);
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'public, max-age=60', // Cacheable for 60 seconds
    });
    res.end(body);
    return;
  }

  // GET /api/users/:id — get one user
  const match = req.url.match(/^\/api\/users\/(\d+)$/);
  if (match) {
    const user = users.find((u) => u.id === parseInt(match[1], 10));
    if (!user) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'User not found' }));
      return;
    }

    const body = JSON.stringify(user);
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### GET Rules

- Never use GET to create, update, or delete data
- Never put sensitive data in the URL (query string) — URLs are logged by proxies, browsers, and servers
- The response body contains the resource representation
- Responses are cacheable by default

---

## POST — Create a Resource (or Trigger a Process)

POST submits data to the server for processing. It is the most flexible method — used for creating resources, submitting forms, triggering actions, and anything that does not fit the other methods.

```
'use strict';

const http = require('node:http');

let nextId = 1;
const items = [];

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/api/items') {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString());
      } catch {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON body' }));
        return;
      }

      // Create the resource
      const item = { id: nextId++, ...body, createdAt: new Date().toISOString() };
      items.push(item);

      const responseBody = JSON.stringify(item);
      res.writeHead(201, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(responseBody),
        'Location': `/api/items/${item.id}`, // Where to find the new resource
      });
      res.end(responseBody);
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### POST Rules

- Not idempotent — two identical POST requests may create two different resources
- Return 201 Created with a `Location` header when a resource is created
- Return 200 OK or 202 Accepted for non-creation actions (processing, triggering)
- Not cacheable (by default)
- Browsers warn users before re-submitting forms ("Are you sure you want to resubmit?") because POST is not safe

---

## PUT — Replace a Resource

PUT replaces the entire resource at the given URL. If the resource does not exist, PUT may create it. The key distinction from POST: PUT targets a specific URL, and the client determines the resource location.

```
'use strict';

const http = require('node:http');

const store = new Map();

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch (err) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const match = req.url.match(/^\/api\/config\/(\w+)$/);

  if (req.method === 'PUT' && match) {
    const key = match[1];

    let body;
    try {
      body = await collectBody(req);
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
      return;
    }

    const existed = store.has(key);
    // PUT replaces the ENTIRE resource — partial updates are not PUT
    store.set(key, body);

    const responseBody = JSON.stringify(body);
    res.writeHead(existed ? 200 : 201, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(responseBody),
    });
    res.end(responseBody);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### PUT Rules

- Idempotent: `PUT /users/42 { name: "Alice" }` produces the same result whether called once or ten times
- Replaces the **entire** resource — if you omit a field, it is gone (unlike PATCH)
- Return 200 OK if the resource existed and was replaced
- Return 201 Created if the resource was newly created
- The client specifies the URL (e.g., `PUT /config/theme`), not the server

---

## PATCH — Partially Update a Resource

PATCH applies a partial modification to a resource. Unlike PUT, you only send the fields you want to change.

```
'use strict';

const http = require('node:http');

const users = new Map([
  [1, { id: 1, name: 'Alice', email: 'alice@example.com', role: 'admin' }],
  [2, { id: 2, name: 'Bob', email: 'bob@example.com', role: 'user' }],
]);

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch (err) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const match = req.url.match(/^\/api\/users\/(\d+)$/);

  if (req.method === 'PATCH' && match) {
    const id = parseInt(match[1], 10);
    const user = users.get(id);

    if (!user) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'User not found' }));
      return;
    }

    let patch;
    try {
      patch = await collectBody(req);
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
      return;
    }

    // Merge only the provided fields — keep everything else unchanged
    const updated = { ...user, ...patch, id: user.id }; // Never allow ID override
    users.set(id, updated);

    const body = JSON.stringify(updated);
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### PATCH vs PUT — When to Use Each

| Scenario | Method | What you send |
|----------|--------|---------------|
| Replace a user's entire profile | PUT | Full user object |
| Change just the email | PATCH | `{ "email": "new@example.com" }` |
| Update a config file completely | PUT | Full config |
| Toggle a single setting | PATCH | `{ "darkMode": true }` |

PATCH is **not idempotent** by definition (a PATCH that says "increment counter by 1" is not idempotent), though most JSON merge patches in practice are.

---

## DELETE — Remove a Resource

DELETE removes the resource at the specified URL.

```
'use strict';

const http = require('node:http');

const items = new Map([
  [1, { id: 1, title: 'First item' }],
  [2, { id: 2, title: 'Second item' }],
]);

const server = http.createServer((req, res) => {
  const match = req.url.match(/^\/api\/items\/(\d+)$/);

  if (req.method === 'DELETE' && match) {
    const id = parseInt(match[1], 10);

    if (!items.has(id)) {
      // Option 1: 404 — resource does not exist
      // Option 2: 204 — idempotent, "it's gone either way"
      // Both are valid. 404 is more informative.
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Item not found' }));
      return;
    }

    items.delete(id);

    // 204 No Content — success, nothing to return
    res.writeHead(204);
    res.end();
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

server.listen(3000);
```

### DELETE Rules

- Idempotent: deleting a resource that is already gone should not be an error (though returning 404 is also acceptable)
- Return 204 No Content (no body) or 200 OK (with a body confirming deletion)
- Do not use DELETE with a request body (some servers ignore it, some reject it)

---

## HEAD — GET Without the Body

HEAD is identical to GET, but the server must not include a response body. The response headers must be the same as if it were a GET request, including `Content-Length`.

```
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Allow': 'GET, HEAD' });
    res.end();
    return;
  }

  const filePath = path.join(__dirname, 'public', req.url === '/' ? 'index.html' : req.url);

  fs.stat(filePath, (err, stats) => {
    if (err) {
      res.writeHead(404);
      if (req.method === 'GET') res.end('Not found');
      else res.end(); // HEAD — no body
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'text/html',
      'Content-Length': stats.size,
      'Last-Modified': stats.mtime.toUTCString(),
    });

    if (req.method === 'HEAD') {
      // Headers only — no body
      res.end();
    } else {
      // GET — include the body
      fs.createReadStream(filePath).pipe(res);
    }
  });
});

server.listen(3000);
```

### When to Use HEAD

- Check if a resource exists without downloading it
- Check the `Content-Length` before deciding to download a large file
- Validate cache freshness (`ETag`, `Last-Modified`) without transferring the body
- Monitor endpoints for uptime (HEAD is cheaper than GET)

---

## OPTIONS — Discover What Is Allowed

OPTIONS asks the server what methods and capabilities are available for a given URL. It is the method used in CORS preflight requests.

```
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // CORS preflight for any path
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Allow': 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400', // Cache preflight for 24 hours
    });
    res.end();
    return;
  }

  // Route-specific OPTIONS
  if (req.method === 'OPTIONS' && req.url === '/api/users') {
    res.writeHead(204, {
      'Allow': 'GET, POST', // Only GET and POST for this endpoint
    });
    res.end();
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('OK');
});

server.listen(3000);
```

---

## Building a Method-Aware Handler

Here is a pattern that cleanly dispatches requests based on method and path:

```
'use strict';

const http = require('node:http');

// In-memory store
const todos = new Map();
let nextId = 1;

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      try {
        const text = Buffer.concat(chunks).toString();
        resolve(text ? JSON.parse(text) : null);
      } catch (err) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function sendJson(res, statusCode, data) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const { pathname } = url;
  const method = req.method;

  try {
    // Collection routes: /api/todos
    if (pathname === '/api/todos') {
      if (method === 'GET') {
        return sendJson(res, 200, [...todos.values()]);
      }

      if (method === 'POST') {
        const body = await collectBody(req);
        if (!body || !body.title) {
          return sendJson(res, 422, { error: 'title is required' });
        }

        const todo = { id: nextId++, title: body.title, done: false };
        todos.set(todo.id, todo);

        res.writeHead(201, {
          'Content-Type': 'application/json',
          'Location': `/api/todos/${todo.id}`,
          'Content-Length': Buffer.byteLength(JSON.stringify(todo)),
        });
        return res.end(JSON.stringify(todo));
      }

      // Method not supported for this URL
      res.writeHead(405, {
        'Allow': 'GET, POST',
        'Content-Type': 'application/json',
      });
      return res.end(JSON.stringify({ error: `${method} not allowed on /api/todos` }));
    }

    // Individual routes: /api/todos/:id
    const match = pathname.match(/^\/api\/todos\/(\d+)$/);
    if (match) {
      const id = parseInt(match[1], 10);
      const todo = todos.get(id);

      if (method === 'GET') {
        if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
        return sendJson(res, 200, todo);
      }

      if (method === 'PUT') {
        const body = await collectBody(req);
        if (!body || !body.title) {
          return sendJson(res, 422, { error: 'title is required' });
        }
        const updated = { id, title: body.title, done: !!body.done };
        todos.set(id, updated);
        return sendJson(res, todo ? 200 : 201, updated);
      }

      if (method === 'PATCH') {
        if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
        const patch = await collectBody(req);
        const updated = { ...todo, ...patch, id: todo.id };
        todos.set(id, updated);
        return sendJson(res, 200, updated);
      }

      if (method === 'DELETE') {
        if (!todo) return sendJson(res, 404, { error: 'Todo not found' });
        todos.delete(id);
        res.writeHead(204);
        return res.end();
      }

      res.writeHead(405, {
        'Allow': 'GET, PUT, PATCH, DELETE',
        'Content-Type': 'application/json',
      });
      return res.end(JSON.stringify({ error: `${method} not allowed` }));
    }

    sendJson(res, 404, { error: 'Not found' });
  } catch (err) {
    if (err.message === 'Invalid JSON') {
      return sendJson(res, 400, { error: 'Invalid JSON body' });
    }
    console.error(err);
    sendJson(res, 500, { error: 'Internal server error' });
  }
});

server.listen(3000, () => {
  console.log('Method-aware server on port 3000');
});
```

---

## Common Method Misuse Patterns

### Using GET for Mutations

```
// DANGEROUS: GET requests are safe — crawlers, prefetchers, and caches will call this
GET /api/users/42/delete    // NO — use DELETE /api/users/42
GET /api/reset-database     // Absolutely not
GET /api/send-email?to=bob  // No — use POST
```

### Using POST for Everything

```
// Loses caching, idempotency, and semantic clarity
POST /api/get-users         // Should be GET /api/users
POST /api/update-user       // Should be PUT or PATCH /api/users/:id
POST /api/delete-user       // Should be DELETE /api/users/:id
```

### Confusing PUT and PATCH

```
// PUT replaces the ENTIRE resource
PUT /api/users/42
{ "email": "new@example.com" }
// Result: { id: 42, email: "new@example.com" } — name is GONE

// PATCH updates only the specified fields
PATCH /api/users/42
{ "email": "new@example.com" }
// Result: { id: 42, name: "Alice", email: "new@example.com" } — name preserved
```

---

## Key Takeaways

- Safe methods (GET, HEAD, OPTIONS) must never modify server state — browsers, crawlers, and caches depend on this guarantee
- Idempotent methods (GET, HEAD, OPTIONS, PUT, DELETE) can be safely retried after network failures because repeating them produces the same result
- POST creates resources or triggers processes and is neither safe nor idempotent — the client cannot safely retry without deduplication logic
- PUT replaces an entire resource while PATCH modifies only the specified fields — confusing them causes data loss
- Always return 405 Method Not Allowed with an `Allow` header when a client uses the wrong method, rather than silently ignoring it or returning 404

## Next

In [Lesson 05 — Headers & MIME Types](lesson-05-headers-mime-types.md), we explore the most important HTTP headers in depth — content negotiation, caching directives, authentication, and how MIME types tell the client what it is receiving.
