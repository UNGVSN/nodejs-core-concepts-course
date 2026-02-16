# E05: HTTP Client

## Objective

Build a robust HTTP client using `node:http` and `node:https` that handles redirects, timeouts, streaming responses, JSON parsing, and error recovery. You will implement the same redirect-following and timeout logic that libraries like `axios` and `node-fetch` provide, using nothing but the standard library.

## Prerequisites

- Module 03 / Lesson 02 — Encoding and Decoding
- Module 05 / Lesson 02 — Readable Streams
- Module 07 / Lesson 01 — HTTP Protocol Fundamentals
- Module 07 / Lesson 03 — Response Anatomy
- Module 07 / Lesson 05 — Headers and MIME Types
- Module 07 / Lesson 06 — The HTTP Module

## Instructions

1. Create a file called `http-client.js`. Add `'use strict';` at the top. Require `node:http`, `node:https`, and `node:url`.

2. Write a function `request(urlString, options)` that returns a Promise resolving to a response object. The `options` parameter accepts:
   - `method` (default `'GET'`)
   - `headers` (default `{}`)
   - `body` (string or Buffer, default `null`)
   - `timeout` (milliseconds, default `5000`)
   - `maxRedirects` (default `5`)
   - `followRedirects` (default `true`)
   Use `Object.assign` or spread to merge defaults with the caller's options so that any unspecified option falls back to its default value.

3. Inside `request`, parse the URL with `new URL(urlString)`. Validate that the protocol is `http:` or `https:` — reject with a clear error for any other protocol. Choose `http` or `https` module based on the protocol. Construct the options object for `http.request()` or `https.request()` with `hostname`, `port` (defaulting to 80 or 443 if not specified), `path` (including the search/query string), `method`, and `headers`. If a body is provided, add `Content-Length` header with `Buffer.byteLength(body)`.

4. Implement redirect following: if the response status is `301`, `302`, `303`, `307`, or `308`:
   - Read the `Location` header. If missing, reject with `"Redirect with no Location header"`.
   - Resolve it against the original URL using `new URL(location, urlString)` — this handles both relative (`/path`) and absolute (`http://other.com`) redirects.
   - Decrement the redirect counter. If it reaches zero, reject with `"Too many redirects (max ${maxRedirects})"`.
   - For `303`, always change the method to `GET` and discard the body — this is required by the spec.
   - For `301` and `302`, change POST to GET (following browser convention). For `307` and `308`, preserve the original method and body.
   - Recursively call `request` with the new URL and updated options.

5. Implement timeout handling: call `req.setTimeout(options.timeout)` and listen for the `'timeout'` event. When it fires, call `req.destroy()` and reject the Promise with an error `"Request timed out after Xms"`.

6. Collect the response body by accumulating chunks from the response stream. Return a response object:
   ```javascript
   {
     status: res.statusCode,
     headers: res.headers,
     body: bodyBuffer,
     text() { return bodyBuffer.toString('utf-8'); },
     json() { return JSON.parse(bodyBuffer.toString('utf-8')); }
   }
   ```

7. Handle connection errors (`'error'` event on the request) by rejecting the Promise with the error.

8. Write convenience helper functions:
   - `get(url, options)` — calls `request` with `method: 'GET'`.
   - `post(url, body, options)` — calls `request` with `method: 'POST'`. If `body` is an object, serialize it with `JSON.stringify` and set `Content-Type: application/json`.
   - `put(url, body, options)` — same as `post` but with `method: 'PUT'`.
   - `del(url, options)` — calls `request` with `method: 'DELETE'`.

9. Create a test section at the bottom of the file that exercises the client:
   ```javascript
   async function main() {
     // Test 1: Simple GET
     const r1 = await get('http://httpbin.org/get');
     console.log('GET status:', r1.status);

     // Test 2: POST with JSON
     const r2 = await post('http://httpbin.org/post', { hello: 'world' });
     console.log('POST status:', r2.status);

     // Test 3: Redirect following
     const r3 = await get('http://httpbin.org/redirect/3');
     console.log('Redirect status:', r3.status);

     // Test 4: Timeout
     try {
       await get('http://httpbin.org/delay/10', { timeout: 2000 });
     } catch (err) {
       console.log('Timeout error:', err.message);
     }
   }
   main().catch(console.error);
   ```

