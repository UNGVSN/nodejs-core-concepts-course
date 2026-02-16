# Module 08 / Lesson 08 — OS Module & System Information

> Your Node.js application does not run in a vacuum — it runs on a machine with a specific architecture, a finite amount of memory, a certain number of CPU cores, and network interfaces with real IP addresses. The `node:os` module gives you programmatic access to all of this information, enabling you to build health dashboards, auto-tune worker counts, detect platform differences, and monitor resource usage without shelling out to system commands.

## Learning Objectives

- Query CPU architecture, platform, and OS version using `os.arch()`, `os.platform()`, `os.type()`, and `os.release()`
- Read CPU core details with `os.cpus()` and use core count to size worker pools and thread pools
- Monitor system memory with `os.totalmem()` and `os.freemem()`, and interpret load averages from `os.loadavg()`
- Enumerate network interfaces with `os.networkInterfaces()` to find IP addresses and MAC addresses
- Access system constants (`os.constants.signals`, `os.constants.errno`) and user information (`os.userInfo()`) for cross-platform scripting

---

## Platform and Architecture

These functions tell you what operating system and CPU architecture your code is running on.

```javascript
'use strict';

const os = require('node:os');

console.log('Architecture:', os.arch());      // 'x64', 'arm64', 'arm', 'ia32'
console.log('Platform:', os.platform());      // 'linux', 'darwin', 'win32', 'freebsd'
console.log('OS Type:', os.type());           // 'Linux', 'Darwin', 'Windows_NT'
console.log('OS Release:', os.release());     // '5.15.0-91-generic', '23.2.0', '10.0.22621'
console.log('OS Version:', os.version());     // '#101-Ubuntu SMP...', 'Darwin Kernel Version...'
console.log('Machine:', os.machine());        // 'x86_64', 'arm64' (Node.js 18.9+)
console.log('Endianness:', os.endianness());  // 'LE' (little-endian) or 'BE' (big-endian)
```

### Cross-Platform Code

```javascript
'use strict';

const os = require('node:os');
const path = require('node:path');

const platform = os.platform();

// Platform-specific configuration
const config = {
  tempDir: os.tmpdir(),
  homeDir: os.homedir(),
  lineEnding: os.EOL,
  pathSeparator: path.sep,
};

console.log('Config:', config);

// Example: choose a different default path per platform
function getDefaultDataDir() {
  switch (platform) {
    case 'darwin':
      return path.join(os.homedir(), 'Library', 'Application Support', 'myapp');
    case 'win32':
      return path.join(process.env.APPDATA || os.homedir(), 'myapp');
    case 'linux':
    default:
      return path.join(os.homedir(), '.config', 'myapp');
  }
}

console.log('Data directory:', getDefaultDataDir());

// Example: platform-aware shell commands
function getShellCommand() {
  if (platform === 'win32') {
    return { shell: 'cmd.exe', flag: '/c' };
  }
  return { shell: '/bin/sh', flag: '-c' };
}

console.log('Shell:', getShellCommand());
```

---

## CPU Information

`os.cpus()` returns an array of objects, one per logical CPU core. Each object contains the model name, clock speed in MHz, and time spent in different modes.

```javascript
'use strict';

const os = require('node:os');

const cpus = os.cpus();

console.log(`CPU cores: ${cpus.length}`);
console.log(`Model: ${cpus[0].model}`);
console.log(`Speed: ${cpus[0].speed} MHz`);

// Show all cores
cpus.forEach((cpu, index) => {
  const total = Object.values(cpu.times).reduce((a, b) => a + b, 0);
  const idle = cpu.times.idle;
  const usage = ((1 - idle / total) * 100).toFixed(1);

  console.log(`  Core ${index}: ${cpu.model.trim()} @ ${cpu.speed} MHz — ${usage}% used`);
});
```

### CPU Times

Each core reports time (in milliseconds) spent in these modes:

| Property | Meaning |
|---|---|
| `user` | Time in user-mode code (your applications) |
| `nice` | Time in user-mode with low priority (Unix only) |
| `sys` | Time in kernel-mode (system calls, I/O) |
| `idle` | Time doing nothing |
| `irq` | Time handling hardware interrupts |

