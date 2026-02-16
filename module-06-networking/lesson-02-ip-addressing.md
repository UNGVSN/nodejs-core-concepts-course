# Module 06 / Lesson 02 — IP Addressing

> Every device on a network needs an address. This lesson covers how those addresses work — from the familiar `192.168.1.1` to the intimidating `fe80::1%en0` — and gives you the Node.js tools to validate and classify them programmatically.

---

## Learning Objectives

- Explain IPv4 addressing: 32-bit structure, dotted-decimal notation, address classes, and private ranges
- Explain IPv6 addressing: 128-bit structure, colon-hex notation, compression rules, and common prefixes
- Apply CIDR notation to define subnets and calculate network/host boundaries
- Describe MAC addresses and the ARP protocol that maps IP addresses to hardware addresses
- Use `net.isIP()`, `net.isIPv4()`, and `net.isIPv6()` for address validation in Node.js

---

## IPv4 — Internet Protocol Version 4

IPv4 addresses are **32 bits** long, written as four octets in dotted-decimal notation. Each octet is a number from 0 to 255.

```
192.168.1.42
```

That is four bytes: `11000000.10101000.00000001.00101010` in binary.

### Total Address Space

32 bits give you 2^32 = 4,294,967,296 possible addresses. That sounds like a lot, but the world has more devices than that. This is why IPv6 exists, and why technologies like NAT (Network Address Translation) were invented as a stopgap.

### Private Address Ranges (RFC 1918)

These addresses are reserved for local networks and are not routable on the public internet:

| Range | CIDR | Addresses | Typical Use |
|-------|------|-----------|-------------|
| `10.0.0.0` – `10.255.255.255` | `10.0.0.0/8` | 16,777,216 | Large enterprises, cloud VPCs |
| `172.16.0.0` – `172.31.255.255` | `172.16.0.0/12` | 1,048,576 | Medium networks |
| `192.168.0.0` – `192.168.255.255` | `192.168.0.0/16` | 65,536 | Home networks |

### Special Addresses

| Address | Purpose |
|---------|---------|
| `127.0.0.1` | Loopback — always refers to the local machine |
| `0.0.0.0` | "All interfaces" — used when binding a server to listen on every network interface |
| `255.255.255.255` | Broadcast — sent to all devices on the local network |
| `169.254.x.x` | Link-local — auto-assigned when DHCP fails |

### Validating IPv4 in Node.js

```javascript
'use strict';

const net = require('node:net');

console.log(net.isIP('192.168.1.1'));       // 4 (it is IPv4)
console.log(net.isIPv4('192.168.1.1'));     // true
console.log(net.isIPv4('not-an-ip'));       // false
console.log(net.isIPv4('256.1.1.1'));       // false — octets must be 0-255
console.log(net.isIPv4('192.168.1'));       // false — must have 4 octets
```

---

## IPv6 — Internet Protocol Version 6

IPv6 addresses are **128 bits** long, written as eight groups of four hexadecimal digits separated by colons.

```
2001:0db8:85a3:0000:0000:8a2e:0370:7334
```

### Address Space

128 bits give you 2^128 = 340,282,366,920,938,463,463,374,607,431,768,211,456 addresses. That is roughly 3.4 x 10^38 — enough to assign an address to every atom on Earth's surface.

### Compression Rules

IPv6 addresses are long, so two compression rules make them shorter:

**Rule 1: Drop leading zeros in each group.**

```
2001:0db8:0000:0000:0000:0000:0000:0001
becomes
2001:db8:0:0:0:0:0:1
```

**Rule 2: Replace one consecutive run of all-zero groups with `::`.**

```
2001:db8:0:0:0:0:0:1
becomes
2001:db8::1
```

The `::` can appear only once in an address — otherwise the parser cannot determine how many zero groups it replaces.

### Common IPv6 Prefixes

