# Track 02 / Lesson 04 — Input Validation & Sanitization

> Every byte that enters your process from the outside world is a potential weapon. The attacker does not need to break your encryption or steal your keys — they just need you to trust their input. This lesson teaches you to validate and sanitize without reaching for npm, because the defenses are all in core Node.js and careful programming.

## Learning Objectives

- Detect and prevent Regular Expression Denial of Service (ReDoS) by recognizing catastrophic backtracking patterns and rewriting them safely
- Defend against path traversal attacks using `path.resolve()` with root directory validation and symlink detection
- Block HTTP header injection (CRLF injection) by rejecting control characters in header values
- Prevent null byte attacks that bypass file extension checks in `node:fs` operations
- Identify and mitigate prototype pollution via `__proto__` and `constructor.prototype` in JSON payloads

---

## The Golden Rule of Input Validation

**Validate on the way in, sanitize on the way out.**

- **Validation** means rejecting input that does not conform to expected format, length, type, and range. Invalid input never reaches your business logic.
- **Sanitization** means transforming valid input so it is safe for its output context (HTML, SQL, shell, file path). The same input may need different sanitization depending on where it is used.

```js
'use strict';

const http = require('node:http');

// A validation pipeline for a user registration endpoint
function validateRegistration(body) {
  const errors = [];

  // Type checks first — reject non-object payloads
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return { valid: false, errors: ['Body must be a JSON object'] };
  }

  // Name: string, 1-100 chars, no control characters
  if (typeof body.name !== 'string') {
    errors.push('name must be a string');
  } else if (body.name.length < 1 || body.name.length > 100) {
    errors.push('name must be 1-100 characters');
  } else if (/[\x00-\x1f\x7f]/.test(body.name)) {
    errors.push('name must not contain control characters');
  }

  // Email: string, basic format check (NO complex regex)
  if (typeof body.email !== 'string') {
    errors.push('email must be a string');
  } else if (body.email.length > 254) {
    errors.push('email must be <= 254 characters');
  } else {
    const at = body.email.indexOf('@');
    if (at < 1 || at === body.email.length - 1) {
      errors.push('email must contain exactly one @ with text on both sides');
    } else if (body.email.indexOf('@', at + 1) !== -1) {
      errors.push('email must contain exactly one @');
    }
  }

  // Age: integer, 13-150
  if (typeof body.age !== 'number' || !Number.isInteger(body.age)) {
    errors.push('age must be an integer');
  } else if (body.age < 13 || body.age > 150) {
    errors.push('age must be between 13 and 150');
  }

  return { valid: errors.length === 0, errors, data: body };
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405);
    res.end();
    return;
  }

  const chunks = [];
  let size = 0;
  const MAX_BODY = 1024 * 10; // 10 KB

  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_BODY) {
      res.writeHead(413);
      res.end('Payload too large');
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on('end', () => {
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString());
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
      return;
    }

    const result = validateRegistration(body);
    if (!result.valid) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ errors: result.errors }));
      return;
    }

    res.writeHead(201, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ message: 'User created', name: result.data.name }));
  });
});

server.listen(3000);
```

---

## ReDoS: Regular Expression Denial of Service

### What Is Catastrophic Backtracking?

Regular expressions with nested quantifiers can exhibit exponential time complexity on certain inputs. The regex engine tries every possible combination of matches, and the number of combinations grows exponentially with input length.

```js
'use strict';

const { performance } = require('node:perf_hooks');

// DANGEROUS: This regex has catastrophic backtracking
// The pattern (a+)+ allows the engine to match 'a' in exponentially
// many ways because the inner + and outer + are both greedy.

const dangerousRegex = /^(a+)+$/;

// Benign input: matches quickly
const safe = 'aaaaaaaaaaaa';
let start = performance.now();
dangerousRegex.test(safe);
console.log(`Safe input (${safe.length} chars): ${(performance.now() - start).toFixed(2)} ms`);

// Malicious input: 'a' repeated + a non-matching character
// The engine backtracks through 2^N combinations
const lengths = [15, 20, 23, 25];

for (const len of lengths) {
  const evil = 'a'.repeat(len) + 'b';
  start = performance.now();
  dangerousRegex.test(evil);
  const elapsed = performance.now() - start;
  console.log(`Evil input (${len + 1} chars): ${elapsed.toFixed(2)} ms`);
  // 15 chars: ~10ms, 20: ~300ms, 25: ~10,000ms
  // Each additional character roughly doubles the time
}
```

### Identifying Dangerous Patterns