```javascript
'use strict';

const os = require('node:os');

/**
 * Calculate CPU usage percentage across all cores.
 * Takes two snapshots separated by a delay.
 */
function measureCPUUsage(durationMs) {
  return new Promise((resolve) => {
    const startCpus = os.cpus();

    setTimeout(() => {
      const endCpus = os.cpus();
      let totalIdle = 0;
      let totalTick = 0;

      for (let i = 0; i < startCpus.length; i++) {
        const startTimes = startCpus[i].times;
        const endTimes = endCpus[i].times;

        const idleDiff = endTimes.idle - startTimes.idle;

        const totalDiff =
          (endTimes.user - startTimes.user) +
          (endTimes.nice - startTimes.nice) +
          (endTimes.sys - startTimes.sys) +
          (endTimes.idle - startTimes.idle) +
          (endTimes.irq - startTimes.irq);

        totalIdle += idleDiff;
        totalTick += totalDiff;
      }

      const usagePercent = totalTick === 0 ? 0 : ((1 - totalIdle / totalTick) * 100);
      resolve(usagePercent.toFixed(1));
    }, durationMs);
  });
}

// Usage
measureCPUUsage(1000).then((usage) => {
  console.log(`CPU usage over 1 second: ${usage}%`);
});
```

### Determining Optimal Worker Count

```javascript
'use strict';

const os = require('node:os');

const cpuCount = os.cpus().length;

// Common strategies for worker/thread pool sizing
const strategies = {
  // One worker per core — maximum CPU parallelism
  maxParallel: cpuCount,

  // Leave one core for the OS and primary process
  conservative: Math.max(1, cpuCount - 1),

  // For I/O-bound work, more workers than cores can help
  ioBound: cpuCount * 2,

  // UV_THREADPOOL_SIZE default is 4, max is 1024
  uvThreadPool: parseInt(process.env.UV_THREADPOOL_SIZE, 10) || 4,
};

console.log(`CPU cores: ${cpuCount}`);
console.log('Worker sizing strategies:');
for (const [name, count] of Object.entries(strategies)) {
  console.log(`  ${name}: ${count} workers`);
}
```

---

## System Memory

```javascript
'use strict';

const os = require('node:os');

function formatBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let value = bytes;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(2)} ${units[i]}`;
}

const total = os.totalmem();
const free = os.freemem();
const used = total - free;
const usedPercent = ((used / total) * 100).toFixed(1);

console.log('System Memory:');
console.log(`  Total:     ${formatBytes(total)}`);
console.log(`  Used:      ${formatBytes(used)} (${usedPercent}%)`);
console.log(`  Free:      ${formatBytes(free)}`);

// Process memory (for comparison)
const mem = process.memoryUsage();
console.log('\nProcess Memory:');
console.log(`  RSS:       ${formatBytes(mem.rss)}`);
console.log(`  Heap Used: ${formatBytes(mem.heapUsed)}`);
console.log(`  Heap Total:${formatBytes(mem.heapTotal)}`);
console.log(`  External:  ${formatBytes(mem.external)}`);
```

### Memory Monitoring with Alerts

```javascript
'use strict';

const os = require('node:os');

const THRESHOLDS = {
  warning: 0.80, // 80% used
  critical: 0.90, // 90% used
  danger: 0.95,   // 95% used
};

function checkMemory() {
  const total = os.totalmem();
  const free = os.freemem();
  const usedRatio = 1 - (free / total);
  const usedPercent = (usedRatio * 100).toFixed(1);

  let status = 'OK';
  if (usedRatio >= THRESHOLDS.danger) {
    status = 'DANGER';
  } else if (usedRatio >= THRESHOLDS.critical) {
    status = 'CRITICAL';
  } else if (usedRatio >= THRESHOLDS.warning) {
    status = 'WARNING';
  }

  const freeGB = (free / 1024 / 1024 / 1024).toFixed(2);
  console.log(`[${new Date().toISOString()}] Memory: ${usedPercent}% used (${freeGB} GB free) — ${status}`);

  return { usedRatio, status, freeBytes: free };
}

// Check every 5 seconds
const intervalId = setInterval(checkMemory, 5000);

// Initial check
checkMemory();

