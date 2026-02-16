# E04: DNS Resolver

## Objective

Build a DNS resolution tool that queries multiple record types for a given domain using Node.js's built-in `dns` module. You will explore the critical difference between `dns.lookup()` (which uses the OS resolver and respects `/etc/hosts`) and `dns.resolve()` (which queries DNS servers directly), measure their performance characteristics, and format the results into a comprehensive domain report. Understanding DNS behavior is essential for debugging network issues in production.

## Prerequisites

- Module 06 / Lesson 01 — Network Fundamentals
- Module 06 / Lesson 05 — DNS Resolution
- Module 06 / Lesson 02 — IP Addressing

## Instructions

1. **Create `dns-resolver.js`.** Accept a domain name as a CLI argument. Query all common record types and display the results.

```js
'use strict';

const dns = require('node:dns');
const { promisify } = require('node:util');

const resolve4 = promisify(dns.resolve4);
const resolve6 = promisify(dns.resolve6);
const resolveMx = promisify(dns.resolveMx);
const resolveTxt = promisify(dns.resolveTxt);
const resolveCname = promisify(dns.resolveCname);
const resolveNs = promisify(dns.resolveNs);
const resolveSoa = promisify(dns.resolveSoa);
const lookup = promisify(dns.lookup);
const reverse = promisify(dns.reverse);

const domain = process.argv[2];
if (!domain) {
  console.error('Usage: node dns-resolver.js <domain>');
  process.exit(1);
}
```

2. **Query all record types.** Run queries for A, AAAA, MX, TXT, CNAME, NS, and SOA records in parallel using `Promise.allSettled()`. This ensures that a failure on one record type (e.g., no AAAA record) does not block the others.

```js
async function queryAll(domain) {
  const queries = [
    { type: 'A',     fn: () => resolve4(domain, { ttl: true }) },
    { type: 'AAAA',  fn: () => resolve6(domain, { ttl: true }) },
    { type: 'MX',    fn: () => resolveMx(domain) },
    { type: 'TXT',   fn: () => resolveTxt(domain) },
    { type: 'CNAME', fn: () => resolveCname(domain) },
    { type: 'NS',    fn: () => resolveNs(domain) },
    { type: 'SOA',   fn: () => resolveSoa(domain) },
  ];

  const results = await Promise.allSettled(queries.map(q => q.fn()));

  for (let i = 0; i < queries.length; i++) {
    const { type } = queries[i];
    const result = results[i];
    if (result.status === 'fulfilled') {
      printRecords(type, result.value);
    } else {
      console.log(`  ${type}: (none — ${result.reason.code})`);
    }
  }
}
```

3. **Format and display records.** Create a `printRecords(type, data)` function that formats each record type clearly:
   - **A/AAAA**: IP address + TTL
   - **MX**: priority + exchange server
   - **TXT**: joined text segments (SPF, DKIM, DMARC records)
   - **CNAME**: canonical name
   - **NS**: nameserver hostname
   - **SOA**: primary NS, admin email, serial, refresh, retry, expire, minttl

4. **Compare `dns.lookup()` vs `dns.resolve()`.** Query the same domain using both methods. Measure the time each takes using `process.hrtime.bigint()`. Run each method 10 times and compute average latency.

```js
async function compareMethods(domain) {
  const iterations = 10;

  // dns.lookup (OS resolver)
  const lookupTimes = [];
  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    await lookup(domain, { all: true });
    lookupTimes.push(Number(process.hrtime.bigint() - start) / 1e6);
  }

  // dns.resolve (direct DNS query)
  const resolveTimes = [];
  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    await resolve4(domain);
    resolveTimes.push(Number(process.hrtime.bigint() - start) / 1e6);
  }

  // ... print comparison ...
}
```

5. **Reverse DNS lookup.** For each A record returned, perform a reverse lookup (`dns.reverse()`) to find the PTR record. This reveals the hostname associated with the IP address — useful for verifying CDN and cloud provider configurations.

6. **Detect common configurations.** Analyze the DNS records and report:
   - Whether the domain uses a CDN (multiple A records, or CNAME pointing to CDN hostnames)
   - Whether email is configured (MX records exist)
   - Whether SPF, DKIM, or DMARC records are present (from TXT records)
   - Whether IPv6 is supported (AAAA records)