The following regex constructs are warning signs for ReDoS:

```
DANGEROUS PATTERNS:
  (a+)+        Nested quantifiers
  (a|a)+       Overlapping alternation with quantifier
  (a+b?)*      Quantifier on group with optional element
  (.*a){3}     Dot-star with specific match, quantified

SAFE ALTERNATIVES:
  a+           Single quantifier, no nesting
  [ab]+        Character class instead of alternation
  a+b*         Sequential quantifiers (not nested)
  (?:a{1,3})+  Bounded inner quantifier
```

### Rewriting Dangerous Regex Patterns

```js
'use strict';

// DANGEROUS: Email regex with catastrophic backtracking
// const emailRegex = /^([a-zA-Z0-9]+\.)*[a-zA-Z0-9]+@([a-zA-Z0-9]+\.)+[a-zA-Z]{2,}$/;
// The (X+\.)* pattern causes exponential backtracking on inputs like
// "aaaaaaaaaaaaaaaa.@" because each 'a' can belong to different groups.

// SAFE: Avoid nested quantifiers entirely
function isValidEmail(email) {
  if (typeof email !== 'string') return false;
  if (email.length === 0 || email.length > 254) return false;

  const atIndex = email.indexOf('@');
  if (atIndex < 1 || atIndex > 64) return false;
  if (email.indexOf('@', atIndex + 1) !== -1) return false;

  const local = email.substring(0, atIndex);
  const domain = email.substring(atIndex + 1);

  // Local part: letters, digits, dots, hyphens, underscores
  if (!/^[a-zA-Z0-9._+-]+$/.test(local)) return false;
  if (local.startsWith('.') || local.endsWith('.')) return false;
  if (local.includes('..')) return false;

  // Domain: letters, digits, dots, hyphens
  if (!/^[a-zA-Z0-9.-]+$/.test(domain)) return false;
  if (domain.startsWith('.') || domain.endsWith('.')) return false;
  if (domain.includes('..')) return false;

  // TLD must be at least 2 characters
  const tld = domain.substring(domain.lastIndexOf('.') + 1);
  if (tld.length < 2) return false;

  return true;
}

console.log(isValidEmail('user@example.com'));           // true
console.log(isValidEmail('user.name+tag@host.co.uk'));   // true
console.log(isValidEmail('a'.repeat(100) + '@b.com'));   // false (local > 64)
console.log(isValidEmail('user@'));                       // false
console.log(isValidEmail('@domain.com'));                 // false

// DANGEROUS: URL path matching with nested wildcards
// const pathRegex = /^(\/[a-z]+)*$/;
// Backtracking on: "////////////////////!"

// SAFE: Use string splitting instead
function matchPath(path, pattern) {
  const pathParts = path.split('/').filter(Boolean);
  const patternParts = pattern.split('/').filter(Boolean);

  if (pathParts.length !== patternParts.length) return null;

  const params = {};
  for (let i = 0; i < patternParts.length; i++) {
    if (patternParts[i].startsWith(':')) {
      params[patternParts[i].substring(1)] = pathParts[i];
    } else if (patternParts[i] !== pathParts[i]) {
      return null;
    }
  }
  return params;
}

console.log(matchPath('/users/42/posts', '/users/:id/posts'));
// { id: '42' }
```

### Setting a Regex Timeout

Node.js does not have built-in regex timeouts, but you can use worker threads to enforce one:

```js
'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

if (!isMainThread) {
  // Worker: execute the regex and report result
  const { pattern, flags, input } = workerData;
  const regex = new RegExp(pattern, flags);
  const result = regex.test(input);
  parentPort.postMessage({ result });
} else {
  // Main thread: run regex in a worker with a timeout
  function regexWithTimeout(pattern, flags, input, timeoutMs = 1000) {
    return new Promise((resolve, reject) => {
      const worker = new Worker(__filename, {
        workerData: { pattern, flags, input },
      });

      const timer = setTimeout(() => {
        worker.terminate();
        reject(new Error(`Regex timed out after ${timeoutMs}ms — possible ReDoS`));
      }, timeoutMs);

      worker.on('message', (msg) => {
        clearTimeout(timer);
        resolve(msg.result);
      });

      worker.on('error', (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  // Test with a safe input
  regexWithTimeout('(a+)+$', '', 'aaaa')
    .then(r => console.log('Safe input result:', r))
    .catch(e => console.error(e.message));

  // Test with a ReDoS input
  regexWithTimeout('(a+)+$', '', 'a'.repeat(30) + 'b', 500)
    .then(r => console.log('Evil input result:', r))
    .catch(e => console.error(e.message));
    // Regex timed out after 500ms — possible ReDoS
}
```

