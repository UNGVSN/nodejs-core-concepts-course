# Track 03 / Lesson 01 — N-API & C Addons

> Sometimes JavaScript is not fast enough. When you need to wrap an existing C library, crunch numbers at native speed, or interface with hardware, Node.js gives you a stable, ABI-compatible gateway into the C world: N-API. This lesson teaches you when to cross that boundary and how to do it safely.

## Learning Objectives

- Explain why native addons exist and when they are justified over pure JavaScript
- Describe the N-API stability guarantee and how it differs from the legacy V8 C++ addon API
- Configure a `binding.gyp` file and build a native addon with `node-gyp`
- Pass data between C and JavaScript using `napi_value`, type conversion functions, and error handling
- Evaluate alternatives to native addons — WebAssembly, child processes with compiled binaries, and pure JavaScript optimization

---

## Why Native Addons Exist

Node.js is fast for I/O-bound work. V8's JIT compiler makes JavaScript competitive for many CPU tasks. But there are cases where native code is the only viable option:

1. **Wrapping existing C/C++ libraries.** You have a battle-tested image processing library, a cryptographic implementation, or a hardware driver written in C. Rewriting it in JavaScript is neither practical nor desirable.

2. **Performance-critical computation.** Some algorithms — matrix multiplication, audio/video encoding, physics simulation — need every cycle. Native code compiled ahead of time will outperform JIT-compiled JavaScript by 2-10x for tight numerical loops.

3. **System-level access.** Certain OS features (specialized ioctl calls, custom memory allocators, hardware interfaces) have no JavaScript equivalent and require direct C bindings.

4. **Deterministic memory management.** JavaScript's garbage collector introduces pauses. In real-time systems (audio processing, game servers), you may need manual memory control.

The trade-off is always the same: native code is harder to write, harder to debug, harder to deploy (platform-specific binaries), and harder to maintain. You reach for it only when you have measured a bottleneck and confirmed that pure JavaScript cannot solve it.

---

## The Evolution of Node.js Addon APIs

### The Bad Old Days: V8 C++ API

Before N-API, native addons were written directly against V8's C++ API. The problem was brutal: V8 changed its internal API between minor versions. An addon compiled against Node.js 8 would fail on Node.js 10. Every Node.js upgrade broke native addons.

```javascript
'use strict';

// This is what addon consumers see — a simple require()
// But behind the scenes, the .node binary was compiled against
// a specific V8 version and would break on upgrades
const addon = require('./build/Release/my_addon.node');
console.log(addon.hello()); // "Hello from C++"
```

### N-API: The Stability Guarantee

N-API (Node-API) was introduced in Node.js 8.0 and stabilized in Node.js 10. It provides an ABI-stable C interface that is independent of V8's internal API. An addon compiled with N-API on Node.js 14 will work on Node.js 16, 18, 20, and 22 without recompilation.

Key guarantees:

- **ABI stability.** The binary interface does not change across Node.js major versions.
- **Engine independence.** N-API abstracts over V8, so in theory it could work with other JavaScript engines.
- **C interface.** The core API is pure C, not C++. This means addons can be written in any language that can produce a C-compatible shared library.
- **Versioning.** N-API versions are additive. Version 9 includes everything from versions 1-8 plus new functions.

```c
/* addon.c — A minimal N-API addon */
#include <node_api.h>

/* The function JavaScript will call */
static napi_value Hello(napi_env env, napi_callback_info info) {
  napi_value result;
  napi_create_string_utf8(env, "Hello from C via N-API!", NAPI_AUTO_LENGTH, &result);
  return result;
}

/* Module initialization — called when require() loads the .node file */
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc = {
    "hello",           /* property name */
    NULL,              /* utf8name (alternative) */
    Hello,             /* method */
    NULL, NULL, NULL,  /* getter, setter, value */
    napi_default,      /* attributes */
    NULL               /* data */
  };
  napi_define_properties(env, exports, 1, &desc);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
```

---

## The Build System: node-gyp and binding.gyp

`node-gyp` is the build tool for native addons. It uses Google's GYP (Generate Your Projects) format to produce platform-specific build files (Makefiles on Unix, Visual Studio projects on Windows).

### Prerequisites

Before building native addons, you need a C/C++ toolchain:

- **macOS:** Install Xcode Command Line Tools (`xcode-select --install`)
- **Linux:** Install `build-essential` (GCC, Make)
- **Windows:** Install Visual Studio Build Tools with the "Desktop development with C++" workload

### binding.gyp Configuration

```json
{
  "targets": [
    {
      "target_name": "my_addon",
      "sources": ["src/addon.c"],
      "include_dirs": [],
      "cflags": ["-Wall", "-Werror"],
      "conditions": [
        ["OS=='mac'", {
          "xcode_settings": {
            "OTHER_CFLAGS": ["-Wall"]
          }
        }]
      ]
    }
  ]
}
```

