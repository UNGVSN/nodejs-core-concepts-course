# Module 06 / Lesson 05 — DNS Resolution

> Before a TCP connection can begin its three-way handshake, before a UDP datagram can be sent, the client needs an IP address. DNS is the system that translates human-readable domain names into machine-routable addresses. This lesson takes you through the hierarchy, the record types, and the two very different ways Node.js resolves names.

---

## Learning Objectives

- Describe the DNS hierarchy from root servers through TLD servers to authoritative nameservers
- Identify and explain the most common DNS record types: A, AAAA, CNAME, MX, TXT, NS, SOA, SRV
- Contrast `dns.lookup()` and `dns.resolve()` in Node.js — thread pool vs async network query
- Explain DNS caching at each level (browser, OS, resolver, TTL) and its implications for Node.js servers
- Build practical DNS utilities using the `node:dns` and `node:dns/promises` modules

---

## The DNS Hierarchy

DNS is a distributed, hierarchical database. When you type `api.example.com` into a browser, the resolution follows a chain of delegation.

### The Root

There are 13 root server addresses (labeled A through M), operated by organizations like ICANN, Verisign, and NASA. They do not know where `api.example.com` is, but they know where to find the `.com` TLD servers.

### Top-Level Domain (TLD) Servers

TLD servers handle the last part of a domain name: `.com`, `.org`, `.net`, `.io`, country codes like `.uk` and `.de`. The `.com` TLD servers do not know where `api.example.com` is, but they know which nameservers are authoritative for `example.com`.

### Authoritative Nameservers

The authoritative nameserver for `example.com` has the actual DNS records. It can answer: "`api.example.com` is at `93.184.216.34`."

### The Recursive Resolver

Your ISP (or a service like `8.8.8.8` or `1.1.1.1`) operates a **recursive resolver** that performs the full lookup chain on your behalf. When your Node.js server needs to resolve a domain, it typically asks the recursive resolver configured in `/etc/resolv.conf`.

### The Resolution Flow

```
Your Node.js app
    ↓ "What is api.example.com?"
Recursive Resolver (e.g., 8.8.8.8)
    ↓ "Where is .com?"
Root Server
    ↓ "Ask the .com TLD at 192.5.6.30"
.com TLD Server
    ↓ "example.com is handled by ns1.example.com at 198.51.100.1"
Authoritative Nameserver for example.com
    ↓ "api.example.com is 93.184.216.34"
Recursive Resolver
    ↓ caches the result, returns it
Your Node.js app
    ↓ connects to 93.184.216.34
```

In practice, the recursive resolver caches aggressively, so most lookups skip several steps.

---

## DNS Record Types

DNS is not just about mapping names to IP addresses. Different record types serve different purposes.

### A Record (Address)

Maps a domain name to an IPv4 address.

```
api.example.com.    300    IN    A    93.184.216.34
```

### AAAA Record (IPv6 Address)

Maps a domain name to an IPv6 address. The name "AAAA" is because IPv6 addresses are four times longer than IPv4 addresses (128 bits vs 32 bits).

```
api.example.com.    300    IN    AAAA    2606:2800:220:1:248:1893:25c8:1946
```

### CNAME Record (Canonical Name)

An alias that points to another domain name. Commonly used for `www` subdomains and CDN configurations.

```
www.example.com.    3600    IN    CNAME    example.com.
cdn.example.com.    300     IN    CNAME    d1234.cloudfront.net.
```

A CNAME lookup requires an additional resolution step — the resolver must follow the alias to find the actual A/AAAA record.

### MX Record (Mail Exchange)

Specifies which mail servers accept email for a domain. Includes a priority number (lower is higher priority).

```
example.com.    3600    IN    MX    10    mail1.example.com.
example.com.    3600    IN    MX    20    mail2.example.com.
```

### TXT Record (Text)

Arbitrary text data associated with a domain. Used for SPF (email authentication), DKIM, domain verification, and other purposes.

```
example.com.    3600    IN    TXT    "v=spf1 include:_spf.google.com ~all"
```

### NS Record (Nameserver)

Identifies the authoritative nameservers for a domain.

```
example.com.    86400    IN    NS    ns1.example.com.
example.com.    86400    IN    NS    ns2.example.com.
```

### SOA Record (Start of Authority)

Contains administrative information about the zone: primary nameserver, contact email, serial number, refresh/retry/expire timers.

### SRV Record (Service)

Specifies the host and port for a specific service. Used by protocols like SIP, XMPP, and service discovery systems.

```
_http._tcp.example.com.    300    IN    SRV    10 60 8080 api.example.com.
```

Format: `priority weight port target`

---

## DNS in Node.js: Two Different APIs

