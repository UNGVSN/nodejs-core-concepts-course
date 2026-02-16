# E02: RESTful API Server

## Objective

Build a complete CRUD API server using only the `node:http` module with an in-memory `Map` as the data store. You will implement proper HTTP method semantics, status codes, content negotiation, and JSON request/response handling — the exact mechanics that frameworks like Express abstract away from you.

## Prerequisites

- Module 03 / Lesson 02 — Encoding and Decoding
- Module 07 / Lesson 01 — HTTP Protocol Fundamentals
- Module 07 / Lesson 04 — HTTP Methods and Semantics
- Module 07 / Lesson 06 — The HTTP Module

## Instructions

1. Create a file called `rest-api.js`. Add `'use strict';` at the top. Require `node:http` and `node:crypto` (for generating UUIDs).

2. Create a `Map` called `store` to hold items. Each item has an `id` (UUID v4), `name` (string), `price` (number), and `createdAt` (ISO timestamp).

3. Write a helper function `parseBody(req)` that returns a Promise resolving to the parsed JSON body. Inside the function:
   - Create an empty array to accumulate chunks.
   - Listen for `data` events and push each chunk.
   - On `end`, join the chunks with `Buffer.concat()`, convert to string, and parse with `JSON.parse`.
   - If the body is empty (zero bytes), resolve with `null`.
   - If `JSON.parse` throws, reject with a descriptive error including the raw body snippet.
   - Track total body size and reject with a "Payload too large" error if it exceeds 1 MB.

4. Write a helper function `sendJSON(res, statusCode, data)` that sets `Content-Type: application/json`, writes the status code, and ends the response with `JSON.stringify(data)`. Also set `Content-Length` to the byte length of the serialized JSON.

5. Write a helper function `validateItem(body)` that checks:
   - `body` is a non-null object.
   - `body.name` exists, is a string, and is between 1 and 100 characters.
   - `body.price` exists, is a number, is finite, and is greater than 0.
   - Returns `{ valid: true }` or `{ valid: false, error: 'descriptive message' }`.

6. Implement the following routes with a simple `if/else` router based on `req.method` and `req.url`:

   - **GET /items** — Return all items as a JSON array. Status `200`.
   - **GET /items/:id** — Return a single item by ID. Status `200`, or `404` with `{ "error": "Item not found" }`.
   - **POST /items** — Create a new item from the JSON body. Use `validateItem` to check the body. Return the created item with status `201`. If validation fails, return `400` with `{ "error": "..." }`.
   - **PUT /items/:id** — Replace an existing item. Preserve the original `id` and `createdAt`. Return the updated item with status `200`, or `404` if not found. Validate the body the same way as POST.
   - **DELETE /items/:id** — Delete an item. Return status `204` (no body) on success, or `404` if not found.

7. For any unmatched route, return `404` with `{ "error": "Route not found" }`. For any unsupported method on a valid route, return `405` with an `Allow` header listing permitted methods (e.g., `Allow: GET, POST`).

8. Extract the `:id` parameter from the URL manually. Split `req.url` on `/` and grab the third segment. Do not use any URL parsing library beyond basic string splitting. Strip query strings by splitting on `?` first.

9. Add request logging: for every incoming request, log `[TIMESTAMP] METHOD /path -> STATUS (Xms)` to the console. Use `process.hrtime.bigint()` to measure the time from request start to response end.

10. Start the server on port 3000. Log `Server listening on port 3000` to the console. Add a global error handler on the request to catch unexpected errors and respond with `500 Internal Server Error`.

11. Test the full CRUD cycle with `curl`:
    ```bash
    # Create
    curl -s -X POST http://localhost:3000/items \
      -H "Content-Type: application/json" \
      -d '{"name":"Widget","price":9.99}' | jq .

    # List all
    curl -s http://localhost:3000/items | jq .

    # Read one (replace <id> with the UUID from the POST response)
    curl -s http://localhost:3000/items/<id> | jq .

    # Update
    curl -s -X PUT http://localhost:3000/items/<id> \
      -H "Content-Type: application/json" \
      -d '{"name":"Gadget","price":19.99}' | jq .

    # Delete
    curl -v -X DELETE http://localhost:3000/items/<id>

    # Verify deletion
    curl -s http://localhost:3000/items/<id>
    ```