### Build Commands

```javascript
'use strict';

// The build workflow (run from shell, not from JavaScript):
//
//   node-gyp configure   # Generates platform-specific build files
//   node-gyp build       # Compiles the addon to build/Release/my_addon.node
//   node-gyp rebuild     # Clean + configure + build in one step
//
// After building, load the addon in JavaScript:

const path = require('node:path');
const addon = require(path.join(__dirname, 'build', 'Release', 'my_addon.node'));

console.log(addon.hello()); // "Hello from C via N-API!"
```

### The bindings Package Pattern

Many addons use a `bindings` npm package to locate the `.node` file. Since this course avoids npm packages, here is what it does internally:

```javascript
'use strict';

const path = require('node:path');
const fs = require('node:fs');

/**
 * Locate a compiled .node addon by searching common build output paths.
 * This replicates what the `bindings` npm package does.
 */
function loadAddon(addonName) {
  const candidates = [
    path.join(__dirname, 'build', 'Release', `${addonName}.node`),
    path.join(__dirname, 'build', 'Debug', `${addonName}.node`),
    path.join(__dirname, 'out', 'Release', `${addonName}.node`),
    path.join(__dirname, 'out', 'Debug', `${addonName}.node`),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return require(candidate);
    }
  }

  throw new Error(
    `Cannot find addon "${addonName}". Searched:\n` +
    candidates.map((c) => `  - ${c}`).join('\n')
  );
}

const addon = loadAddon('my_addon');
console.log(addon.hello());
```

---

## Passing Data Between C and JavaScript

Every value that crosses the C/JavaScript boundary is a `napi_value` — an opaque handle. You use type-specific functions to create and extract values.

### Numeric Types

```c
/* add.c — Add two integers */
#include <node_api.h>

static napi_value Add(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  /* Extract int32 values from JavaScript arguments */
  int32_t a, b;
  napi_get_value_int32(env, argv[0], &a);
  napi_get_value_int32(env, argv[1], &b);

  /* Create the result */
  napi_value result;
  napi_create_int32(env, a + b, &result);
  return result;
}

/* For doubles: */
/* napi_get_value_double(env, argv[0], &d);  */
/* napi_create_double(env, d * 2.0, &result); */
```

```javascript
'use strict';

// After building the addon:
const addon = require('./build/Release/add_addon.node');

console.log(addon.add(17, 25));   // 42
console.log(addon.add(-10, 10));  // 0
```

### Strings

```c
/* greet.c — Receive a string, return a greeting */
#include <node_api.h>
#include <string.h>
#include <stdio.h>

static napi_value Greet(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  /* Get the string length first */
  size_t str_len;
  napi_get_value_string_utf8(env, argv[0], NULL, 0, &str_len);

  /* Allocate buffer and extract the string */
  char name[256];
  napi_get_value_string_utf8(env, argv[0], name, sizeof(name), &str_len);

  /* Build the greeting */
  char greeting[512];
  snprintf(greeting, sizeof(greeting), "Hello, %s! Welcome to N-API.", name);

  napi_value result;
  napi_create_string_utf8(env, greeting, NAPI_AUTO_LENGTH, &result);
  return result;
}
```

### Buffers and ArrayBuffers

This is where N-API shines for systems programming — direct access to binary data without copying.

```c
/* process_buffer.c — Read and modify a Buffer in-place */
#include <node_api.h>
#include <stdint.h>

static napi_value InvertBuffer(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  /* Get a pointer to the Buffer's data — zero-copy! */
  uint8_t *data;
  size_t length;
  napi_get_buffer_info(env, argv[0], (void **)&data, &length);

  /* Invert every byte in place */
  for (size_t i = 0; i < length; i++) {
    data[i] = ~data[i];
  }

  /* Return the same buffer (modified in place) */
  return argv[0];
}
```

```javascript
'use strict';

const addon = require('./build/Release/buffer_addon.node');

const buf = Buffer.from([0x00, 0xFF, 0xAA, 0x55]);
console.log('Before:', buf); // <Buffer 00 ff aa 55>

addon.invertBuffer(buf);
console.log('After: ', buf); // <Buffer ff 00 55 aa>

// The C code modified the buffer IN PLACE — no copy was made.
// This is the key performance advantage for binary data processing.
```

---

## Error Handling in N-API

N-API functions return `napi_status` codes. You must check them. Unhandled errors in native code crash the entire process — there is no try/catch safety net.