10. Add a `--verbose` mode: if `process.argv.includes('--verbose')`, log each request and redirect to stderr (`console.error`) with the method, URL, status code, and response time. Format the log lines as:
    ```
    [->] GET http://example.com/path
    [<-] 200 OK (45ms)
    ```
    For redirects, show the chain clearly:
    ```
    [->] GET http://example.com/old
    [<-] 301 -> http://example.com/new (12ms)
    [->] GET http://example.com/new
    [<-] 200 OK (38ms)
    ```

## Break-Then-Harden Challenge

1. **Redirect loop.** Set up a local server that redirects `/a` to `/b` and `/b` to `/a`:
   ```javascript
   const loopServer = http.createServer((req, res) => {
     const target = req.url === '/a' ? '/b' : '/a';
     res.writeHead(302, { Location: target });
     res.end();
   });
   ```
   Point your client at it with `maxRedirects: 10`. Observe it looping until the counter runs out. Verify the error message is clear. Then add redirect loop detection: track visited URLs in a Set and reject immediately if the same URL is encountered twice.

2. **Partial response hang.** Set up a local server that sends headers and half the body, then stops writing without closing the connection. Observe your client hanging forever waiting for the `'end'` event. Fix it by adding a response timeout: if no `data` event arrives for 10 seconds after the response starts, destroy the socket and reject with `"Response stalled"`.

3. **HTTPS certificate error.** Make a request to a server with a self-signed certificate. Observe the `UNABLE_TO_VERIFY_LEAF_SIGNATURE` or `SELF_SIGNED_CERT_IN_CHAIN` error. Understand why you should NOT set `rejectUnauthorized: false` in production — it disables all certificate validation, making the connection vulnerable to man-in-the-middle attacks. Log a warning to stderr if someone passes that option.

## Expected Output

```
$ node http-client.js --verbose
[->] GET http://httpbin.org/get
[<-] 200 OK
GET status: 200

[->] POST http://httpbin.org/post
[<-] 200 OK
POST status: 200

[->] GET http://httpbin.org/redirect/3
[<-] 302 -> http://httpbin.org/redirect/2
[->] GET http://httpbin.org/redirect/2
[<-] 302 -> http://httpbin.org/redirect/1
[->] GET http://httpbin.org/redirect/1
[<-] 302 -> http://httpbin.org/get
[->] GET http://httpbin.org/get
[<-] 200 OK
Redirect status: 200

[->] GET http://httpbin.org/delay/10
Timeout error: Request timed out after 2000ms
```

## Bonus

1. Add support for streaming large responses: instead of accumulating the body into memory, return a `stream` property on the response that is the raw `IncomingMessage` Readable stream. Allow callers to pipe it to a file with `response.stream.pipe(fs.createWriteStream('output.bin'))`.

2. Implement automatic retry with exponential backoff: if the request fails with a network error or receives a `503 Service Unavailable`, retry up to 3 times with delays of 1s, 2s, 4s.

## Hints

1. `new URL('/relative', 'http://base.com/path')` correctly resolves relative redirect URLs against the base.
2. Use `url.protocol === 'https:'` to decide between `http.request` and `https.request`.
3. The `Location` header may be relative (e.g., `/new-path`) or absolute (e.g., `http://other.com/path`). Always resolve it with `new URL(location, originalUrl)`.
4. `req.destroy()` immediately terminates the underlying socket — always call it on timeout before rejecting.
5. Status codes `307` and `308` require the method and body to be preserved on redirect. `301` and `302` traditionally change POST to GET (though the spec says otherwise, browsers and most clients do this).