---

## Path Traversal Defense

Path traversal exploits happen when an attacker supplies a file path containing `../` sequences to escape the intended directory:

```js
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');

// VULNERABLE: Direct path concatenation
function serveFile_BAD(baseDir, requestPath) {
  // If requestPath is "../../etc/passwd", this reads /etc/passwd
  const filePath = baseDir + requestPath;
  return fs.readFileSync(filePath, 'utf8');
}

// SECURE: Resolve and validate
function serveFile_GOOD(baseDir, requestPath) {
  // Resolve to absolute path — this handles ../ and ./ segments
  const resolvedBase = path.resolve(baseDir);
  const resolvedPath = path.resolve(resolvedBase, requestPath);

  // Check that the resolved path starts with the base directory
  // The path.sep suffix prevents prefix matching attacks:
  // Without it, base="/app/data" would match "/app/data-secret/file"
  if (!resolvedPath.startsWith(resolvedBase + path.sep) &&
      resolvedPath !== resolvedBase) {
    throw new Error('Path traversal attempt blocked');
  }

  // Check for symlinks that might escape the directory
  try {
    const realPath = fs.realpathSync(resolvedPath);
    if (!realPath.startsWith(resolvedBase + path.sep) &&
        realPath !== resolvedBase) {
      throw new Error('Symlink escape attempt blocked');
    }
  } catch (err) {
    if (err.code === 'ENOENT') {
      throw new Error('File not found');
    }
    throw err;
  }

  return fs.readFileSync(resolvedPath, 'utf8');
}

// Demonstration
const BASE = '/tmp/public';

// These should be blocked:
const attacks = [
  '../../../etc/passwd',
  '..\\..\\..\\windows\\system32\\config\\sam',
  '....//....//etc/passwd',
  '%2e%2e%2f%2e%2e%2fetc%2fpasswd',   // URL-encoded (decode first!)
  'valid/../../../etc/passwd',
];

for (const attack of attacks) {
  try {
    // URL-decode first (attackers encode traversal sequences)
    const decoded = decodeURIComponent(attack);
    serveFile_GOOD(BASE, decoded);
    console.log(`MISSED: ${attack}`);
  } catch (err) {
    console.log(`BLOCKED: ${attack} → ${err.message}`);
  }
}
```

### Handling URL-Encoded Paths

Attackers often double-encode or use alternative encodings for `../`:

```js
'use strict';

const path = require('node:path');

// All known representations of path traversal
function containsTraversal(input) {
  // Decode URL encoding (handle double encoding)
  let decoded = input;
  let prev;
  do {
    prev = decoded;
    try {
      decoded = decodeURIComponent(decoded);
    } catch {
      break; // Invalid encoding — keep as-is
    }
  } while (decoded !== prev);

  // Normalize path separators
  const normalized = decoded.replace(/\\/g, '/');

  // Check for traversal patterns
  if (normalized.includes('../') || normalized.includes('..\\')) return true;
  if (normalized === '..' || normalized.endsWith('/..')) return true;

  // Resolve and check
  const resolved = path.resolve('/', normalized);
  if (resolved !== path.normalize('/' + normalized)) return true;

  return false;
}

console.log(containsTraversal('../etc/passwd'));           // true
console.log(containsTraversal('%2e%2e%2fetc%2fpasswd'));   // true
console.log(containsTraversal('..%252f..%252fetc'));       // true (double-encoded)
console.log(containsTraversal('images/photo.png'));        // false
console.log(containsTraversal('users/profile'));           // false
```

---

## CRLF Injection (HTTP Header Injection)

If user input is placed into HTTP headers without sanitization, an attacker can inject `\r\n` (CRLF) to add arbitrary headers or even an entire HTTP response body:

