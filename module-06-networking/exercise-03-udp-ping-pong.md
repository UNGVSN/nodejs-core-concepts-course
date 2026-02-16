# E03: UDP Ping-Pong

## Objective

Build a UDP client-server pair that measures network round-trip latency with high precision. The client sends timestamped ping packets, the server reflects them as pong packets, and the client computes RTT (round-trip time) for each exchange. After a configurable number of pings, the client reports min, max, average, median, standard deviation, and p99 latency statistics. This exercise teaches you the fundamental differences between UDP and TCP through direct experience.

## Prerequisites

- Module 06 / Lesson 01 — Network Fundamentals
- Module 06 / Lesson 04 — UDP and Datagrams
- Module 03 / Lesson 04 — Buffer Operations (for packing timestamps into packets)

## Instructions

1. **Create `pong-server.js`.** Bind a UDP socket to a configurable port and reflect every received datagram back to the sender.

```js
'use strict';

const dgram = require('node:dgram');

const PORT = parseInt(process.argv[2] || '5000', 10);
const server = dgram.createSocket('udp4');

let packetCount = 0;

server.on('message', (msg, rinfo) => {
  packetCount++;
  server.send(msg, rinfo.port, rinfo.address);
});

server.on('listening', () => {
  const addr = server.address();
  console.log(`Pong server listening on ${addr.address}:${addr.port}`);
});

server.on('error', (err) => {
  console.error('Server error:', err.message);
  server.close();
});

server.bind(PORT);

process.on('SIGINT', () => {
  console.log(`\nReceived ${packetCount} packets. Shutting down.`);
  server.close();
});
```

2. **Define the ping packet format.** Each ping carries a sequence number and a high-resolution timestamp:

```
+---------------------------+-------------------------------+
| Sequence Number (4 bytes) | Timestamp ns (8 bytes, BigInt) |
+---------------------------+-------------------------------+
```

Total packet size: 12 bytes. Use `Buffer.alloc(12)` and `writeUInt32BE` / `writeBigUInt64BE`.

3. **Create `ping-client.js`.** Send a configurable number of pings (default 100) with a configurable interval (default 100 ms). For each ping, record the send time. When the pong returns, compute RTT.

```js
'use strict';

const dgram = require('node:dgram');

const HOST = process.argv[2] || '127.0.0.1';
const PORT = parseInt(process.argv[3] || '5000', 10);
const COUNT = parseInt(process.argv[4] || '100', 10);
const INTERVAL = parseInt(process.argv[5] || '100', 10);

const client = dgram.createSocket('udp4');
const results = [];
let sent = 0;
let received = 0;
```

4. **Send pings at regular intervals.** Use `setInterval` to send one ping every `INTERVAL` ms. Pack the sequence number and `process.hrtime.bigint()` into the 12-byte buffer. Stop the interval after `COUNT` pings.

5. **Receive pongs and compute RTT.** On the `'message'` event, unpack the sequence number and original timestamp. Compute `RTT = process.hrtime.bigint() - originalTimestamp`. Store the result in nanoseconds. Convert to microseconds for display.

```js
client.on('message', (msg) => {
  const now = process.hrtime.bigint();
  const seq = msg.readUInt32BE(0);
  const sendTime = msg.readBigUInt64BE(4);
  const rttNs = Number(now - sendTime);
  const rttUs = rttNs / 1000;

  results.push({ seq, rttUs });
  received++;

  process.stdout.write(
    `Pong seq=${seq} rtt=${rttUs.toFixed(1)}us\r`
  );
});
```

6. **Detect packet loss.** After a timeout (2x the interval), check which sequence numbers have not received a pong. Report them as lost. Calculate loss percentage.

7. **Compute statistics.** After all pongs are received (or the timeout expires), compute and print:
   - **Min RTT** — fastest round trip
   - **Max RTT** — slowest round trip
   - **Average RTT** — arithmetic mean
   - **Median RTT** — 50th percentile
   - **Std Dev** — standard deviation
   - **p99 RTT** — 99th percentile
   - **Packet loss** — percentage of pings with no pong

```js
function computeStats(rtts) {
  rtts.sort((a, b) => a - b);
  const sum = rtts.reduce((acc, v) => acc + v, 0);
  const avg = sum / rtts.length;
  const median = rtts[Math.floor(rtts.length / 2)];
  const p99 = rtts[Math.floor(rtts.length * 0.99)];
  const variance = rtts.reduce((acc, v) => acc + (v - avg) ** 2, 0) / rtts.length;
  const stddev = Math.sqrt(variance);

  return { min: rtts[0], max: rtts[rtts.length - 1], avg, median, p99, stddev };
}
```

8. **Print the final report.** Display a formatted summary table with all statistics.

## Break-Then-Harden Challenge

1. **Do not handle out-of-order pongs.** UDP does not guarantee ordering. If pong for seq=5 arrives before seq=4, and your code assumes sequential arrival, the RTT calculations will be wrong (or crash on missing index). Use the sequence number from the packet, not the arrival order, to match pongs to pings.

2. **Send all pings simultaneously.** Remove the interval and fire all 100 pings in a tight loop. On localhost, this works. But it reveals a subtle bug: if the kernel's UDP send buffer overflows, some pings are silently dropped (no error, no event). Add send-buffer overflow detection by checking the return value and listening for `'error'` events.

3. **Use TCP instead of UDP.** Rewrite the ping-pong pair using `net.createConnection` and `net.createServer`. Compare the latency numbers. TCP's three-way handshake and Nagle's algorithm add measurable overhead. Disable Nagle with `socket.setNoDelay(true)` and measure again.

## Expected Output

```
Pinging 127.0.0.1:5000 — 100 packets, interval 100ms

Pong seq=0   rtt=142.3us
Pong seq=1   rtt=98.7us
Pong seq=2   rtt=105.1us
...
Pong seq=99  rtt=112.4us

--- 127.0.0.1:5000 ping statistics ---
100 packets sent, 100 received, 0.0% packet loss

RTT Statistics (microseconds):
  Min:     67.2 us
  Max:     891.4 us
  Avg:     124.8 us
  Median:  108.3 us
  Std Dev: 72.1 us
  p99:     654.2 us

Latency distribution:
  < 100 us:  34 packets (34%)
  100-200 us: 51 packets (51%)
  200-500 us: 12 packets (12%)
  500+ us:    3 packets (3%)
```

## Bonus

1. **Add payload size option.** Accept a `--size <bytes>` flag that pads the ping packet with extra bytes. Measure how RTT changes with packet sizes from 12 bytes to 65,507 bytes (max UDP payload). Plot the relationship.

2. **Continuous mode.** Add a `--continuous` flag that sends pings indefinitely (like `ping` command). Print a running summary every 10 seconds. Handle `SIGINT` to print the final report.

## Hints

1. `dgram.createSocket('udp4')` creates a UDP socket. Unlike TCP, there is no `connect` step — you can send to any address immediately with `socket.send(buffer, port, host)`.

2. `process.hrtime.bigint()` returns nanoseconds as a `BigInt`. You must use `Number()` to convert before doing arithmetic with regular numbers. Be aware of precision loss above 2^53 nanoseconds (~104 days).

3. UDP packets can be reordered, duplicated, or lost. Your code must handle all three cases. Use the sequence number as the authoritative identifier — never rely on arrival order.

4. The server does zero processing — it just reflects the packet. This means the RTT you measure is almost entirely network + kernel overhead. On localhost, expect sub-millisecond times.

5. To detect lost packets, use `setTimeout` after sending the last ping. Wait for `2 * INTERVAL` ms, then check which sequence numbers never received a response.
