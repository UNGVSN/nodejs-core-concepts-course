# Module 07 / Lesson 07 — Routing & URL Parsing

> Every web framework — Express, Fastify, Koa, Hapi — has a router at its core. But a router is not magic. It is a map from `(method, path)` pairs to handler functions, with some pattern matching on top. Building one from scratch using only `node:http` and the WHATWG `URL` API teaches you exactly what those frameworks do behind the scenes, and means you will never be confused by routing behavior again.

## Learning Objectives

- Parse request URLs using the WHATWG `URL` class and extract `pathname`, `searchParams`, and other components
- Work with `URLSearchParams` to read, iterate, and manipulate query string values
- Build a complete HTTP router from scratch with `Map`-based route storage and method matching
- Implement path parameter extraction (`/users/:id`) using regular expressions
- Add middleware support so that cross-cutting concerns run before route handlers

---

## URL Parsing With the WHATWG `URL` API

Node.js ships with the WHATWG `URL` standard — the same API available in browsers. The legacy `url.parse()` function is deprecated. Always use `new URL()`.

### The Problem With `req.url`

The `req.url` property on an `http.IncomingMessage` is **not** a full URL. It contains only the path and query string:

```
Full URL:   http://example.com:3000/users?page=2&sort=name
req.url:    /users?page=2&sort=name
```

It does **not** include the protocol, host, or port. To use the `URL` constructor, you must provide a base:

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // Construct a full URL from req.url and the Host header
  const base = `http://${req.headers.host}`;
  const url = new URL(req.url, base);

  console.log('href:       ', url.href);
  console.log('protocol:   ', url.protocol);   // 'http:'
  console.log('host:       ', url.host);        // '127.0.0.1:3000'
  console.log('hostname:   ', url.hostname);    // '127.0.0.1'
  console.log('port:       ', url.port);        // '3000'
  console.log('pathname:   ', url.pathname);    // '/users'
  console.log('search:     ', url.search);      // '?page=2&sort=name'
  console.log('searchParams:', url.searchParams); // URLSearchParams object
  console.log('hash:       ', url.hash);        // '' (browsers strip hash before sending)

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    pathname: url.pathname,
    params: Object.fromEntries(url.searchParams),
  }));
});

server.listen(3000, () => {
  console.log('URL parser on port 3000');
  console.log('Try: http://127.0.0.1:3000/users?page=2&sort=name');
});
```

### URL Components Diagram

```
  http://user:pass@example.com:8080/api/users?sort=name&page=2#results
  └─┬──┘ └──┬───┘ └───┬─────┘└┬─┘└───┬────┘ └──────┬───────┘ └──┬──┘
  protocol  auth    hostname  port  pathname    search          hash
            └────┬────┘
               host
```

Note: The hash (`#results`) is never sent to the server by browsers. It stays client-side. You will only see it if you construct URLs manually.

### Handling Edge Cases

```javascript
'use strict';

// Paths with encoded characters
const url1 = new URL('/hello%20world', 'http://localhost');
console.log(url1.pathname);  // '/hello%20world'

// Paths with dots (no normalization)
const url2 = new URL('/api/../secret', 'http://localhost');
console.log(url2.pathname);  // '/secret' — URL class resolves '..'

// Trailing slashes
const url3 = new URL('/users/', 'http://localhost');
const url4 = new URL('/users', 'http://localhost');
console.log(url3.pathname);  // '/users/'
console.log(url4.pathname);  // '/users'
// These are different routes — decide on a convention and normalize
```

---

## Working With `URLSearchParams`

The `url.searchParams` property returns a `URLSearchParams` instance, which provides a rich API for working with query strings.

```javascript
'use strict';

const url = new URL('http://localhost/search?q=nodejs&page=2&tag=backend&tag=api');

const params = url.searchParams;

// .get() — returns the first value for a key, or null
console.log(params.get('q'));      // 'nodejs'
console.log(params.get('page'));   // '2' (always a string)
console.log(params.get('tag'));    // 'backend' (first value only)
console.log(params.get('missing'));// null

// .getAll() — returns all values for a key
console.log(params.getAll('tag')); // ['backend', 'api']

// .has() — check if a key exists
console.log(params.has('q'));      // true
console.log(params.has('limit')); // false

// .entries() — iterate over [key, value] pairs
for (const [key, value] of params.entries()) {
  console.log(`  ${key} = ${value}`);
}
// Output:
//   q = nodejs
//   page = 2
//   tag = backend
//   tag = api

// .forEach() — callback-style iteration
params.forEach((value, key) => {
  console.log(`  ${key}: ${value}`);
});

// Convert to a plain object (loses duplicate keys)
const obj = Object.fromEntries(params);
console.log(obj); // { q: 'nodejs', page: '2', tag: 'api' } — only last 'tag' kept

// .toString() — serialize back to a query string
console.log(params.toString()); // 'q=nodejs&page=2&tag=backend&tag=api'
```