Node.js provides two fundamentally different approaches to DNS resolution. Understanding the difference is critical for production performance.

### `dns.lookup()` — The OS Resolver

`dns.lookup()` uses the operating system's name resolution mechanism. On Linux and macOS, this means it calls `getaddrinfo()`, which:

1. Checks `/etc/hosts`
2. Checks the OS DNS cache (if one exists)
3. Queries the nameserver configured in `/etc/resolv.conf`

**The critical detail:** `getaddrinfo()` is a **blocking** system call. Node.js runs it on the **libuv thread pool** (default size: 4 threads). This means `dns.lookup()` can exhaust the thread pool under high load.

```javascript
'use strict';

const dns = require('node:dns');

// dns.lookup uses the OS resolver (runs on the libuv thread pool)
dns.lookup('example.com', (err, address, family) => {
  if (err) {
    console.error('Lookup error:', err.message);
    return;
  }
  console.log(`Address: ${address}`);   // e.g., 93.184.216.34
  console.log(`Family: IPv${family}`);  // e.g., IPv4
});
```

With options:

```javascript
'use strict';

const dns = require('node:dns');

// Request all addresses (IPv4 and IPv6)
dns.lookup('example.com', { all: true }, (err, addresses) => {
  if (err) {
    console.error(err.message);
    return;
  }

  for (const addr of addresses) {
    console.log(`${addr.address} (IPv${addr.family})`);
  }
});

// Request only IPv6
dns.lookup('example.com', { family: 6 }, (err, address) => {
  if (err) {
    console.error('No IPv6 address:', err.message);
    return;
  }
  console.log(`IPv6: ${address}`);
});
```

### `dns.resolve()` — The Async DNS Client

`dns.resolve()` performs DNS queries directly over the network using c-ares, an asynchronous DNS client library. It does **not** use the thread pool. It does **not** check `/etc/hosts`.

```javascript
'use strict';

const dns = require('node:dns');

// dns.resolve uses c-ares (async network query, no thread pool)
dns.resolve('example.com', 'A', (err, addresses) => {
  if (err) {
    console.error('Resolve error:', err.code, err.message);
    return;
  }
  console.log('A records:', addresses);  // ['93.184.216.34']
});
```

### The Promises API

The `node:dns/promises` module provides a cleaner async interface:

```javascript
'use strict';

const dns = require('node:dns/promises');

async function resolveAll(hostname) {
  try {
    const [a, aaaa, mx, txt, ns] = await Promise.allSettled([
      dns.resolve(hostname, 'A'),
      dns.resolve(hostname, 'AAAA'),
      dns.resolve(hostname, 'MX'),
      dns.resolve(hostname, 'TXT'),
      dns.resolve(hostname, 'NS'),
    ]);

    console.log(`DNS records for ${hostname}:`);
    console.log('  A:   ', a.status === 'fulfilled' ? a.value : 'none');
    console.log('  AAAA:', aaaa.status === 'fulfilled' ? aaaa.value : 'none');
    console.log('  MX:  ', mx.status === 'fulfilled' ? mx.value : 'none');
    console.log('  TXT: ', txt.status === 'fulfilled' ? txt.value : 'none');
    console.log('  NS:  ', ns.status === 'fulfilled' ? ns.value : 'none');
  } catch (err) {
    console.error('Resolution failed:', err.message);
  }
}

resolveAll('google.com');
```

---

## `lookup` vs `resolve`: The Complete Comparison

| Feature | `dns.lookup()` | `dns.resolve()` |
|---------|----------------|------------------|
| Underlying mechanism | OS `getaddrinfo()` | c-ares async DNS client |
| Thread pool usage | **Yes** — blocks a thread pool thread | **No** — fully async |
| Checks `/etc/hosts` | **Yes** | **No** |
| Uses OS DNS cache | **Yes** | **No** |
| Returns | One address (or all with `{ all: true }`) | All records of the requested type |
| Record types | A and AAAA only | A, AAAA, CNAME, MX, TXT, NS, SOA, SRV |
| Used by | `http.request`, `net.createConnection` (default) | Nothing by default — you call it explicitly |
| Scalability under load | **Poor** — limited by thread pool size | **Good** — scales with event loop |

### The Thread Pool Problem

The default libuv thread pool has only 4 threads. If your server is making many outbound HTTP requests, each one calls `dns.lookup()`, which occupies a thread pool thread. Under high load, DNS lookups queue up behind file I/O operations that also use the thread pool.

```javascript
'use strict';

const dns = require('node:dns');

// Simulate high-concurrency DNS lookups — they compete for thread pool threads
const start = Date.now();
let completed = 0;

for (let i = 0; i < 100; i++) {
  dns.lookup('example.com', () => {
    completed++;
    if (completed === 100) {
      console.log(`100 lookups completed in ${Date.now() - start}ms`);
      // With 4 thread pool threads, this will be slow
      // because lookups are serialized in batches of 4
    }
  });
}
```

