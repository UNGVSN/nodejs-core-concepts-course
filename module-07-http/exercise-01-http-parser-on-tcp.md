# E01: HTTP Parser on TCP

## Objective

Build a minimal HTTP/1.1 parser on top of a raw TCP socket without using the `node:http` module. You will extract the method, path, HTTP version, headers, and body from raw bytes, including support for both Content-Length and chunked Transfer-Encoding bodies. This exercise forces you to understand what `node:http` does under the hood at the byte level — the same parsing that `llhttp` (Node's C parser) performs millions of times per second in production.

## Prerequisites

- Module 03 / Lesson 03 — Buffer Operations
- Module 06 / Lesson 03 — TCP Server and Client
- Module 06 / Lesson 04 — Framing and Protocols
- Module 07 / Lesson 01 — HTTP Protocol Fundamentals
- Module 07 / Lesson 02 — Request Anatomy

## Instructions

1. Create a file called `http-parser-tcp.js`. Add `'use strict';` at the top. Require only `node:net`.

2. Define a `parseRequestLine(line)` function that takes the first line of an HTTP request (e.g., `GET /api/users HTTP/1.1`) and returns an object `{ method, path, version }`. Split the line on spaces — there should be exactly three parts. Validate that the method is one of `GET`, `POST`, `PUT`, `DELETE`, `HEAD`, `OPTIONS`, `PATCH`. Validate that the version matches `HTTP/1.0` or `HTTP/1.1`. Throw a descriptive error if any validation fails.

3. Define a `parseHeaders(headerLines)` function that takes an array of raw header lines and returns a `Map` of lowercase header names to values. Each header line has the format `Header-Name: value`. Handle multi-value headers (e.g., multiple `Set-Cookie`) by storing an array. Trim whitespace from values. Reject header names that contain invalid characters (only alphanumeric and hyphens are allowed).

4. Define a `parseChunkedBody(raw)` function that decodes a chunked Transfer-Encoding body. The format is:
   ```
   <chunk-size-in-hex>\r\n
   <chunk-data>\r\n
   <chunk-size-in-hex>\r\n
   <chunk-data>\r\n
   0\r\n
   \r\n
   ```
   Read the chunk size (hex), then that many bytes of data, then `\r\n`, repeating until a `0\r\n\r\n` terminator. Return the concatenated body as a `Buffer`.

5. Create a TCP server on port 4000. When a connection arrives, accumulate incoming data into a buffer. Detect the end of headers by scanning for `\r\n\r\n`. Once found, split on that delimiter — everything before is headers, everything after is the start of the body. Parse the request line (first line) and the remaining header lines.

6. After parsing headers, determine the body strategy:
   - If `Transfer-Encoding: chunked`, call `parseChunkedBody` on the remaining bytes.
   - If `Content-Length` is present, wait until you have accumulated exactly that many body bytes. If more `data` events are needed, keep accumulating.
   - Otherwise, assume no body (GET, HEAD, DELETE typically have none).

7. Log the parsed request to the console as a structured object: `{ method, path, version, headers: [...], bodyLength: N }`. If the body is present and the Content-Type is `application/json`, also log the parsed JSON body.

8. Write a helper function `sendResponse(socket, statusCode, statusText, headers, body)` that constructs a valid HTTP/1.1 response from parts. The function must:
   - Write the status line: `HTTP/1.1 <code> <text>\r\n`
   - Write each header: `<name>: <value>\r\n`
   - Write the blank line: `\r\n`
   - Write the body (if any)
   Use this helper to respond with `200 OK` and a JSON body confirming what was parsed.

9. Test with `curl`:
   ```bash
   # Simple GET
   curl -v http://localhost:4000/hello

   # POST with JSON body (Content-Length)
   curl -X POST -d '{"name":"node"}' -H "Content-Type: application/json" http://localhost:4000/api/data

   # POST with chunked encoding
   curl -X POST -H "Transfer-Encoding: chunked" -d @- http://localhost:4000/chunked <<< "hello chunked world"

   # HEAD request (no body expected in response)
   curl -I http://localhost:4000/status
   ```

10. Add error handling: if the request line is malformed, respond with `400 Bad Request`. If the method is not recognized, respond with `405 Method Not Allowed`. If the accumulated buffer exceeds 1 MB before the header boundary is found, respond with `413 Payload Too Large`. Close the socket after responding to each request.

## Break-Then-Harden Challenge

1. **Incomplete headers (Slowloris attack).** Send a request that never sends `\r\n\r\n` — use `nc` or a raw TCP client that writes one byte per second and hangs. This is the Slowloris denial-of-service pattern. Observe your parser waiting forever and holding the connection open. Fix it by adding a 5-second timeout on the socket (`socket.setTimeout(5000)`) and destroying the socket on timeout with an appropriate error log.

2. **Oversized headers.** Send a request with a 1 MB header value using `nc` or a custom script. Observe memory consumption growing. Fix it by checking `buffer.length` on every `data` event — if the accumulated buffer exceeds 8 KB before the header boundary is found, respond with `431 Request Header Fields Too Large` and destroy the socket immediately.

3. **Malformed chunked encoding.** Send a chunked body where the chunk size is not valid hex (e.g., `XYZ\r\n`). Observe the crash or `NaN` from `parseInt`. Fix it by validating the hex parse — check that `parseInt(sizeStr, 16)` returns a finite, non-negative number. If not, respond with `400 Bad Request` and close the connection.

## Expected Output

```
$ node http-parser-tcp.js
TCP server listening on port 4000

--- Incoming Request ---
{
  method: 'GET',
  path: '/hello',
  version: 'HTTP/1.1',
  headers: [
    [ 'host', 'localhost:4000' ],
    [ 'user-agent', 'curl/8.x.x' ],
    [ 'accept', '*/*' ]
  ],
  bodyLength: 0
}
Responded: 200 OK -> {"method":"GET","path":"/hello","bodyLength":0}

--- Incoming Request ---
{
  method: 'POST',
  path: '/api/data',
  version: 'HTTP/1.1',
  headers: [
    [ 'host', 'localhost:4000' ],
    [ 'content-type', 'application/json' ],
    [ 'content-length', '15' ]
  ],
  bodyLength: 15,
  body: { name: 'node' }
}
Responded: 200 OK -> {"method":"POST","path":"/api/data","bodyLength":15}

--- Incoming Request ---
{
  method: 'POST',
  path: '/chunked',
  version: 'HTTP/1.1',
  headers: [
    [ 'host', 'localhost:4000' ],
    [ 'transfer-encoding', 'chunked' ]
  ],
  bodyLength: 19
}
Responded: 200 OK -> {"method":"POST","path":"/chunked","bodyLength":19}

--- Error ---
Malformed request line: "INVALID"
Responded: 400 Bad Request
```

## Bonus

1. Add support for HTTP pipelining: handle multiple requests arriving on the same TCP connection without closing it. Respond to each in order, using `Connection: keep-alive` unless the client sends `Connection: close`. This requires resetting your buffer state after each request and re-scanning for the next `\r\n\r\n`.

2. Parse query string parameters from the path (e.g., `/search?q=node&page=2` returns `{ q: 'node', page: '2' }`). Use only string splitting — split on `?` to separate path from query, then split on `&` to get key-value pairs, then split each on `=` and decode with `decodeURIComponent()`. Do not use `URL` or `URLSearchParams`.

## Hints

1. The header/body boundary is always `\r\n\r\n` (two consecutive CRLFs). The first CRLF ends the last header line; the second CRLF marks the empty line separating headers from body.
2. Chunked encoding sizes are hexadecimal. Use `parseInt(chunk, 16)` to convert. A chunk size of `0` indicates the end of the body.
3. `Buffer.indexOf('\r\n\r\n')` is the fastest way to find the header boundary in accumulated data. It returns `-1` if not found.
4. Remember that TCP delivers data in arbitrary chunks — a single `data` event may contain a partial request, a complete request, or multiple requests. Always accumulate into a buffer before parsing, and handle the case where the header boundary spans two `data` events.
5. When writing raw HTTP responses, every line must end with `\r\n`, and there must be a blank line (`\r\n`) between headers and body.
6. Use `Buffer.concat(chunks)` to join accumulated data efficiently. Do not convert to strings until you need to parse text — the body may contain binary data.
7. The `Content-Length` header value is a decimal string. Parse it with `parseInt(value, 10)` and validate that it is a non-negative integer before using it to slice the body from the buffer.