### Building Query Strings

```javascript
'use strict';

// Create URLSearchParams from an object
const params = new URLSearchParams({
  q: 'node.js tutorials',
  page: '1',
  limit: '20',
});

console.log(params.toString());
// 'q=node.js+tutorials&page=1&limit=20'
// Note: spaces become '+' (application/x-www-form-urlencoded)

// Add, set, and delete
params.append('tag', 'backend');
params.append('tag', 'javascript');
params.set('page', '2');     // Replace existing value
params.delete('limit');      // Remove a key

console.log(params.toString());
// 'q=node.js+tutorials&page=2&tag=backend&tag=javascript'

// Sort alphabetically by key
params.sort();
console.log(params.toString());
// 'page=2&q=node.js+tutorials&tag=backend&tag=javascript'
```

---

## A Simple Router: Method + Pathname

The simplest router matches the combination of HTTP method and URL pathname.

```javascript
'use strict';

const http = require('node:http');

// Route storage: Map<string, Function>
const routes = new Map();

function addRoute(method, path, handler) {
  const key = `${method.toUpperCase()} ${path}`;
  routes.set(key, handler);
}

function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const key = `${req.method} ${url.pathname}`;
  const handler = routes.get(key);

  if (handler) {
    handler(req, res, url);
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not Found', path: url.pathname }));
  }
}

// ── Register routes ──

addRoute('GET', '/', (req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ message: 'Welcome to the API' }));
});

addRoute('GET', '/health', (req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
});

addRoute('POST', '/echo', (req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ echo: body }));
  });
});

// ── Start server ──

const server = http.createServer(handleRequest);
server.listen(3000, () => {
  console.log('Simple router on port 3000');
});
```

This works, but it cannot handle dynamic paths like `/users/42` or `/posts/abc-123`.

---

## Path Parameters: `/users/:id`

Path parameters let you capture dynamic segments of the URL. Express uses `:param` syntax. We can implement the same thing with regular expressions.

### Converting a Pattern to a RegExp

The pattern `/users/:id/posts/:postId` should match URLs like `/users/42/posts/7` and extract `{ id: '42', postId: '7' }`.

```javascript
'use strict';

/**
 * Convert a route pattern like '/users/:id/posts/:postId'
 * into a RegExp and a list of parameter names.
 *
 * @param {string} pattern - Route pattern with :param placeholders
 * @returns {{ regex: RegExp, paramNames: string[] }}
 */
function compilePattern(pattern) {
  const paramNames = [];

  // Replace :paramName with a capturing group
  const regexStr = pattern.replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (match, name) => {
    paramNames.push(name);
    return '([^/]+)'; // Match any character except '/'
  });

  // Anchor the regex to match the full pathname
  const regex = new RegExp(`^${regexStr}$`);

  return { regex, paramNames };
}

// Test
const { regex, paramNames } = compilePattern('/users/:id/posts/:postId');
console.log('RegExp:', regex);       // /^\/users\/([^/]+)\/posts\/([^/]+)$/
console.log('Params:', paramNames);  // ['id', 'postId']

const match = '/users/42/posts/hello-world'.match(regex);
if (match) {
  const params = {};
  paramNames.forEach((name, i) => {
    params[name] = match[i + 1]; // match[0] is the full string
  });
  console.log('Extracted:', params); // { id: '42', postId: 'hello-world' }
}
```

---

## The Complete Router

Combining method matching, exact routes, parameterized routes, and query parsing into a reusable router.

