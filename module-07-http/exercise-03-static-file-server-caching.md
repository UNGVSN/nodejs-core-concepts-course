# E03: Static File Server with Caching

## Objective

Build a static file server that serves files from a directory with full HTTP caching support. You will implement ETag generation via content hashing, Last-Modified timestamps, conditional request handling (304 Not Modified), Cache-Control headers, and MIME type detection — the same caching layer that production servers like nginx provide.

## Prerequisites

- Module 03 / Lesson 03 — Buffer Operations
- Module 04 / Lesson 03 — Reading Files
- Module 05 / Lesson 02 — Readable Streams
- Module 07 / Lesson 03 — Response Anatomy
- Module 07 / Lesson 05 — Headers and MIME Types

## Instructions

1. Create a file called `static-server.js`. Add `'use strict';` at the top. Require `node:http`, `node:fs`, `node:path`, and `node:crypto`.

2. Define a constant `STATIC_ROOT` that resolves to a `./public` directory relative to the script using `path.resolve(__dirname, 'public')`. Create this directory structure manually before running:
   ```
   public/
     index.html          (any simple HTML page)
     style.css           (any CSS file)
     script.js           (any JS file)
     logo.png            (any small image — even a 1x1 pixel PNG)
     docs/
       readme.txt        (any text content)
   ```

3. Build a MIME type lookup function `getMimeType(filePath)` using a plain object as a lookup table:
   ```javascript
   const MIME_TYPES = {
     '.html': 'text/html; charset=utf-8',
     '.css':  'text/css',
     '.js':   'application/javascript',
     '.json': 'application/json',
     '.png':  'image/png',
     '.jpg':  'image/jpeg',
     '.gif':  'image/gif',
     '.svg':  'image/svg+xml',
     '.txt':  'text/plain',
     '.ico':  'image/x-icon',
     '.woff2':'font/woff2',
   };
   ```
   Extract the extension with `path.extname(filePath).toLowerCase()`. Default to `application/octet-stream` for unknown extensions.

4. Write a function `generateETag(content)` that computes a strong ETag from the file content using `crypto.createHash('sha256')`. Hash the content, take the first 32 hex characters (to keep it short), and wrap in double quotes (e.g., `"e3b0c44298fc1c149afb4c83..."`). Strong ETags guarantee byte-for-byte equality.

5. For each incoming request, resolve the file path by joining `STATIC_ROOT` with the decoded request URL. **Prevent directory traversal attacks**: use `path.resolve()` and verify the resulting absolute path starts with the resolved `STATIC_ROOT`. If it does not, respond with `403 Forbidden` and log the attempted path to the console.

6. Use `fs.stat()` (callback or promise version) to check if the file exists and is a regular file. If it is a directory, check whether it contains an `index.html` and serve that instead. If the file does not exist, respond with `404 Not Found` and a simple HTML error page.

7. Implement conditional GET with **ETag**:
   - Read the file content into a Buffer, generate the ETag.
   - If the request has an `If-None-Match` header, compare it against the generated ETag. The header may contain multiple ETags separated by commas — check if any match.
   - If a match is found, respond with `304 Not Modified` (no body, but include the ETag header).
   - Otherwise, send the full file with the `ETag` header.

8. Implement conditional GET with **Last-Modified**:
   - Use `stat.mtime` to get the last modification time.
   - Set the `Last-Modified` header to `stat.mtime.toUTCString()`.
   - If the request has an `If-Modified-Since` header, parse it with `new Date()` and compare against `stat.mtime`. If the file has not been modified since that time, respond with `304 Not Modified`.
   - Note: ETag takes precedence — if `If-None-Match` is present, ignore `If-Modified-Since` (per RFC 7232).

9. Add `Cache-Control` headers based on file type:
   - HTML files: `Cache-Control: no-cache` (always revalidate with the server).
   - CSS/JS files: `Cache-Control: public, max-age=31536000, immutable` (1 year cache, for fingerprinted/versioned assets).
   - Images: `Cache-Control: public, max-age=86400` (1 day).
   - Everything else: `Cache-Control: public, max-age=3600` (1 hour).
   The `no-cache` directive does NOT mean "do not cache" — it means "cache, but revalidate every time." This is different from `no-store`.

10. Stream the file to the response using `fs.createReadStream()` instead of reading the entire file into memory for the response body. Set the `Content-Length` header from `stat.size` and the `Content-Type` from `getMimeType()`. Handle the `'error'` event on the read stream (e.g., file deleted between stat and read). Start the server on port 3000 and log the STATIC_ROOT path.

## Break-Then-Harden Challenge