```js
'use strict';

const http = require('node:http');

// VULNERABLE: Setting a header from user input
function setCookie_BAD(res, name, value) {
  // If value is "hello\r\nSet-Cookie: admin=true", the attacker
  // injects a second Set-Cookie header
  res.setHeader('Set-Cookie', `${name}=${value}`);
}

// SECURE: Reject control characters
function setCookie_GOOD(res, name, value) {
  // Reject any value containing control characters
  if (/[\x00-\x1f\x7f]/.test(name) || /[\x00-\x1f\x7f]/.test(value)) {
    throw new Error('Header value contains illegal control characters');
  }

  // Additional: reject newlines explicitly (defense in depth)
  if (name.includes('\n') || name.includes('\r') ||
      value.includes('\n') || value.includes('\r')) {
    throw new Error('CRLF injection attempt blocked');
  }

  res.setHeader('Set-Cookie', `${name}=${value}; HttpOnly; Secure; SameSite=Strict`);
}

// Note: Node.js >= 19.6 automatically rejects header values
// containing certain control characters. But defense in depth means
// you should validate BEFORE calling setHeader.

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const lang = url.searchParams.get('lang') || 'en';

  try {
    setCookie_GOOD(res, 'language', lang);
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(`Language set to: ${lang}`);
  } catch (err) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end(err.message);
  }
});

server.listen(3000, () => {
  console.log('Server on http://localhost:3000');
  console.log('Try: ?lang=en');
  console.log('Try: ?lang=en%0d%0aSet-Cookie:%20admin=true');
});
```

### Sanitizing for Different Output Contexts

```js
'use strict';

// Sanitize for HTML output (prevent XSS)
function sanitizeHtml(input) {
  return String(input)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

// Sanitize for URL parameter (prevent injection in URLs)
function sanitizeUrlParam(input) {
  return encodeURIComponent(String(input));
}

// Sanitize for log output (prevent log injection / log forging)
function sanitizeLog(input) {
  return String(input)
    .replace(/[\r\n]/g, ' ')       // Remove newlines (prevent log line injection)
    .replace(/[\x00-\x1f]/g, '')   // Remove control characters
    .substring(0, 500);             // Truncate to prevent log flooding
}

// Demonstration
const malicious = '<script>alert("xss")</script>';
console.log('HTML:', sanitizeHtml(malicious));
// &lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;

console.log('URL:', sanitizeUrlParam(malicious));
// %3Cscript%3Ealert(%22xss%22)%3C%2Fscript%3E

const logInjection = 'user logged in\n[ADMIN] System shutdown initiated';
console.log('Log:', sanitizeLog(logInjection));
// user logged in [ADMIN] System shutdown initiated
```

---

## Null Byte Attacks