| Address | Purpose |
|---------|---------|
| `::1` | Loopback (equivalent to `127.0.0.1`) |
| `::` | All-zeros, used as bind address (equivalent to `0.0.0.0`) |
| `fe80::/10` | Link-local — auto-configured, not routable |
| `fc00::/7` | Unique local — like RFC 1918 private addresses |
| `2001:db8::/32` | Documentation range — never used in production |
| `::ffff:192.168.1.1` | IPv4-mapped IPv6 address |

### IPv4-Mapped IPv6 Addresses

When a Node.js server listens on `::` (the default on many systems), IPv4 clients appear as IPv4-mapped IPv6 addresses:

```javascript
'use strict';

const net = require('node:net');

const server = net.createServer((socket) => {
  console.log('Remote address:', socket.remoteAddress);
  // If an IPv4 client connects, this prints: ::ffff:127.0.0.1
  // The ::ffff: prefix indicates an IPv4 address mapped into IPv6 space

  socket.end();
});

server.listen(4000, '::', () => {
  console.log('Listening on IPv6 (dual-stack)');

  // Connect via IPv4 — the server will see an IPv4-mapped IPv6 address
  const client = net.createConnection({ port: 4000, host: '127.0.0.1' }, () => {
    client.end();
  });

  client.on('close', () => server.close());
});
```

### Validating IPv6 in Node.js

```javascript
'use strict';

const net = require('node:net');

console.log(net.isIP('::1'));               // 6 (it is IPv6)
console.log(net.isIPv6('::1'));             // true
console.log(net.isIPv6('2001:db8::1'));     // true
console.log(net.isIPv6('fe80::1%en0'));     // true — zone ID is valid
console.log(net.isIPv6('192.168.1.1'));     // false — that is IPv4
console.log(net.isIPv6('not-an-address'));  // false
```

---

## Subnets and CIDR Notation

A subnet divides a network into smaller networks. CIDR (Classless Inter-Domain Routing) notation expresses this by appending a prefix length to an IP address.

```
192.168.1.0/24
```

The `/24` means the first 24 bits are the **network portion** and the remaining 8 bits are the **host portion**.

### How to Read CIDR

| CIDR | Network Bits | Host Bits | Hosts per Subnet | Subnet Mask |
|------|-------------|-----------|-------------------|-------------|
| `/8` | 8 | 24 | 16,777,214 | `255.0.0.0` |
| `/16` | 16 | 16 | 65,534 | `255.255.0.0` |
| `/24` | 24 | 8 | 254 | `255.255.255.0` |
| `/32` | 32 | 0 | 1 (single host) | `255.255.255.255` |

The number of usable hosts is `2^(host bits) - 2` because the first address is the network address and the last is the broadcast address.

### Subnet Calculation in JavaScript

Node.js does not include a built-in subnet calculator, but you can implement one with bitwise operations:

```javascript
'use strict';

/**
 * Parse an IPv4 address string into a 32-bit integer.
 */
function ipToInt(ip) {
  const parts = ip.split('.').map(Number);
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

/**
 * Convert a 32-bit integer back to dotted-decimal notation.
 */
function intToIp(int) {
  return [
    (int >>> 24) & 0xff,
    (int >>> 16) & 0xff,
    (int >>> 8) & 0xff,
    int & 0xff,
  ].join('.');
}

/**
 * Check if an IP address is within a CIDR range.
 */
function isInSubnet(ip, cidr) {
  const [network, prefixStr] = cidr.split('/');
  const prefix = parseInt(prefixStr, 10);
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;

  const ipInt = ipToInt(ip);
  const networkInt = ipToInt(network);

  return (ipInt & mask) === (networkInt & mask);
}

// Examples
console.log(isInSubnet('192.168.1.42', '192.168.1.0/24'));   // true
console.log(isInSubnet('192.168.2.1', '192.168.1.0/24'));    // false
console.log(isInSubnet('10.0.50.100', '10.0.0.0/8'));        // true

// Calculate subnet details
const cidr = '192.168.1.0/24';
const [network, prefixStr] = cidr.split('/');
const prefix = parseInt(prefixStr, 10);
const mask = (~0 << (32 - prefix)) >>> 0;
const networkInt = ipToInt(network);
const broadcastInt = (networkInt | ~mask) >>> 0;

console.log('Network:  ', intToIp(networkInt));     // 192.168.1.0
console.log('Broadcast:', intToIp(broadcastInt));    // 192.168.1.255
console.log('Mask:     ', intToIp(mask));            // 255.255.255.0
console.log('Hosts:    ', broadcastInt - networkInt - 1); // 254
```