### Workarounds

**Option 1: Increase the thread pool size.**

```bash
UV_THREADPOOL_SIZE=64 node server.js
```

**Option 2: Use `dns.resolve()` instead of `dns.lookup()`.**

You can tell Node.js HTTP client to use `dns.resolve()` instead of `dns.lookup()`:

```javascript
'use strict';

const http = require('node:http');
const dns = require('node:dns');

// Override the lookup function for outbound HTTP requests
const options = {
  hostname: 'example.com',
  port: 80,
  path: '/',
  // Custom lookup that uses dns.resolve instead of dns.lookup
  lookup: (hostname, opts, callback) => {
    dns.resolve(hostname, 'A', (err, addresses) => {
      if (err) return callback(err);
      // Return the first address
      callback(null, addresses[0], 4);
    });
  },
};

const req = http.request(options, (res) => {
  console.log(`Status: ${res.statusCode}`);
  res.resume(); // Drain the response
});

req.on('error', (err) => console.error(err.message));
req.end();
```

**Option 3: Implement DNS caching at the application level (see below).**

---

## DNS Caching

DNS caching happens at multiple levels. Understanding each helps you diagnose "stale DNS" issues.

### Cache Layers

| Layer | Location | TTL Source | Flush Method |
|-------|----------|-----------|--------------|
| Browser cache | Client browser | DNS TTL | Clear browser cache |
| OS resolver cache | Client or server OS | DNS TTL | `systemd-resolve --flush-caches` (Linux), `dscacheutil -flushcache` (macOS) |
| Recursive resolver cache | ISP / 8.8.8.8 / 1.1.1.1 | DNS TTL | Wait for TTL to expire |
| Application cache | Your Node.js process | Your implementation | Your implementation |

### The TTL (Time To Live)

Every DNS record has a TTL in seconds. When the TTL expires, the record must be re-queried. Common TTL values:

| TTL | Use Case |
|-----|----------|
| 60s (1 min) | Services that change frequently (failover, blue-green deploys) |
| 300s (5 min) | Standard web services |
| 3600s (1 hour) | Stable services |
| 86400s (1 day) | Rarely-changing records (MX, NS) |

### Node.js Does NOT Cache DNS

Unlike browsers and operating systems, Node.js does **not** cache DNS results by default. Every `http.request()` triggers a new `dns.lookup()` call. On a busy server making thousands of outbound requests per second, this is wasteful.

### Building a DNS Cache

```javascript
'use strict';

const dns = require('node:dns');

class DnsCache {
  #cache = new Map();
  #defaultTtlMs;

  constructor(defaultTtlMs = 30_000) {
    this.#defaultTtlMs = defaultTtlMs;
  }

  lookup(hostname, options, callback) {
    // Normalize arguments — options is optional
    if (typeof options === 'function') {
      callback = options;
      options = {};
    }

    const key = `${hostname}:${options.family || 0}`;
    const cached = this.#cache.get(key);

    if (cached && cached.expiry > Date.now()) {
      // Cache hit — return immediately without touching the thread pool
      process.nextTick(() => {
        callback(null, cached.address, cached.family);
      });
      return;
    }

    // Cache miss — perform the actual lookup
    dns.lookup(hostname, options, (err, address, family) => {
      if (err) return callback(err);

      this.#cache.set(key, {
        address,
        family,
        expiry: Date.now() + this.#defaultTtlMs,
      });

      callback(null, address, family);
    });
  }

  clear() {
    this.#cache.clear();
  }

  get size() {
    return this.#cache.size;
  }
}

// Usage
const cache = new DnsCache(60_000); // 60-second TTL

// First lookup — goes to the OS resolver
cache.lookup('example.com', (err, address, family) => {
  console.log(`First lookup: ${address} (IPv${family})`);
  console.log(`Cache size: ${cache.size}`);

  // Second lookup — served from cache (no thread pool usage)
  cache.lookup('example.com', (err, address, family) => {
    console.log(`Second lookup (cached): ${address} (IPv${family})`);
  });
});
```

### Using the Cache With HTTP Requests

```javascript
'use strict';

const http = require('node:http');
const dns = require('node:dns');

// Simple in-memory DNS cache
const dnsCache = new Map();
const DNS_TTL_MS = 30_000;

function cachedLookup(hostname, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }

  const cached = dnsCache.get(hostname);
  if (cached && cached.expiry > Date.now()) {
    return process.nextTick(() => callback(null, cached.address, cached.family));
  }

  dns.lookup(hostname, options, (err, address, family) => {
    if (!err) {
      dnsCache.set(hostname, { address, family, expiry: Date.now() + DNS_TTL_MS });
    }
    callback(err, address, family);
  });
}

// Every outbound HTTP request uses the cached lookup
function makeRequest(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { lookup: cachedLookup }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, bodyLength: body.length }));
    });
    req.on('error', reject);
  });
}
```