```javascript
'use strict';

const http = require('node:http');

class Router {
  #routes = [];

  /**
   * Register a route.
   * @param {string} method - HTTP method
   * @param {string} pattern - URL pattern (e.g., '/users/:id')
   * @param {...Function} handlers - One or more handler functions
   */
  #addRoute(method, pattern, handlers) {
    const paramNames = [];
    const regexStr = pattern.replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (_, name) => {
      paramNames.push(name);
      return '([^/]+)';
    });
    const regex = new RegExp(`^${regexStr}$`);

    this.#routes.push({ method, pattern, regex, paramNames, handlers });
  }

  get(pattern, ...handlers)    { this.#addRoute('GET', pattern, handlers); }
  post(pattern, ...handlers)   { this.#addRoute('POST', pattern, handlers); }
  put(pattern, ...handlers)    { this.#addRoute('PUT', pattern, handlers); }
  patch(pattern, ...handlers)  { this.#addRoute('PATCH', pattern, handlers); }
  delete(pattern, ...handlers) { this.#addRoute('DELETE', pattern, handlers); }

  /**
   * Handle an incoming request.
   * @param {http.IncomingMessage} req
   * @param {http.ServerResponse} res
   */
  handle(req, res) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;

    // Find the first matching route
    for (const route of this.#routes) {
      if (route.method !== req.method) continue;

      const match = pathname.match(route.regex);
      if (!match) continue;

      // Extract path parameters
      const params = {};
      route.paramNames.forEach((name, i) => {
        params[name] = decodeURIComponent(match[i + 1]);
      });

      // Attach parsed data to the request
      req.params = params;
      req.query = Object.fromEntries(url.searchParams);
      req.pathname = pathname;

      // Run handlers in sequence (middleware + final handler)
      this.#runHandlers(route.handlers, 0, req, res);
      return;
    }

    // No route matched — 404
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: 'Not Found',
      method: req.method,
      path: pathname,
    }));
  }

  #runHandlers(handlers, index, req, res) {
    if (index >= handlers.length) return;

    const handler = handlers[index];

    // If the handler accepts a 'next' parameter, treat it as middleware
    if (handler.length >= 3) {
      handler(req, res, () => {
        this.#runHandlers(handlers, index + 1, req, res);
      });
    } else {
      handler(req, res);
    }
  }
}

module.exports = { Router };
```

### Using the Router

```javascript
'use strict';

const http = require('node:http');

// ── Router implementation (inline for this example) ──

class Router {
  #routes = [];

  #addRoute(method, pattern, handlers) {
    const paramNames = [];
    const regexStr = pattern.replace(/:([a-zA-Z_][a-zA-Z0-9_]*)/g, (_, name) => {
      paramNames.push(name);
      return '([^/]+)';
    });
    const regex = new RegExp(`^${regexStr}$`);
    this.#routes.push({ method, pattern, regex, paramNames, handlers });
  }

  get(pattern, ...handlers)    { this.#addRoute('GET', pattern, handlers); }
  post(pattern, ...handlers)   { this.#addRoute('POST', pattern, handlers); }
  put(pattern, ...handlers)    { this.#addRoute('PUT', pattern, handlers); }
  delete(pattern, ...handlers) { this.#addRoute('DELETE', pattern, handlers); }

  handle(req, res) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;

    for (const route of this.#routes) {
      if (route.method !== req.method) continue;
      const match = pathname.match(route.regex);
      if (!match) continue;

      const params = {};
      route.paramNames.forEach((name, i) => {
        params[name] = decodeURIComponent(match[i + 1]);
      });

      req.params = params;
      req.query = Object.fromEntries(url.searchParams);
      req.pathname = pathname;

      this.#runHandlers(route.handlers, 0, req, res);
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not Found', path: pathname }));
  }

  #runHandlers(handlers, index, req, res) {
    if (index >= handlers.length) return;
    const handler = handlers[index];
    if (handler.length >= 3) {
      handler(req, res, () => this.#runHandlers(handlers, index + 1, req, res));
    } else {
      handler(req, res);
    }
  }
}

// ── Application ──

const router = new Router();

// In-memory data store
const users = new Map();
users.set('1', { id: '1', name: 'Alice', email: 'alice@example.com' });
users.set('2', { id: '2', name: 'Bob', email: 'bob@example.com' });

// ── Middleware ──

function logger(req, res, next) {
  const start = Date.now();
  res.on('finish', () => {
    const elapsed = Date.now() - start;
    console.log(`${req.method} ${req.pathname} ${res.statusCode} ${elapsed}ms`);
  });
  next();
}

// ── Routes ──

router.get('/users', logger, (req, res) => {
  const allUsers = Array.from(users.values());

  // Apply query filters
  const { name } = req.query;
  const filtered = name
    ? allUsers.filter((u) => u.name.toLowerCase().includes(name.toLowerCase()))
    : allUsers;

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(filtered));
});

router.get('/users/:id', logger, (req, res) => {
  const user = users.get(req.params.id);

  if (!user) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'User not found' }));
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(user));
});

router.post('/users', logger, (req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString());
      const id = String(users.size + 1);
      const user = { id, name: body.name, email: body.email };
      users.set(id, user);

      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(user));
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
});

router.delete('/users/:id', logger, (req, res) => {
  const deleted = users.delete(req.params.id);

  if (!deleted) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'User not found' }));
  }

  res.writeHead(204);
  res.end();
});

// ── Start server ──

const server = http.createServer((req, res) => router.handle(req, res));

server.listen(3000, () => {
  console.log('Router server on port 3000');
  console.log('Routes:');
  console.log('  GET    /users');
  console.log('  GET    /users/:id');
  console.log('  POST   /users');
  console.log('  DELETE /users/:id');
});
```