7. **Custom DNS server.** Use `dns.setServers()` to query a specific DNS server (e.g., `'8.8.8.8'` for Google, `'1.1.1.1'` for Cloudflare). Accept a `--server` CLI flag. Compare results from different DNS servers for the same domain.

8. **Handle errors gracefully.** Common DNS errors include `ENODATA` (no records of the requested type), `ENOTFOUND` (domain does not exist), and `ETIMEOUT` (DNS server unreachable). Catch each and display a human-readable message.

## Break-Then-Harden Challenge

1. **Query a non-existent domain.** Try resolving `thisdomaindoesnotexist12345.com`. Without error handling, the process crashes. With `Promise.allSettled()`, each query fails independently and you can report which record types returned `ENOTFOUND`. Verify this works correctly.

2. **Set an unreachable DNS server.** Call `dns.setServers(['192.0.2.1'])` (a reserved IP that routes nowhere). Queries should eventually timeout with `ETIMEOUT`. Measure how long the timeout takes. Add a custom timeout using `Promise.race()` with a `setTimeout` to fail faster.

3. **Compare results from different DNS servers.** Query the same domain using Google (`8.8.8.8`), Cloudflare (`1.1.1.1`), and the system default. The A records may differ (different CDN edge nodes). Document the differences and explain why they occur (GeoDNS, anycast, caching).

## Expected Output

```
DNS Report for: github.com
========================================

A Records (IPv4):
  140.82.121.3    TTL: 60s
  140.82.121.4    TTL: 60s

AAAA Records (IPv6):
  (none — ENODATA)

MX Records:
  1  aspmx.l.google.com
  5  alt1.aspmx.l.google.com
  5  alt2.aspmx.l.google.com
  10 alt3.aspmx.l.google.com
  10 alt4.aspmx.l.google.com

TXT Records:
  "v=spf1 ip4:192.30.252.0/22 include:_netblocks..."
  "MS=ms58704441"
  "docusign=..."

CNAME Records:
  (none — ENODATA)

NS Records:
  dns1.p08.nsone.net
  dns2.p08.nsone.net
  dns3.p08.nsone.net
  dns4.p08.nsone.net
  ns-1283.awsdns-32.org
  ns-1707.awsdns-21.co.uk
  ns-421.awsdns-52.com
  ns-520.awsdns-01.net

SOA Record:
  Primary NS: dns1.p08.nsone.net
  Admin:      hostmaster.nsone.net
  Serial:     1
  Refresh:    43200s
  Retry:      7200s
  Expire:     1209600s
  Min TTL:    3600s

Reverse DNS:
  140.82.121.3 → lb-140-82-121-3-iad.github.com
  140.82.121.4 → lb-140-82-121-4-iad.github.com

Analysis:
  CDN detected:   Yes (multiple A records)
  Email:          Yes (5 MX records — Google Workspace)
  SPF:            Yes
  IPv6:           No

Method Comparison (10 iterations):
  dns.lookup():   avg 2.34ms  (OS resolver, cached)
  dns.resolve4(): avg 12.87ms (direct query, bypasses cache)
```

## Bonus

1. **DNS propagation checker.** Query the domain against 5 well-known public DNS servers simultaneously. Display results side by side to check if a DNS change has propagated globally.

2. **Recursive trace.** If the domain has a CNAME, resolve the CNAME target, and if that has another CNAME, keep following the chain. Print the full resolution path: `www.example.com → cdn.example.com → d1234.cloudfront.net → 13.227.85.100`.

## Hints

1. `dns.resolve4(domain, { ttl: true })` returns objects with `{ address, ttl }` instead of bare strings. Use this for the TTL display.

2. `dns.lookup()` uses `getaddrinfo(3)` under the hood — the same system call that `curl` and browsers use. It respects `/etc/hosts`, `/etc/resolv.conf`, and nsswitch.conf. `dns.resolve()` talks directly to DNS servers, bypassing all of that.

3. `Promise.allSettled()` never rejects. Each result is either `{ status: 'fulfilled', value }` or `{ status: 'rejected', reason }`. This is perfect for DNS queries where some record types may not exist.

4. TXT records return arrays of arrays — each TXT record can be split across multiple strings. Join them: `record.join('')` to get the full text.

5. `dns.getServers()` returns the currently configured DNS servers. Call it before and after `dns.setServers()` to show what changed.
