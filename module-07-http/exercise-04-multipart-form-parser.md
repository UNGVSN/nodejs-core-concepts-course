# E04: Multipart Form Parser

## Objective

Parse `multipart/form-data` HTTP request bodies from scratch. You will extract the boundary from the Content-Type header, split the raw body into parts, parse Content-Disposition headers to identify field names and filenames, and save uploaded files to disk. This is the protocol that every file upload on the web relies on, and you will build the parser byte by byte.

## Prerequisites

- Module 03 / Lesson 03 — Buffer Operations
- Module 04 / Lesson 04 — Writing Files
- Module 07 / Lesson 02 — Request Anatomy
- Module 07 / Lesson 06 — The HTTP Module

## Instructions

1. Create a file called `multipart-parser.js`. Add `'use strict';` at the top. Require `node:http`, `node:fs`, `node:path`, and `node:crypto`.

2. Create an `uploads` directory next to the script for storing uploaded files at startup:
   ```javascript
   const UPLOAD_DIR = path.resolve(__dirname, 'uploads');
   fs.mkdirSync(UPLOAD_DIR, { recursive: true });
   ```

3. Write a function `extractBoundary(contentType)` that parses the `Content-Type` header to extract the boundary string. The header looks like `multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxk`. Split on `; `, find the segment starting with `boundary=`, and return the value after the `=`. Throw a descriptive error if the header is missing, is not `multipart/form-data`, or has no boundary parameter.

4. Write a function `splitParts(body, boundary)` that splits the raw body `Buffer` on the boundary delimiter. The structure of a multipart body is:
   ```
   --<boundary>\r\n
   <part 1 headers>\r\n\r\n<part 1 body>\r\n
   --<boundary>\r\n
   <part 2 headers>\r\n\r\n<part 2 body>\r\n
   --<boundary>--\r\n
   ```
   Use `Buffer.indexOf()` to find each occurrence of `--<boundary>`. Extract the bytes between consecutive boundary positions. Skip the preamble (before the first boundary) and the epilogue (after the closing `--<boundary>--`). Return an array of `Buffer` objects, one per part.

5. Write a function `parsePartHeaders(part)` that separates the headers from the body within a single part. The headers end at the first `\r\n\r\n` within the part. Split the header block on `\r\n` to get individual lines, then split each line on `: ` (colon-space) to get key-value pairs. Return `{ headers: Map, body: Buffer }`.

6. Write a function `parseContentDisposition(header)` that extracts `name` and `filename` from a Content-Disposition header value like `form-data; name="file"; filename="photo.jpg"`. Split on `; `, then for each parameter, split on `=` and strip surrounding double quotes from the value. Return `{ name, filename }` where `filename` is `null` for regular text fields.

7. Write the main handler function `handleUpload(req, res)`:
   - Verify the request method is POST and Content-Type starts with `multipart/form-data`. Return `400` if not.
   - Accumulate the request body into a Buffer. Enforce a 10 MB maximum — if the body exceeds this during accumulation, destroy the request stream and respond with `413 Payload Too Large`.
   - Extract the boundary, split into parts, parse each part's headers and body.
   - For **file parts** (those with a `filename` in Content-Disposition): sanitize the filename with `path.basename()`, generate a unique storage name using `crypto.randomUUID()` combined with the original extension, and write to the `uploads` directory using `fs.writeFileSync`.
   - For **text field parts** (no `filename`): decode the body as UTF-8 and store the value as a string.
   - Collect all parsed fields and files into a result object.

8. Respond with `200 OK` and a JSON body summarizing what was received:
   ```json
   {
     "fields": { "description": "My photo" },
     "files": [
       {
         "fieldName": "file",
         "originalName": "photo.jpg",
         "savedAs": "a1b2c3d4-e5f6-7890-abcd-ef1234567890.jpg",
         "size": 45230,
         "contentType": "image/jpeg"
       }
     ]
   }
   ```
   Include the `Content-Type` of each file part if the browser/curl sends it.