---

## MAC Addresses — Layer 2 Identity

A MAC (Media Access Control) address is a **48-bit** hardware address burned into every network interface card. It is written as six pairs of hexadecimal digits:

```
a4:83:e7:2f:01:b5
```

### MAC vs IP

| Property | MAC Address | IP Address |
|----------|-------------|------------|
| Layer | 2 (Data Link) | 3 (Network) |
| Scope | Local network segment only | Global (routable) |
| Assignment | Burned into hardware (or virtualized) | Assigned by DHCP or static config |
| Changes per hop | Yes — rewritten at each router | No — stays the same end-to-end |

A MAC address never leaves the local network. When a packet travels across the internet, the source and destination IP addresses stay the same, but the source and destination MAC addresses change at every router hop.

### Viewing MAC Addresses in Node.js

```javascript
'use strict';

const os = require('node:os');

const interfaces = os.networkInterfaces();

for (const [name, addrs] of Object.entries(interfaces)) {
  for (const addr of addrs) {
    if (addr.mac && addr.mac !== '00:00:00:00:00:00') {
      console.log(`${name}: MAC ${addr.mac} — ${addr.family} ${addr.address}`);
    }
  }
}
// Example output:
// en0: MAC a4:83:e7:2f:01:b5 — IPv4 192.168.1.42
// en0: MAC a4:83:e7:2f:01:b5 — IPv6 fe80::1
```

---

## ARP — Address Resolution Protocol

ARP is the protocol that maps a Layer 3 IP address to a Layer 2 MAC address within a local network. Without ARP, a device that knows the destination IP address cannot construct the Ethernet frame needed to actually deliver the packet.

### How ARP Works

1. Machine A wants to send a packet to `192.168.1.1` on the local network.
2. Machine A checks its **ARP cache** for the MAC address of `192.168.1.1`.
3. If not cached, Machine A broadcasts an **ARP request**: "Who has 192.168.1.1? Tell `a4:83:e7:2f:01:b5`."
4. Every device on the local network receives the broadcast. The device with IP `192.168.1.1` replies: "192.168.1.1 is at `b8:27:eb:12:34:56`."
5. Machine A caches the mapping and constructs the Ethernet frame with the correct destination MAC.

### ARP and Node.js

Node.js does not expose ARP directly — it is a kernel-level concern. But ARP affects you:

- **ARP cache misses** add latency to the first packet in a new connection on a local network.
- **ARP spoofing** is a common attack vector on shared networks (someone claims to be the gateway).
- **ARP storms** on large flat networks can saturate bandwidth.

You can inspect the ARP cache from the terminal:

```bash
# macOS / Linux
arp -a
# Shows: interface (IP) at MAC on interface_name [type]
```

---

## Practical: Building an IP Address Utility

Let us build a utility that combines everything from this lesson:

```javascript
'use strict';

const net = require('node:net');
const os = require('node:os');

/**
 * Classify and describe an IP address.
 */
function describeAddress(ip) {
  const version = net.isIP(ip);

  if (version === 0) {
    return { valid: false, input: ip, error: 'Not a valid IP address' };
  }

  const result = {
    valid: true,
    input: ip,
    version: version === 4 ? 'IPv4' : 'IPv6',
  };

  if (version === 4) {
    const parts = ip.split('.').map(Number);

    // Classify the address
    if (parts[0] === 127) {
      result.type = 'loopback';
    } else if (parts[0] === 10) {
      result.type = 'private (10.0.0.0/8)';
    } else if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) {
      result.type = 'private (172.16.0.0/12)';
    } else if (parts[0] === 192 && parts[1] === 168) {
      result.type = 'private (192.168.0.0/16)';
    } else if (parts[0] === 169 && parts[1] === 254) {
      result.type = 'link-local';
    } else if (parts[0] === 0) {
      result.type = 'unspecified';
    } else {
      result.type = 'public';
    }
  }

  if (version === 6) {
    if (ip === '::1') {
      result.type = 'loopback';
    } else if (ip === '::') {
      result.type = 'unspecified';
    } else if (ip.startsWith('fe80')) {
      result.type = 'link-local';
    } else if (ip.startsWith('fc') || ip.startsWith('fd')) {
      result.type = 'unique-local (private)';
    } else if (ip.startsWith('::ffff:')) {
      result.type = 'IPv4-mapped';
    } else {
      result.type = 'global unicast';
    }
  }

  return result;
}

// Test with various addresses
const testAddresses = [
  '192.168.1.42',
  '10.0.0.1',
  '8.8.8.8',
  '127.0.0.1',
  '169.254.1.1',
  '::1',
  'fe80::1',
  '2001:db8::1',
  '::ffff:192.168.1.1',
  'not-valid',
];

for (const addr of testAddresses) {
  const info = describeAddress(addr);
  if (info.valid) {
    console.log(`${info.input} — ${info.version}, ${info.type}`);
  } else {
    console.log(`${info.input} — INVALID`);
  }
}
```

Expected output:

```
192.168.1.42 — IPv4, private (192.168.0.0/16)
10.0.0.1 — IPv4, private (10.0.0.0/8)
8.8.8.8 — IPv4, public
127.0.0.1 — IPv4, loopback
169.254.1.1 — IPv4, link-local
::1 — IPv6, loopback
fe80::1 — IPv6, link-local
2001:db8::1 — IPv6, global unicast
::ffff:192.168.1.1 — IPv6, IPv4-mapped
not-valid — INVALID
```

---

## Listing Local Addresses

A utility that lists all local addresses and their properties:

```javascript
'use strict';

const os = require('node:os');
const net = require('node:net');

function listLocalAddresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];

  for (const [name, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      addresses.push({
        interface: name,
        family: addr.family,
        address: addr.address,
        netmask: addr.netmask,
        mac: addr.mac,
        internal: addr.internal,
        cidr: addr.cidr,            // e.g., '192.168.1.42/24'
        scopeid: addr.scopeid || 0, // IPv6 scope ID (zone index)
      });
    }
  }

  return addresses;
}

const local = listLocalAddresses();

// Print external (non-loopback) addresses only
const external = local.filter((a) => !a.internal);
for (const addr of external) {
  console.log(`${addr.interface}: ${addr.cidr} (${addr.family}, MAC ${addr.mac})`);
}
```

---

## Key Takeaways

- IPv4 addresses are 32-bit (4.3 billion addresses); IPv6 addresses are 128-bit (effectively unlimited). Node.js handles both transparently.
- Private IPv4 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) are not routable on the public internet.
- CIDR notation (`/24`, `/16`) defines the split between network and host bits; subnet math is straightforward with bitwise operations in JavaScript.
- MAC addresses identify devices on the local network; ARP maps IP addresses to MAC addresses at Layer 2.
- Use `net.isIP()`, `net.isIPv4()`, and `net.isIPv6()` to validate addresses; use `os.networkInterfaces()` to enumerate local interfaces.

---

## Next

Continue to [Lesson 03 — TCP Protocol Deep Dive](lesson-03-tcp-protocol.md) to understand the three-way handshake, sequence numbers, flow control, and congestion control — the mechanics that make TCP reliable.
