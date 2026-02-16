# Module 07 — HTTP From Scratch

> HTTP is just text over TCP — until you have to parse it correctly. This module builds your understanding of the HTTP protocol from the raw bytes up through Node.js's `node:http` module, covering request/response anatomy, method semantics, routing, body parsing, and security headers. By the end, you will be able to build a fully functional HTTP server without touching a single npm package.

---

## Learning Objectives

- Trace the lifecycle of an HTTP request from TCP connection to parsed response
- Dissect request and response anatomy — method, URL, status line, headers, and body
- Implement routing with URL parsing, path parameters, and query strings using `new URL()` and `node:url`
- Parse JSON, URL-encoded, and multipart/form-data request bodies from raw Buffers
- Configure CORS headers, Content Security Policy, and other security headers to harden a server
- Build a production-aware HTTP client with redirect following, timeouts, and streaming support

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [HTTP Protocol Fundamentals](lesson-01-http-protocol-fundamentals.md) | Request/response model, HTTP/1.0 vs 1.1 vs 2, connection lifecycle, persistent connections |
| 02 | [Request Anatomy](lesson-02-request-anatomy.md) | Method, URL, headers, body; parsing the request line from raw TCP bytes |
| 03 | [Response Anatomy](lesson-03-response-anatomy.md) | Status line, status codes (1xx-5xx), headers, body, chunked transfer encoding |
| 04 | [HTTP Methods & Semantics](lesson-04-http-methods-semantics.md) | GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS; idempotency, safety, cacheability |
| 05 | [Headers & MIME Types](lesson-05-headers-mime-types.md) | Content-Type, Content-Length, Accept, Cache-Control, ETag, custom headers, content negotiation |
| 06 | [The http Module](lesson-06-http-module.md) | `http.createServer`, `IncomingMessage`, `ServerResponse`, request/response lifecycle and events |
| 07 | [Routing & URL Parsing](lesson-07-routing-url-parsing.md) | `new URL()`, pathname matching, query parameters, route parameters (`:id`), building a router |
| 08 | [Body Parsing & File Uploads](lesson-08-body-parsing.md) | Parsing JSON, URL-encoded, and multipart/form-data bodies without npm packages |
| 09 | [CORS & Security Headers](lesson-09-cors-security-headers.md) | Same-origin policy, CORS preflight, CSP, HSTS, X-Frame-Options, X-Content-Type-Options |

---

## Exercises

| # | Exercise | Description |
|---|----------|-------------|
| E01 | [HTTP Parser on TCP](exercise-01-http-parser-on-tcp.md) | Parse raw HTTP from a TCP socket — extract method, path, headers, body from raw bytes |
| E02 | [RESTful API Server](exercise-02-restful-api-server.md) | CRUD API for a resource (in-memory store), proper status codes, JSON request/response |
| E03 | [Static File Server with Caching](exercise-03-static-file-server-caching.md) | Serve files with `ETag`, `Last-Modified`, `If-None-Match`, `304 Not Modified` support |
| E04 | [Multipart Form Parser](exercise-04-multipart-form-parser.md) | Parse `multipart/form-data` uploads, extract boundary, save files to disk |
| E05 | [HTTP Client](exercise-05-http-client.md) | Build an HTTP client using `http.request` — handle redirects, timeouts, and streaming responses |
| E06 | [Load Tester](exercise-06-load-tester.md) | HTTP load testing tool: concurrent requests, measure latency percentiles (p50/p95/p99) |

---

## Progressive Project — Step 07: Full HTTP Protocol Implementation

This is the seventh step of the course-spanning progressive project: **Build Your Own Production HTTP Server**.

In this step you complete the HTTP layer of the framework. Everything you learned about TCP in Module 06 now gets wrapped in proper HTTP protocol handling, turning your raw socket server into something that speaks HTTP fluently.

**What you will build:**

- Full request parsing — method, URL, headers, and body extracted from raw HTTP messages
- Response builder — construct proper HTTP responses with status lines, headers, and body streaming
- Route matching with path parameters (`:id`, `:slug`) and query string extraction
- JSON and URL-encoded body parsing middleware
- CORS middleware that handles preflight `OPTIONS` requests
- Proper `Content-Length` and `Transfer-Encoding: chunked` support
- Error handling middleware that catches thrown errors and returns structured JSON error responses

**Key code pattern:**

```javascript
'use strict';

const http = require('node:http');
const { URL } = require('node:url');

class Router {
  #routes = [];

  add(method, pattern, handler) {
    const keys = [];
    const regex = pattern.replace(/:(\w+)/g, (_, key) => {
      keys.push(key);
      return '([^/]+)';
    });
    this.#routes.push({ method, regex: new RegExp(`^${regex}$`), keys, handler });
  }

  match(method, pathname) {
    for (const route of this.#routes) {
      if (route.method !== method) continue;
      const match = pathname.match(route.regex);
      if (match) {
        const params = {};
        route.keys.forEach((key, i) => { params[key] = match[i + 1]; });
        return { handler: route.handler, params };
      }
    }
    return null;
  }
}
```

**Builds on:** Step 06 (TCP Server Foundation) — you already handle raw TCP connections; now you parse and generate proper HTTP on top of them.

**Leads to:** Step 08 (Child Process Worker Pool) — you will offload CPU-intensive request handlers to child processes so the event loop stays responsive.

---

## Key Takeaways

After completing this module you will understand HTTP at the protocol level — not as an abstraction handed to you by a framework, but as a text-based protocol you can parse from raw bytes, route with pattern matching, and secure with the right headers. You will never be confused by a CORS error again.

---

## Next

Continue to [Module 08 — Unix, Processes & IPC](../module-08-unix-processes/README.md) to learn how Node.js interacts with the operating system through processes, signals, and inter-process communication.