9. Create the HTTP server on port 3000. Route `POST /upload` to `handleUpload`. Route `GET /` to a simple HTML form:
   ```html
   <form method="POST" action="/upload" enctype="multipart/form-data">
     <input name="description" type="text" placeholder="Description" />
     <input name="file" type="file" />
     <button type="submit">Upload</button>
   </form>
   ```
   All other routes return `404`.

10. Test with `curl`:
    ```bash
    # Single file with a text field
    curl -X POST http://localhost:3000/upload \
      -F "description=My test upload" \
      -F "file=@./test-image.png"

    # Multiple files
    curl -X POST http://localhost:3000/upload \
      -F "photo1=@./image1.jpg" \
      -F "photo2=@./image2.jpg" \
      -F "album=Vacation"

    # Text-only (no files)
    curl -X POST http://localhost:3000/upload \
      -F "name=Alice" \
      -F "email=alice@example.com"
    ```

## Break-Then-Harden Challenge

1. **Boundary injection.** Craft a file whose content contains the exact boundary string. Observe how your parser incorrectly splits the file content. Fix it by matching boundaries only at the start of a line (preceded by `\r\n` or at the beginning of the body), and always prefix boundaries with `--` as the spec requires.

2. **Missing Content-Disposition.** Send a multipart body where one part has no Content-Disposition header. Observe the crash when you try to read `name`. Fix it by validating that every part has a Content-Disposition header, and skip (or reject with 400) any parts that lack one.

3. **Filename path traversal.** Upload a file with the name `../../../etc/evil.sh`. Observe whether it writes outside the `uploads` directory. Fix it by stripping directory components from filenames using `path.basename()` and validating the resolved write path stays inside `uploads`.

## Expected Output

```
$ node multipart-parser.js
Upload directory: /Users/you/project/uploads
Multipart server listening on port 3000

$ curl -X POST http://localhost:3000/upload \
    -F "title=Vacation Photo" \
    -F "photo=@./beach.jpg"

--- Upload Received ---
Fields:
  title = "Vacation Photo"
Files:
  [1] fieldName: photo
      originalName: beach.jpg
      contentType: image/jpeg
      savedAs: 7f3a9c12-4e5b-4d8a-b2c1-3e4f5a6b7c8d.jpg
      size: 128456 bytes
      path: /Users/you/project/uploads/7f3a9c12-4e5b-4d8a-b2c1-3e4f5a6b7c8d.jpg

Response (200 OK):
{
  "fields": { "title": "Vacation Photo" },
  "files": [
    {
      "fieldName": "photo",
      "originalName": "beach.jpg",
      "contentType": "image/jpeg",
      "savedAs": "7f3a9c12-4e5b-4d8a-b2c1-3e4f5a6b7c8d.jpg",
      "size": 128456
    }
  ]
}

# Text-only submission (no files)
$ curl -X POST http://localhost:3000/upload \
    -F "name=Alice" -F "email=alice@example.com"

Response (200 OK):
{
  "fields": { "name": "Alice", "email": "alice@example.com" },
  "files": []
}

# Missing Content-Type
$ curl -X POST http://localhost:3000/upload \
    -H "Content-Type: application/json" -d '{}'
Response (400 Bad Request):
{
  "error": "Expected multipart/form-data Content-Type"
}
```

## Bonus

1. Add support for multiple files in a single field (e.g., `<input type="file" multiple name="photos">`). When the same field name appears multiple times, collect all files into an array under that field name.

2. Implement streaming file writes: instead of accumulating the entire body in memory, parse parts as the data arrives and pipe file content directly to `fs.createWriteStream`. This requires maintaining a state machine that tracks whether you are inside headers or body for the current part.

## Hints

1. The boundary in the body is always prefixed with `--`. So if the Content-Type says `boundary=abc`, the actual delimiter in the body is `--abc`.
2. `Buffer.indexOf()` accepts both strings and other Buffers — use it to search for boundary positions efficiently.
3. Content-Disposition values use semicolons to separate parameters. Split on `; ` and then look for `name=` and `filename=` prefixes. Strip surrounding quotes from values.
4. When computing the file extension, use `path.extname(originalFilename)` to safely extract it.
5. Always use `Buffer` operations (not string operations) when working with the body, because file content may contain bytes that are not valid UTF-8.