```c
/* safe_divide.c — Division with proper error handling */
#include <node_api.h>

#define NAPI_CALL(env, call)                                    \
  do {                                                          \
    napi_status status = (call);                                \
    if (status != napi_ok) {                                    \
      const napi_extended_error_info *error_info;               \
      napi_get_last_error_info((env), &error_info);             \
      napi_throw_error((env), NULL, error_info->error_message); \
      return NULL;                                              \
    }                                                           \
  } while (0)

static napi_value Divide(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, NULL, NULL));

  double a, b;
  NAPI_CALL(env, napi_get_value_double(env, argv[0], &a));
  NAPI_CALL(env, napi_get_value_double(env, argv[1], &b));

  if (b == 0.0) {
    napi_throw_error(env, "ERR_DIVIDE_BY_ZERO", "Division by zero");
    return NULL;
  }

  napi_value result;
  NAPI_CALL(env, napi_create_double(env, a / b, &result));
  return result;
}
```

```javascript
'use strict';

const addon = require('./build/Release/math_addon.node');

try {
  console.log(addon.divide(10, 3));  // 3.3333...
  console.log(addon.divide(10, 0));  // throws!
} catch (err) {
  console.error(`Caught: ${err.message}`);
  console.error(`Code:   ${err.code}`);
  // Caught: Division by zero
  // Code:   ERR_DIVIDE_BY_ZERO
}
```

---

## node-addon-api: The C++ Wrapper

Writing raw N-API in C is verbose. The `node-addon-api` header-only C++ library wraps every N-API call in ergonomic C++ classes. It ships with Node.js's header distribution, so no npm install is required at runtime — only at build time.

```cpp
/* addon.cpp — The same Add function in C++ with node-addon-api */
#include <napi.h>

Napi::Value Add(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();

  if (info.Length() < 2 || !info[0].IsNumber() || !info[1].IsNumber()) {
    Napi::TypeError::New(env, "Expected two numbers").ThrowAsJavaScriptException();
    return env.Null();
  }

  double a = info[0].As<Napi::Number>().DoubleValue();
  double b = info[1].As<Napi::Number>().DoubleValue();

  return Napi::Number::New(env, a + b);
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("add", Napi::Function::New(env, Add));
  return exports;
}

NODE_API_MODULE(addon, Init)
```

Compare the C version: 15+ lines with manual error checking vs 12 lines with RAII-style error handling. For any addon beyond a trivial example, the C++ wrapper is strongly recommended.

---

## When Native Code Is Worth the Complexity

### Decision Framework

Ask these questions before writing a native addon:

```javascript
'use strict';

/**
 * Decision tree for "Should I write a native addon?"
 *
 * 1. Is the bottleneck actually CPU-bound?
 *    - If I/O-bound: NO. Use streams, worker threads, or clustering.
 *
 * 2. Have I profiled the JavaScript implementation?
 *    - If not profiled: NO. Measure first. V8 is surprisingly fast.
 *
 * 3. Does an existing C/C++ library solve the problem?
 *    - If yes: MAYBE. Wrapping an existing library is the strongest
 *      justification for a native addon.
 *
 * 4. Can WebAssembly solve it instead?
 *    - WASM is portable (no platform-specific builds), sandboxed,
 *      and increasingly fast. For pure computation without OS access,
 *      WASM is often the better choice.
 *
 * 5. Can a child process with a compiled binary solve it?
 *    - Spawning a Go/Rust/C binary and communicating via stdin/stdout
 *      avoids the build complexity entirely. The overhead is one
 *      process spawn per invocation.
 *
 * 6. Is the team able to maintain C/C++ code?
 *    - Native addons require C expertise, platform-specific debugging,
 *      and CI pipelines that compile for every target OS.
 */

// Benchmark: Pure JavaScript vs hypothetical native addon
const { performance } = require('node:perf_hooks');

function fibonacciJS(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) {
    const temp = a + b;
    a = b;
    b = temp;
  }
  return b;
}

const iterations = 1_000_000;
const start = performance.now();
for (let i = 0; i < iterations; i++) {
  fibonacciJS(40);
}
const elapsed = performance.now() - start;

console.log(`JS Fibonacci(40) x ${iterations}: ${elapsed.toFixed(2)} ms`);
console.log(`Per call: ${(elapsed / iterations * 1000).toFixed(2)} us`);
// V8 will JIT-optimize this tight loop to near-native speed.
// A C addon would show minimal improvement for this kind of code.
```

### Alternatives Comparison

| Approach | Build Complexity | Portability | Performance | Use Case |
|----------|-----------------|-------------|-------------|----------|
| N-API C addon | High | Low (per-platform) | Highest | Wrapping C libs, real-time processing |
| WebAssembly | Medium | High (portable .wasm) | High | Pure computation, sandboxed |
| Child process | Low | Medium | Medium | One-shot transformations |
| Pure JavaScript | None | Highest | Good (V8 JIT) | Most workloads |

---

## Async Native Addons

Long-running C operations must not block the event loop. N-API provides `napi_create_async_work` to run C code on libuv's thread pool.