---

## Reverse DNS Lookup

Reverse DNS maps an IP address back to a hostname. This is useful for logging, auditing, and identifying connecting clients.

```javascript
'use strict';

const dns = require('node:dns');

// Reverse lookup — IP to hostname
dns.reverse('8.8.8.8', (err, hostnames) => {
  if (err) {
    console.error('Reverse lookup failed:', err.message);
    return;
  }
  console.log('8.8.8.8 resolves to:', hostnames);
  // ['dns.google']
});

// Using the promises API
const dnsPromises = require('node:dns/promises');

async function reverseAll(ips) {
  for (const ip of ips) {
    try {
      const hostnames = await dnsPromises.reverse(ip);
      console.log(`${ip} → ${hostnames.join(', ')}`);
    } catch (err) {
      console.log(`${ip} → no reverse DNS (${err.code})`);
    }
  }
}

reverseAll(['8.8.8.8', '1.1.1.1', '127.0.0.1']);
```

---

## Setting Custom DNS Servers

By default, `dns.resolve()` uses the servers from `/etc/resolv.conf`. You can override this:

```javascript
'use strict';

const dns = require('node:dns');

// Check current DNS servers
console.log('Default servers:', dns.getServers());
// e.g., ['192.168.1.1', '8.8.8.8']

// Set custom DNS servers
dns.setServers([
  '8.8.8.8',        // Google Public DNS (IPv4)
  '8.8.4.4',        // Google Public DNS (IPv4, secondary)
  '2001:4860:4860::8888', // Google Public DNS (IPv6)
  '1.1.1.1',        // Cloudflare DNS
]);

console.log('Updated servers:', dns.getServers());

// Now all dns.resolve() calls use these servers
dns.resolve('example.com', 'A', (err, addresses) => {
  if (err) console.error(err.message);
  else console.log('Resolved via custom servers:', addresses);
});
```

Note: `dns.setServers()` only affects `dns.resolve()` and its variants. It does **not** affect `dns.lookup()`, which always uses the OS resolver.

---

## Common DNS Error Codes

```javascript
'use strict';

const dns = require('node:dns');

// These are the error codes you will encounter
const errorCodes = {
  'NODATA':     'DNS server returned answer with no data',
  'FORMERR':    'DNS server claims query was misformatted',
  'SERVFAIL':   'DNS server returned general failure',
  'NOTFOUND':   'Domain name not found',
  'NOTIMP':     'DNS server does not implement requested operation',
  'REFUSED':    'DNS server refused query',
  'BADQUERY':   'Misformatted DNS query',
  'BADNAME':    'Misformatted hostname',
  'BADFAMILY':  'Unsupported address family',
  'BADRESP':    'Misformatted DNS reply',
  'CONNREFUSED':'Could not contact DNS servers',
  'TIMEOUT':    'Timeout while contacting DNS servers',
  'EOF':        'End of file',
  'FILE':       'Error reading file',
  'NOMEM':      'Out of memory',
  'DESTRUCTION':'Channel is being destroyed',
  'CANCELLED':  'DNS query cancelled',
};

// Example: handling a NOTFOUND error
dns.resolve('this-domain-definitely-does-not-exist-12345.com', 'A', (err) => {
  if (err) {
    console.log(`Error code: ${err.code}`);           // NOTFOUND
    console.log(`Description: ${errorCodes[err.code]}`);
  }
});
```

---

## Key Takeaways

- DNS is a hierarchical system: root servers delegate to TLD servers, which delegate to authoritative nameservers. Recursive resolvers cache results at each step.
- The most important record types are A (IPv4), AAAA (IPv6), CNAME (alias), MX (mail), TXT (verification/SPF), and SRV (service discovery).
- `dns.lookup()` uses the OS resolver on the libuv thread pool (blocking); `dns.resolve()` uses c-ares asynchronously (non-blocking). Under high load, `dns.lookup()` becomes a bottleneck.
- Node.js does not cache DNS by default. For servers making many outbound requests, implement application-level DNS caching or use the `lookup` option to inject a cached resolver.
- DNS TTLs control how long records are cached; short TTLs (60s) enable fast failover but increase resolver load.

---

## Next

Continue to [Lesson 06 — The net Module](lesson-06-net-module.md) to start building TCP servers and clients with Node.js, using the networking knowledge from these first five lessons as your foundation.