// Clean up after 30 seconds for this demo
setTimeout(() => clearInterval(intervalId), 30_000);
```

---

## Load Averages

`os.loadavg()` returns the 1-minute, 5-minute, and 15-minute load averages. These represent the average number of processes waiting for CPU time. On Unix systems, a load average equal to the number of CPU cores means the system is fully utilized.

```javascript
'use strict';

const os = require('node:os');

const [load1, load5, load15] = os.loadavg();
const cpuCount = os.cpus().length;

console.log('Load Averages (Unix only):');
console.log(`  1 minute:  ${load1.toFixed(2)}`);
console.log(`  5 minutes: ${load5.toFixed(2)}`);
console.log(`  15 minutes:${load15.toFixed(2)}`);
console.log(`  CPU cores: ${cpuCount}`);
console.log();

// Interpret load relative to CPU count
function interpretLoad(load, cores) {
  const ratio = load / cores;
  if (ratio < 0.7) return 'OK — system has capacity';
  if (ratio < 1.0) return 'BUSY — approaching full utilization';
  if (ratio < 2.0) return 'OVERLOADED — processes are queuing';
  return 'SEVERELY OVERLOADED — significant queuing';
}

console.log(`  1-min assessment:  ${interpretLoad(load1, cpuCount)}`);
console.log(`  5-min assessment:  ${interpretLoad(load5, cpuCount)}`);
console.log(`  15-min assessment: ${interpretLoad(load15, cpuCount)}`);
```

On Windows, `os.loadavg()` always returns `[0, 0, 0]`. There is no equivalent concept in the Windows kernel.

---

## System Uptime

```javascript
'use strict';

const os = require('node:os');

const uptimeSec = os.uptime();

function formatUptime(seconds) {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = Math.floor(seconds % 60);

  const parts = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  parts.push(`${secs}s`);

  return parts.join(' ');
}

console.log(`System uptime: ${formatUptime(uptimeSec)}`);
console.log(`Process uptime: ${formatUptime(process.uptime())}`);
```

---

## Important Directories

```javascript
'use strict';

const os = require('node:os');

console.log('Home directory:', os.homedir());   // /home/user or /Users/user or C:\Users\user
console.log('Temp directory:', os.tmpdir());     // /tmp or /var/folders/... or C:\Users\...\Temp
console.log('Hostname:', os.hostname());         // machine-name
```

These are particularly useful for cross-platform applications that need to store configuration files, temporary data, or cache files.

---

## Network Interfaces

`os.networkInterfaces()` returns an object keyed by interface name, with each value being an array of address objects.

```javascript
'use strict';

const os = require('node:os');

const interfaces = os.networkInterfaces();

console.log('Network Interfaces:');
console.log('='.repeat(70));

for (const [name, addrs] of Object.entries(interfaces)) {
  console.log(`\n${name}:`);
  for (const addr of addrs) {
    console.log(`  Family:   ${addr.family}`);
    console.log(`  Address:  ${addr.address}`);
    console.log(`  Netmask:  ${addr.netmask}`);
    console.log(`  MAC:      ${addr.mac}`);
    console.log(`  Internal: ${addr.internal}`);
    if (addr.cidr) console.log(`  CIDR:     ${addr.cidr}`);
    console.log();
  }
}
```

### Finding the Machine's External IP

```javascript
'use strict';

const os = require('node:os');

/**
 * Get the first non-internal IPv4 address.
 * Returns '127.0.0.1' if no external interface is found.
 */
function getExternalIP() {
  const interfaces = os.networkInterfaces();

  for (const addrs of Object.values(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === 'IPv4' && !addr.internal) {
        return addr.address;
      }
    }
  }

  return '127.0.0.1';
}

/**
 * Get all non-internal addresses (IPv4 and IPv6).
 */
function getAllExternalAddresses() {
  const interfaces = os.networkInterfaces();
  const result = [];

  for (const [name, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (!addr.internal) {
        result.push({
          interface: name,
          family: addr.family,
          address: addr.address,
          mac: addr.mac,
        });
      }
    }
  }

  return result;
}