```c
/* async_hash.c — Compute a hash asynchronously on the thread pool */
#include <node_api.h>
#include <string.h>
#include <stdlib.h>

typedef struct {
  napi_async_work work;
  napi_deferred deferred;
  char *input;
  uint32_t result;
} hash_work_t;

/* Simple DJB2 hash — runs on the thread pool, NOT the event loop */
static void ExecuteHash(napi_env env, void *data) {
  hash_work_t *w = (hash_work_t *)data;
  uint32_t hash = 5381;
  const char *str = w->input;
  int c;
  while ((c = *str++)) {
    hash = ((hash << 5) + hash) + c;
  }
  w->result = hash;
}

/* Runs on the event loop after ExecuteHash completes */
static void CompleteHash(napi_env env, napi_status status, void *data) {
  hash_work_t *w = (hash_work_t *)data;

  napi_value result;
  napi_create_uint32(env, w->result, &result);
  napi_resolve_deferred(env, w->deferred, result);
  napi_delete_async_work(env, w->work);
  free(w->input);
  free(w);
}

static napi_value AsyncHash(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

  /* Extract the input string */
  size_t str_len;
  napi_get_value_string_utf8(env, argv[0], NULL, 0, &str_len);
  char *input = malloc(str_len + 1);
  napi_get_value_string_utf8(env, argv[0], input, str_len + 1, &str_len);

  /* Create a Promise to return to JavaScript */
  napi_value promise;
  napi_deferred deferred;
  napi_create_promise(env, &deferred, &promise);

  /* Set up async work */
  hash_work_t *w = malloc(sizeof(hash_work_t));
  w->input = input;
  w->deferred = deferred;

  napi_value work_name;
  napi_create_string_utf8(env, "async_hash", NAPI_AUTO_LENGTH, &work_name);
  napi_create_async_work(env, NULL, work_name, ExecuteHash, CompleteHash, w, &w->work);
  napi_queue_async_work(env, w->work);

  return promise;
}
```

```javascript
'use strict';

// The addon exposes a Promise-based API — completely non-blocking
const addon = require('./build/Release/async_hash.node');

async function main() {
  const hash1 = await addon.asyncHash('hello world');
  const hash2 = await addon.asyncHash('Node.js N-API');

  console.log(`Hash of "hello world":    ${hash1}`);
  console.log(`Hash of "Node.js N-API":  ${hash2}`);

  // The event loop was never blocked — both hashes were computed
  // on libuv's thread pool, and the Promises resolved when done.
}

main().catch(console.error);
```

---

## Debugging Native Addons

When a native addon crashes, you get a segfault, not a stack trace. Here are the tools:

```javascript
'use strict';

// 1. Enable core dumps (run before starting Node.js):
//    ulimit -c unlimited
//    node --abort-on-uncaught-exception app.js
//
// 2. Use lldb or gdb to inspect the crash:
//    lldb -- node app.js
//    (lldb) run
//    (lldb) bt          # backtrace after crash
//
// 3. Use AddressSanitizer during development:
//    In binding.gyp, add to cflags:
//    "-fsanitize=address", "-fno-omit-frame-pointer"
//    And to ldflags:
//    "-fsanitize=address"
//
// 4. N-API's napi_get_last_error_info() gives you error details
//    without crashing — always check return codes.

const { execSync } = require('node:child_process');

// Verify that the build toolchain is available
try {
  const version = execSync('node-gyp --version', { encoding: 'utf8' }).trim();
  console.log(`node-gyp version: ${version}`);
} catch {
  console.log('node-gyp not found — install it globally: npm install -g node-gyp');
}

// Verify C compiler
try {
  const cc = execSync('cc --version 2>&1 | head -1', { encoding: 'utf8' }).trim();
  console.log(`C compiler: ${cc}`);
} catch {
  console.log('No C compiler found — install Xcode CLI tools or build-essential');
}
```

---

## Key Takeaways

- N-API provides an ABI-stable C interface for writing native addons that work across Node.js versions without recompilation — solving the version breakage problem of the legacy V8 C++ API
- Every value crossing the C/JavaScript boundary is an opaque `napi_value` handle — you extract and create values using type-specific functions like `napi_get_value_int32` and `napi_create_string_utf8`
- Long-running native operations must use `napi_create_async_work` to run on libuv's thread pool, returning a Promise to JavaScript — blocking the event loop from C is just as fatal as blocking it from JavaScript
- The decision to write a native addon should follow a strict hierarchy: profile first, consider WASM and child processes, and choose N-API only when wrapping an existing C library or when measured performance demands it
- Debugging native addons requires C-level tools (lldb, gdb, AddressSanitizer) because a crash in native code is a segfault, not a JavaScript exception

## Next

In the next lesson, we move from calling *into* native code to calling *between* Node.js processes — using Unix domain sockets and named pipes for the fastest possible inter-process communication on a single host.