1. **Directory traversal.** Request `http://localhost:3000/../../etc/passwd`. Observe whether your path resolution leaks files outside `STATIC_ROOT`. If it does, fix the `path.resolve` check. Test with `curl --path-as-is` to prevent curl from normalizing the path before sending. Also test with encoded dots: `http://localhost:3000/%2e%2e/%2e%2e/etc/passwd`.

2. **Race condition with ETag.** Open two terminals. In one, send a request for a file. In the other, modify the file between the `stat` call and the `read` call (e.g., `echo "changed" >> public/style.css` timed between the two). Observe a stale ETag being sent for the old content. Fix it by re-reading the stat after computing the ETag and comparing mtimes, or by computing the ETag from the stream as you send it (stream the file through a hash transform, capture the hash, and send it in a trailing header or fall back to a weak ETag).

3. **Large file memory exhaustion.** Create a 1 GB test file: `dd if=/dev/zero of=public/large.bin bs=1M count=1024`. Observe what happens if you read the entire file into memory to compute the ETag. Your process will consume 1 GB+ of RSS. Fix it by using a streaming hash (pipe the file through `crypto.createHash('sha256')` as a transform stream), or fall back to a weak ETag based on `mtime` and `size` for files above a threshold (e.g., 10 MB): `W/"${stat.size}-${stat.mtimeMs}"`.

## Expected Output

```
$ node static-server.js
Static file server listening on port 3000
Serving files from /Users/you/project/public

# First request — full 200 response with caching headers
$ curl -v http://localhost:3000/index.html
> GET /index.html HTTP/1.1
< HTTP/1.1 200 OK
< Content-Type: text/html; charset=utf-8
< ETag: "e3b0c44298fc1c149afb..."
< Last-Modified: Sat, 15 Feb 2026 10:00:00 GMT
< Cache-Control: no-cache
< Content-Length: 234
<
<!DOCTYPE html>...

# Second request with matching ETag — 304 (no body transferred)
$ curl -v -H 'If-None-Match: "e3b0c44298fc1c149afb..."' http://localhost:3000/index.html
> GET /index.html HTTP/1.1
> If-None-Match: "e3b0c44298fc1c149afb..."
< HTTP/1.1 304 Not Modified
< ETag: "e3b0c44298fc1c149afb..."
< Cache-Control: no-cache
(no body — 0 bytes transferred)

# CSS file — long cache, immutable
$ curl -v http://localhost:3000/style.css
< HTTP/1.1 200 OK
< Content-Type: text/css
< Cache-Control: public, max-age=31536000, immutable
< ETag: "7c211433f02024a5b5..."
< Content-Length: 89

# Directory request — serves index.html
$ curl -v http://localhost:3000/
< HTTP/1.1 200 OK
< Content-Type: text/html; charset=utf-8

# Directory traversal — blocked
$ curl --path-as-is http://localhost:3000/../../etc/passwd
< HTTP/1.1 403 Forbidden

# 404 — file does not exist
$ curl -v http://localhost:3000/nonexistent.html
< HTTP/1.1 404 Not Found
```

## Bonus

1. Add support for `Accept-Encoding: gzip`. If the client accepts gzip, compress the response body using `node:zlib` and set `Content-Encoding: gzip`. Skip compression for images and files smaller than 1 KB.

2. Implement `Range` request support for partial content (status `206`). Parse the `Range` header, serve the requested byte range, and set `Content-Range` and `Accept-Ranges: bytes` headers. This enables resumable downloads and video seeking.

## Hints

1. `path.resolve('/safe/root', '../../../etc/passwd')` resolves to `/etc/passwd` — always check the resolved path starts with your root before serving. Use `resolvedPath.startsWith(STATIC_ROOT)` as the guard.
2. `crypto.createHash('sha256').update(content).digest('hex')` gives you a consistent hash for ETag generation. Truncate to the first 32 characters for readability.
3. A `304` response must include the same `ETag`, `Cache-Control`, and `Last-Modified` headers as a `200` — only the body is omitted. The status code tells the client "your cached copy is still valid."
4. Compare `If-Modified-Since` by parsing both dates and checking if the file's mtime is less than or equal to the header's date. Use `new Date(header).getTime()` for comparison. Be careful: `mtime` has millisecond precision but HTTP dates only have second precision, so truncate mtime to seconds before comparing.
5. `fs.createReadStream(filePath)` returns a Readable that you can pipe directly to `res` — this avoids loading the entire file into memory.
6. Decode `req.url` with `decodeURIComponent()` before joining with the root path — URLs may contain `%20` for spaces and other encoded characters.
7. Handle the `'error'` event on the read stream: if the file is deleted between the `stat` call and the `createReadStream` call, catch the error and respond with `500` instead of crashing.