### Testing the Router

```bash
# List all users
curl http://127.0.0.1:3000/users

# Get a specific user
curl http://127.0.0.1:3000/users/1

# Search by name
curl "http://127.0.0.1:3000/users?name=alice"

# Create a user
curl -X POST -H "Content-Type: application/json" \
  -d '{"name":"Charlie","email":"charlie@example.com"}' \
  http://127.0.0.1:3000/users

# Delete a user
curl -X DELETE http://127.0.0.1:3000/users/2
```

---

## Route Matching Priority

When multiple routes could match a path, the order of registration determines priority. Our router uses first-match semantics — the first route whose regex matches wins.

The key rule: register `/users/me` (exact) **before** `/users/:id` (parameterized). If you register `/users/:id` first, a request to `/users/me` matches it with `params.id = 'me'` instead of hitting the dedicated handler.

### Recommended Registration Order

```
1. Exact static routes:     GET /users/me
2. Parameterized routes:    GET /users/:id
3. Nested params:           GET /users/:id/posts/:postId
4. Catch-all (if needed):   GET *
```

---

## Normalizing Trailing Slashes

A common source of 404 bugs is inconsistent trailing slashes. `/users` and `/users/` are different pathnames.

```javascript
'use strict';

const http = require('node:http');

/**
 * Middleware that strips trailing slashes and redirects.
 * /users/ → 301 redirect to /users
 */
function stripTrailingSlash(req, res, next) {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname !== '/' && url.pathname.endsWith('/')) {
    const cleanPath = url.pathname.slice(0, -1) + url.search;
    res.writeHead(301, { 'Location': cleanPath });
    return res.end();
  }

  next();
}

/**
 * Alternative: normalize in the router without redirecting.
 */
function normalizePathname(pathname) {
  // Remove trailing slash (except for root '/')
  if (pathname.length > 1 && pathname.endsWith('/')) {
    return pathname.slice(0, -1);
  }
  return pathname;
}

// Usage in router.handle():
// const pathname = normalizePathname(url.pathname);
```

For larger applications, group related routes into separate functions (e.g., `registerUserRoutes(router)`, `registerPostRoutes(router)`) and call them from your main file. This keeps each resource's routes together and makes the codebase navigable.

---

## `req.url` Gotchas

A few things that trip up developers coming from frameworks:

| Gotcha | Example | Explanation |
|--------|---------|-------------|
| `req.url` includes query string | `'/users?page=2'` | You must parse it — do not compare `req.url === '/users'` |
| `req.url` does not include host | `'/users'` not `'http://localhost/users'` | Construct with `new URL(req.url, base)` |
| `req.url` does not include hash | Never `'#section'` | Browsers strip the hash before sending the request |
| `req.url` can be `'*'` | `OPTIONS * HTTP/1.1` | The `OPTIONS` method with `*` targets the entire server |
| `req.url` can be absolute | `'http://proxy.example.com/path'` | When Node.js is used as an HTTP proxy |

```javascript
'use strict';

const http = require('node:http');

const server = http.createServer((req, res) => {
  // BAD: This fails when there is a query string
  // if (req.url === '/users') { ... }

  // GOOD: Parse the URL and compare the pathname
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/users') {
    const page = parseInt(url.searchParams.get('page') || '1', 10);
    const limit = parseInt(url.searchParams.get('limit') || '10', 10);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ page, limit }));
    return;
  }

  res.writeHead(404);
  res.end('Not Found\n');
});

server.listen(3000);
```

---

## Key Takeaways

- Always use `new URL(req.url, base)` to parse request URLs — never compare `req.url` directly, because it includes the query string and can contain encoded characters.
- `URLSearchParams` provides `.get()`, `.getAll()`, `.has()`, `.entries()`, and `.forEach()` for clean query string access — use `Object.fromEntries(searchParams)` for a quick conversion, but be aware it drops duplicate keys.
- A complete router can be built in under 60 lines: compile `:param` patterns to RegExp at registration time, store routes in an array, and match by iterating in registration order.
- Route registration order determines priority — always register exact static routes (`/users/me`) before parameterized routes (`/users/:id`) to prevent the parameter from swallowing the literal path.
- Middleware chains work by passing a `next` function to each handler — if the handler calls `next()`, execution continues to the next handler; if it does not, the chain stops, giving each middleware veto power over the request.

---

## Next

Continue to [Lesson 08 — Body Parsing & File Uploads](lesson-08-body-parsing.md) to learn how to parse JSON bodies, URL-encoded forms, and multipart file uploads using only the Node.js standard library.