## Break-Then-Harden Challenge

1. **Malformed JSON.** Send a POST with invalid JSON: `curl -X POST http://localhost:3000/items -H "Content-Type: application/json" -d '{name: broken}'`. Observe the crash or unhandled rejection. Fix it by wrapping `JSON.parse` in a try/catch inside `parseBody` and responding with `400 Bad Request` and a clear error message that includes a snippet of the invalid body.

2. **Missing Content-Type.** Send a POST without the `Content-Type: application/json` header: `curl -X POST http://localhost:3000/items -d '{"name":"test","price":1}'`. Your server may still parse it, which violates HTTP semantics. Fix it by checking that `req.headers['content-type']` includes `application/json` before attempting to parse. Respond with `415 Unsupported Media Type` otherwise.

3. **Huge payload.** Generate a large file and send it: `dd if=/dev/urandom bs=1M count=100 | base64 > /tmp/bigfile.json && curl -X POST http://localhost:3000/items -H "Content-Type: application/json" --data @/tmp/bigfile.json`. Observe memory pressure and potential OOM. Fix it by tracking accumulated body size in `parseBody` — if it exceeds 1 MB, destroy the request stream and respond with `413 Payload Too Large`.

## Expected Output

```
$ node rest-api.js
Server listening on port 3000

[2026-02-15T10:00:01.123Z] POST /items -> 201 (2ms)
[2026-02-15T10:00:02.456Z] GET /items -> 200 (0ms)
[2026-02-15T10:00:03.789Z] GET /items/a1b2c3d4-... -> 200 (0ms)
[2026-02-15T10:00:04.012Z] PUT /items/a1b2c3d4-... -> 200 (1ms)
[2026-02-15T10:00:05.345Z] DELETE /items/a1b2c3d4-... -> 204 (0ms)
[2026-02-15T10:00:06.678Z] GET /items/nonexistent -> 404 (0ms)
[2026-02-15T10:00:07.901Z] POST /items -> 400 (1ms)
[2026-02-15T10:00:08.234Z] POST /items -> 415 (0ms)
```

```json
// POST /items response (201 Created)
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "name": "Widget",
  "price": 9.99,
  "createdAt": "2026-02-15T10:00:01.123Z"
}

// GET /items response (200 OK)
[
  {
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "name": "Widget",
    "price": 9.99,
    "createdAt": "2026-02-15T10:00:01.123Z"
  }
]

// POST /items with bad body (400 Bad Request)
{
  "error": "Validation failed: 'price' must be a positive number"
}

// POST /items without Content-Type header (415 Unsupported Media Type)
{
  "error": "Content-Type must be application/json"
}
```

## Bonus

1. Add support for `PATCH /items/:id` that merges partial updates into the existing item instead of replacing the whole object. Only update fields that are present in the request body.

2. Implement pagination on `GET /items` using query parameters `?page=1&limit=10`. Return a response envelope: `{ "data": [...], "total": N, "page": 1, "limit": 10 }`.

## Hints

1. `crypto.randomUUID()` generates a RFC 4122 v4 UUID — no need to implement your own.
2. Remember that `req` is a Readable stream. You must listen for `data` and `end` events to collect the body before you can parse it. Do not try to read `req.body` directly — it does not exist in vanilla `node:http`.
3. The `:id` segment in `/items/:id` is just the third element when you `split('/')` the URL (index 2). Example: `'/items/abc-123'.split('/')` gives `['', 'items', 'abc-123']`.
4. `res.writeHead(204)` followed by `res.end()` sends a proper no-content response. Do not write a body with 204 — HTTP clients may ignore it or treat it as an error.
5. Always set `Content-Type: application/json` before writing JSON responses — clients depend on this header for parsing.
6. Use `Buffer.concat(chunks).toString('utf-8')` instead of `chunks.join('')` to safely handle multi-byte characters that might be split across chunk boundaries.
7. To measure request duration, capture `process.hrtime.bigint()` at the start of the handler and compute the difference at the end. Divide by `1e6` for milliseconds.
8. When returning `405`, include an `Allow` header listing the methods that the resource supports. For example: `res.setHeader('Allow', 'GET, POST')` for the `/items` collection endpoint.
