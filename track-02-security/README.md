# Track 02 — Security Engineering

> Security is not a feature you bolt on after deployment. This track teaches you to think like an attacker — model threats, harden TLS, prevent timing attacks, validate every input, and protect your server from the most common exploits — all with Node.js core modules and zero dependencies.

---

## Overview

Most Node.js security advice amounts to "install helmet" and "use rate-limit-express." That is not security engineering. That is cargo-culting npm packages.

This track starts from first principles. You will learn threat modeling with the STRIDE framework applied specifically to Node.js server architectures. You will understand TLS at the handshake level — cipher suites, certificate chains, OCSP stapling, and why TLS 1.3 matters. You will implement constant-time comparison to prevent timing attacks, build input validation without a single npm package, and harden a raw `node:http` server against slowloris, request smuggling, path traversal, and ReDoS.

Every defense you build uses only `node:crypto`, `node:tls`, `node:http`, and your understanding of how attacks actually work.

---

## Prerequisite Modules

- **Module 07** — HTTP From Scratch
- **Module 10** — Cryptography, Compression & Security

---

## Lessons

| # | Lesson | Description |
|---|--------|-------------|
| 01 | [Threat Modeling for Node.js](lesson-01-threat-modeling.md) | STRIDE model applied to Node.js servers, identifying attack surfaces, ranking risks, building a threat matrix |
| 02 | [TLS Deep Dive](lesson-02-tls-deep-dive.md) | Certificate chains, CA trust stores, OCSP stapling, cipher suite selection, TLS 1.3 handshake walkthrough, `node:tls` configuration |
| 03 | [Timing Attacks & Side Channels](lesson-03-timing-attacks.md) | Why `===` is dangerous for secrets, `crypto.timingSafeEqual`, constant-time comparison, cache timing considerations |
| 04 | [Input Validation & Sanitization](lesson-04-input-validation.md) | ReDoS prevention, path traversal defense, HTTP header injection, null byte attacks — all without npm validation libraries |
| 05 | [Secure Server Hardening](lesson-05-server-hardening.md) | Rate limiting with `Map` + timestamps, request size limits, slowloris protection via timeouts, HTTP request smuggling defenses |

---

## Who This Track Is For

- Node.js developers building internet-facing servers who need to understand real attack vectors, not just checkbox compliance
- Backend engineers responsible for handling sensitive data (authentication tokens, PII, financial data) in Node.js services
- Developers who want to move beyond "install this security package" toward understanding the threat model their code operates in
- Anyone preparing for security-focused interviews or audits

---

## What You Will Learn

- How to systematically model threats against a Node.js application using STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)
- How TLS actually works at the protocol level — the handshake, key exchange, cipher suites, and how to configure `node:tls` for production
- Why naive string comparison leaks secret values through timing, and how to implement constant-time alternatives
- How to validate and sanitize user input (URLs, paths, headers, query strings) using only built-in JavaScript and `node:*` modules
- How to defend a raw HTTP server against denial-of-service attacks (slowloris, large payloads, connection exhaustion) without any npm middleware
- How to combine these defenses into a layered security architecture that does not depend on a single third-party package