console.log('External IP:', getExternalIP());
console.log('\nAll external addresses:');
for (const addr of getAllExternalAddresses()) {
  console.log(`  ${addr.interface}: ${addr.address} (${addr.family}) MAC: ${addr.mac}`);
}
```

---

## User Information

```javascript
'use strict';

const os = require('node:os');

const user = os.userInfo();

console.log('Current User:');
console.log(`  Username: ${user.username}`);
console.log(`  UID:      ${user.uid}`);      // -1 on Windows
console.log(`  GID:      ${user.gid}`);      // -1 on Windows
console.log(`  Home:     ${user.homedir}`);
console.log(`  Shell:    ${user.shell}`);     // null on Windows

// Check if running as root (Unix) or Administrator (conceptual)
if (os.platform() !== 'win32' && user.uid === 0) {
  console.log('\nWARNING: Running as root. Consider using a non-root user.');
}
```

---

## Line Endings and System Constants

### os.EOL

The platform-specific line ending:

```javascript
'use strict';

const os = require('node:os');

console.log('EOL representation:', JSON.stringify(os.EOL));
// Linux/macOS: "\n"
// Windows:     "\r\n"

// Use os.EOL when writing platform-native text files
const lines = ['line 1', 'line 2', 'line 3'];
const content = lines.join(os.EOL) + os.EOL;
console.log('File content bytes:', Buffer.byteLength(content));
```

### os.constants

System-level constants for signals and error numbers:

```javascript
'use strict';

const os = require('node:os');

// Signal constants
console.log('Signal constants:');
console.log(`  SIGINT:  ${os.constants.signals.SIGINT}`);   // 2
console.log(`  SIGTERM: ${os.constants.signals.SIGTERM}`);  // 15
console.log(`  SIGKILL: ${os.constants.signals.SIGKILL}`);  // 9
console.log(`  SIGUSR1: ${os.constants.signals.SIGUSR1}`);  // 10
console.log(`  SIGUSR2: ${os.constants.signals.SIGUSR2}`);  // 12

// Errno constants
console.log('\nErrno constants:');
console.log(`  ENOENT:   ${os.constants.errno.ENOENT}`);    // No such file/directory
console.log(`  EACCES:   ${os.constants.errno.EACCES}`);    // Permission denied
console.log(`  EEXIST:   ${os.constants.errno.EEXIST}`);    // File exists
console.log(`  EADDRINUSE: ${os.constants.errno.EADDRINUSE}`); // Address in use

// Use in error handling
const fs = require('node:fs');
try {
  fs.readFileSync('/nonexistent/file.txt');
} catch (err) {
  if (err.errno === -os.constants.errno.ENOENT) {
    console.log('\nCaught ENOENT: file does not exist');
  }
}
```

---

## Practical Pattern: System Health Dashboard

Bringing all the `os` module capabilities together into a health report:

```javascript
'use strict';

const os = require('node:os');
const http = require('node:http');

function formatBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let value = bytes;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(2)} ${units[i]}`;
}

function getSystemHealth() {
  const cpus = os.cpus();
  const [load1, load5, load15] = os.loadavg();
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const usedMem = totalMem - freeMem;
  const procMem = process.memoryUsage();

  return {
    timestamp: new Date().toISOString(),

    system: {
      hostname: os.hostname(),
      platform: os.platform(),
      arch: os.arch(),
      osType: os.type(),
      osRelease: os.release(),
      uptime: `${(os.uptime() / 3600).toFixed(1)} hours`,
    },

    cpu: {
      model: cpus[0].model.trim(),
      cores: cpus.length,
      speed: `${cpus[0].speed} MHz`,
      loadAverage: {
        '1m': load1.toFixed(2),
        '5m': load5.toFixed(2),
        '15m': load15.toFixed(2),
      },
      loadPerCore: (load1 / cpus.length).toFixed(2),
    },

    memory: {
      total: formatBytes(totalMem),
      used: formatBytes(usedMem),
      free: formatBytes(freeMem),
      usedPercent: ((usedMem / totalMem) * 100).toFixed(1) + '%',
    },

    process: {
      pid: process.pid,
      nodeVersion: process.version,
      uptime: `${process.uptime().toFixed(0)} seconds`,
      rss: formatBytes(procMem.rss),
      heapUsed: formatBytes(procMem.heapUsed),
      heapTotal: formatBytes(procMem.heapTotal),
    },

    network: getNetworkSummary(),

    user: {
      username: os.userInfo().username,
      uid: os.userInfo().uid,
      homedir: os.homedir(),
    },
  };
}

function getNetworkSummary() {
  const interfaces = os.networkInterfaces();
  const summary = [];

  for (const [name, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (!addr.internal && addr.family === 'IPv4') {
        summary.push({ interface: name, address: addr.address, mac: addr.mac });
      }
    }
  }

  return summary;
}

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    const health = getSystemHealth();
    const body = JSON.stringify(health, null, 2);

    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  if (req.url === '/health/summary') {
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    const [load1] = os.loadavg();
    const cores = os.cpus().length;

    const status = {
      status: 'ok',
      memoryUsedPercent: (((totalMem - freeMem) / totalMem) * 100).toFixed(1),
      loadPerCore: (load1 / cores).toFixed(2),
      uptime: `${(os.uptime() / 3600).toFixed(1)}h`,
    };

    // Determine health status
    const memUsage = (totalMem - freeMem) / totalMem;
    const loadRatio = load1 / cores;

    if (memUsage > 0.95 || loadRatio > 2.0) {
      status.status = 'critical';
    } else if (memUsage > 0.85 || loadRatio > 1.0) {
      status.status = 'warning';
    }

    const body = JSON.stringify(status);
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    });
    return res.end(body);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('GET /health or /health/summary\n');
});

server.listen(3000, () => {
  console.log('Health dashboard on http://localhost:3000/health');
});
```

---

## os Module Quick Reference

| Function | Returns | Notes |
|---|---|---|
| `os.arch()` | `'x64'`, `'arm64'`, etc. | CPU architecture |
| `os.platform()` | `'linux'`, `'darwin'`, `'win32'` | OS platform |
| `os.type()` | `'Linux'`, `'Darwin'`, `'Windows_NT'` | OS kernel name |
| `os.release()` | Version string | OS release version |
| `os.version()` | Version string | OS version (detailed) |
| `os.machine()` | `'x86_64'`, `'arm64'` | Machine type (Node 18.9+) |
| `os.cpus()` | Array of CPU info | Model, speed, times per core |
| `os.totalmem()` | Number (bytes) | Total system memory |
| `os.freemem()` | Number (bytes) | Available system memory |
| `os.loadavg()` | `[1m, 5m, 15m]` | Load averages (Unix only) |
| `os.uptime()` | Number (seconds) | System uptime |
| `os.homedir()` | String | User's home directory |
| `os.tmpdir()` | String | System temp directory |
| `os.hostname()` | String | Machine hostname |
| `os.networkInterfaces()` | Object | Network adapter details |
| `os.userInfo()` | Object | Current user info |
| `os.EOL` | `'\n'` or `'\r\n'` | Platform line ending |
| `os.endianness()` | `'LE'` or `'BE'` | Byte order |
| `os.constants` | Object | Signal and errno constants |

---

## Key Takeaways

- `os.cpus().length` is the standard way to determine how many worker processes or threads to spawn — use it in `cluster.fork()` loops and `UV_THREADPOOL_SIZE` calculations rather than hardcoding a number
- `os.totalmem()` and `os.freemem()` report system-wide memory in bytes — combine them with `process.memoryUsage()` to distinguish between system pressure and your application's heap growth
- `os.loadavg()` returns 1/5/15-minute load averages on Unix systems — divide by `os.cpus().length` to get per-core load, where values above 1.0 indicate the system has more work queued than cores to run it
- `os.networkInterfaces()` enumerates all adapters with their IPv4/IPv6 addresses, netmasks, and MAC addresses — filter by `internal === false` and `family === 'IPv4'` to find the machine's LAN-reachable IP
- `os.EOL`, `os.platform()`, and `os.homedir()` are essential for writing cross-platform code that handles file paths, line endings, and configuration directories correctly on Linux, macOS, and Windows

## Next

This concludes Module 08. Continue to [Module 09 — Multi-Threading](../module-09-multithreading/lesson-01-thread-fundamentals.md) where you will learn how `worker_threads` enable true parallel computation within a single Node.js process using shared memory and message passing.