In C-based systems (including parts of Node.js's native layer), strings are terminated by a null byte (`\0`). JavaScript strings can contain null bytes, but file system calls may truncate at the null byte:

```js
'use strict';

const path = require('node:path');
const fs = require('node:fs');

// ATTACK: Bypassing file extension checks with null bytes
// In older Node.js versions, this could read any file:
// filename = "secret.txt\0.png"
// Extension check sees ".png" → allowed
// fs.readFile sees "secret.txt" → reads the wrong file

// Modern Node.js (>= v8.x) rejects null bytes in file paths,
// but you should still validate defensively.

function safeFileAccess(requestedFile, allowedExtensions) {
  // STEP 1: Reject null bytes
  if (requestedFile.includes('\0')) {
    throw new Error('Null byte detected in file path');
  }

  // STEP 2: Check extension AFTER removing null bytes (defense in depth)
  const ext = path.extname(requestedFile).toLowerCase();
  if (!allowedExtensions.includes(ext)) {
    throw new Error(`Extension ${ext} is not allowed`);
  }

  // STEP 3: Validate no path traversal
  const resolved = path.resolve('/uploads', requestedFile);
  if (!resolved.startsWith(path.resolve('/uploads') + path.sep)) {
    throw new Error('Path traversal blocked');
  }

  return resolved;
}

// Test cases
const ALLOWED = ['.png', '.jpg', '.gif'];

const testCases = [
  'photo.png',                    // Valid
  'photo.png\0.exe',              // Null byte attack
  'image.jpg',                    // Valid
  '../../../etc/passwd\0.png',    // Traversal + null byte
  'script.js',                    // Wrong extension
];

for (const test of testCases) {
  try {
    const result = safeFileAccess(test, ALLOWED);
    console.log(`ALLOWED: ${test} → ${result}`);
  } catch (err) {
    console.log(`BLOCKED: ${test} → ${err.message}`);
  }
}
```

---

## Prototype Pollution

Prototype pollution is a JavaScript-specific attack where an attacker modifies `Object.prototype` by injecting `__proto__` or `constructor` keys into a JSON payload. Once `Object.prototype` is polluted, every object in the process inherits the polluted properties.

```js
'use strict';

// DEMONSTRATION: How prototype pollution works

// Simulating unsafe deep merge (common in config libraries)
function unsafeDeepMerge(target, source) {
  for (const key of Object.keys(source)) {
    if (typeof source[key] === 'object' && source[key] !== null &&
        typeof target[key] === 'object' && target[key] !== null) {
      unsafeDeepMerge(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

// ATTACK: Attacker sends this JSON payload
const maliciousPayload = JSON.parse(
  '{"__proto__": {"isAdmin": true, "role": "superuser"}}'
);

const config = { theme: 'dark' };

// This pollutes Object.prototype!
// unsafeDeepMerge(config, maliciousPayload);

// Now EVERY object has isAdmin === true
// const user = {};
// console.log(user.isAdmin); // true — POLLUTED
// console.log(user.role);    // "superuser" — POLLUTED

console.log('Prototype pollution is blocked — see safe version below.');
```

### Safe Deep Merge

```js
'use strict';

// SAFE: Deep merge that blocks prototype pollution
function safeDeepMerge(target, source) {
  // Reject dangerous keys at every level
  const BLOCKED_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

  for (const key of Object.keys(source)) {
    // Block dangerous keys
    if (BLOCKED_KEYS.has(key)) {
      continue; // Silently skip — or throw if you want to alert
    }

    // Only merge own properties
    if (!Object.prototype.hasOwnProperty.call(source, key)) {
      continue;
    }

    const sourceVal = source[key];
    const targetVal = target[key];

    if (typeof sourceVal === 'object' && sourceVal !== null &&
        !Array.isArray(sourceVal) &&
        typeof targetVal === 'object' && targetVal !== null &&
        !Array.isArray(targetVal)) {
      safeDeepMerge(targetVal, sourceVal);
    } else {
      target[key] = sourceVal;
    }
  }

  return target;
}

// Test: Pollution attempt is blocked
const config = { db: { host: 'localhost', port: 5432 } };
const userInput = JSON.parse(
  '{"db": {"host": "newhost"}, "__proto__": {"isAdmin": true}}'
);

safeDeepMerge(config, userInput);

console.log('Config:', config);
// { db: { host: 'newhost', port: 5432 } }

const testObj = {};
console.log('testObj.isAdmin:', testObj.isAdmin);
// undefined — prototype is NOT polluted
```

### Object.create(null) for Config Objects

```js
'use strict';

// Use Object.create(null) for objects that receive external data.
// These objects have NO prototype chain — no __proto__, no constructor.

function createSafeStore() {
  const store = Object.create(null);

  return {
    set(key, value) {
      // Even if key is "__proto__" or "constructor",
      // it is just a regular property on a null-prototype object
      if (typeof key !== 'string' || key.length === 0 || key.length > 256) {
        throw new Error('Invalid key');
      }
      store[key] = value;
    },
    get(key) {
      return store[key];
    },
    has(key) {
      return key in store;
    },
    keys() {
      return Object.keys(store);
    },
  };
}

const store = createSafeStore();
store.set('name', 'Alice');
store.set('__proto__', 'this is just data, not pollution');
store.set('constructor', 'also just data');

console.log(store.get('name'));         // Alice
console.log(store.get('__proto__'));    // this is just data, not pollution
console.log(store.get('constructor')); // also just data

// Verify prototype is clean
const testObj = {};
console.log(testObj.name);       // undefined — no pollution
console.log(testObj.constructor); // [Function: Object] — pristine
```

---

## JSON Schema Validation Without npm

You can build a basic JSON schema validator with pure JavaScript:

```js
'use strict';

// Minimal JSON schema validator — no npm required
function validate(data, schema) {
  const errors = [];

  function check(value, sch, pathStr) {
    // Type check
    if (sch.type) {
      const actual = Array.isArray(value) ? 'array' :
                     value === null ? 'null' :
                     typeof value;
      if (actual !== sch.type) {
        errors.push(`${pathStr}: expected ${sch.type}, got ${actual}`);
        return;
      }
    }

    // String constraints
    if (sch.type === 'string' && typeof value === 'string') {
      if (sch.minLength !== undefined && value.length < sch.minLength) {
        errors.push(`${pathStr}: length ${value.length} < minLength ${sch.minLength}`);
      }
      if (sch.maxLength !== undefined && value.length > sch.maxLength) {
        errors.push(`${pathStr}: length ${value.length} > maxLength ${sch.maxLength}`);
      }
      if (sch.pattern && !new RegExp(sch.pattern).test(value)) {
        errors.push(`${pathStr}: does not match pattern ${sch.pattern}`);
      }
    }

    // Number constraints
    if (sch.type === 'number' && typeof value === 'number') {
      if (sch.minimum !== undefined && value < sch.minimum) {
        errors.push(`${pathStr}: ${value} < minimum ${sch.minimum}`);
      }
      if (sch.maximum !== undefined && value > sch.maximum) {
        errors.push(`${pathStr}: ${value} > maximum ${sch.maximum}`);
      }
      if (sch.integer && !Number.isInteger(value)) {
        errors.push(`${pathStr}: expected integer`);
      }
    }

    // Enum
    if (sch.enum && !sch.enum.includes(value)) {
      errors.push(`${pathStr}: must be one of [${sch.enum.join(', ')}]`);
    }

    // Object properties
    if (sch.type === 'object' && typeof value === 'object' && value !== null) {
      // Check required fields
      if (sch.required) {
        for (const req of sch.required) {
          if (!(req in value)) {
            errors.push(`${pathStr}: missing required field '${req}'`);
          }
        }
      }

      // Validate each property
      if (sch.properties) {
        for (const [propName, propSchema] of Object.entries(sch.properties)) {
          if (propName in value) {
            check(value[propName], propSchema, `${pathStr}.${propName}`);
          }
        }
      }

      // Reject additional properties if specified
      if (sch.additionalProperties === false && sch.properties) {
        const allowed = new Set(Object.keys(sch.properties));
        for (const key of Object.keys(value)) {
          if (!allowed.has(key)) {
            errors.push(`${pathStr}: unexpected property '${key}'`);
          }
        }
      }
    }

    // Array items
    if (sch.type === 'array' && Array.isArray(value)) {
      if (sch.minItems !== undefined && value.length < sch.minItems) {
        errors.push(`${pathStr}: array length ${value.length} < minItems ${sch.minItems}`);
      }
      if (sch.maxItems !== undefined && value.length > sch.maxItems) {
        errors.push(`${pathStr}: array length ${value.length} > maxItems ${sch.maxItems}`);
      }
      if (sch.items) {
        for (let i = 0; i < value.length; i++) {
          check(value[i], sch.items, `${pathStr}[${i}]`);
        }
      }
    }
  }

  check(data, schema, '$');
  return { valid: errors.length === 0, errors };
}

// Define a schema for a user creation endpoint
const userSchema = {
  type: 'object',
  required: ['name', 'email', 'age'],
  additionalProperties: false,
  properties: {
    name: { type: 'string', minLength: 1, maxLength: 100 },
    email: { type: 'string', maxLength: 254 },
    age: { type: 'number', minimum: 13, maximum: 150, integer: true },
    role: { type: 'string', enum: ['user', 'editor'] },
  },
};

// Valid input
console.log(validate({ name: 'Alice', email: 'a@b.com', age: 30 }, userSchema));
// { valid: true, errors: [] }

// Invalid input
console.log(validate({ name: '', email: 'a@b.com', age: 10 }, userSchema));
// { valid: false, errors: ['$.name: length 0 < minLength 1', '$.age: 10 < minimum 13'] }

// Prototype pollution attempt blocked by additionalProperties: false
console.log(validate(
  { name: 'Alice', email: 'a@b.com', age: 30, __proto__: { isAdmin: true } },
  userSchema
));
// { valid: false, errors: ["$: unexpected property '__proto__'"] }
```

---

## Key Takeaways

- ReDoS is caused by regex patterns with nested quantifiers (e.g., `(a+)+`) that exhibit exponential backtracking — replace complex regex with simple string operations, or isolate regex execution in a worker thread with a timeout
- Path traversal defense requires `path.resolve()` followed by a prefix check against the root directory, plus `fs.realpathSync()` to detect symlink escapes — never concatenate user input directly into file paths
- CRLF injection occurs when user input containing `\r\n` is placed into HTTP headers — reject all control characters (`\x00-\x1f`, `\x7f`) in any value destined for an HTTP header
- Null byte attacks (`\0`) can bypass file extension checks in native code — always check for and reject null bytes in file paths before any `fs` operation
- Prototype pollution via `__proto__` or `constructor` keys in JSON payloads can compromise every object in the process — use `Object.create(null)` for data stores, block dangerous keys in deep merge operations, and whitelist expected properties

## Next

In [Lesson 05 — Secure Server Hardening](lesson-05-server-hardening.md), we take everything from threat modeling, TLS, timing safety, and input validation and combine it into a hardened HTTP server. You will implement rate limiting, request size limits, slowloris protection, and HTTP request smuggling defenses — all with `node:http` and zero npm packages.
