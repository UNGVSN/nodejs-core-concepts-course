# Project 04 — Mini Process Manager (PM2 Lite)

> PM2 has 40,000 lines of code. Yours will have a few hundred — but you will understand every single one of them. This project makes you build a lightweight process manager from scratch: daemonization, cluster mode, auto-restart with backoff, log rotation, health monitoring, and an HTTP management API. All core Node.js. Zero npm.

---

## Overview

This capstone project draws on your understanding of the event loop, EventEmitter, child processes, cluster mode, worker threads, and networking to build a miniature process manager in the spirit of PM2. You will build a daemon that manages the lifecycle of Node.js applications — starting, stopping, restarting, and monitoring them — with a CLI for human operators and an HTTP API for programmatic control.

The process manager must handle the hard problems: auto-restart on crash with exponential backoff, graceful zero-downtime reload, log capture and rotation, IPC-based health monitoring, and PID file management. This is systems programming in JavaScript.

---

## Prerequisite Modules

- **Module 01** — Node.js Architecture & the Event Loop
- **Module 02** — EventEmitter & Event-Driven Patterns
- **Module 06** — Networking
- **Module 07** — HTTP From Scratch
- **Module 08** — Unix, Processes & IPC
- **Module 09** — Multi-Threading & Performance

---

## Features to Build

- **Start/stop/restart applications** — launch Node.js apps as child processes, track their state, and manage their lifecycle
- **Cluster mode** — fork N workers per application based on CPU count via `node:cluster`
- **Auto-restart with exponential backoff** — automatically restart crashed processes; increase delay after repeated failures (1s, 2s, 4s, 8s... capped at 30s); reset backoff after stable uptime
- **Log rotation** — capture stdout/stderr from managed processes; rotate log files when they exceed a configurable size (default 10MB)
- **IPC health monitoring** — collect memory usage, CPU time, event loop delay, and uptime from managed processes via `child_process` IPC messages
- **HTTP management API** — `GET /status` (list all apps), `GET /status/:app` (single app detail), `POST /start/:app`, `POST /stop/:app`, `POST /restart/:app`, `POST /reload/:app`
- **Graceful reload** — zero-downtime restart: start new workers, wait for them to be ready, then gracefully shut down old workers
- **Environment variable management** — pass and override environment variables per application via config
- **PID file management** — write PID files for the daemon and each managed process; clean up on exit
- **CLI interface** — human-friendly commands: `pm start app.js`, `pm stop myapp`, `pm restart myapp`, `pm status`, `pm logs myapp`

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      pm.js (CLI)                         │
│                                                         │
│  Commands: start, stop, restart, reload, status, logs    │
│  Communicates with daemon via Unix socket or HTTP API    │
└────────────────────────┬────────────────────────────────┘
                         │ HTTP / Unix Socket
                         ▼
┌─────────────────────────────────────────────────────────┐
│                    daemon.js (main)                       │
│                                                         │
│  ┌──────────────┐  ┌──────────────────────────────────┐ │
│  │ HTTP API     │  │  Process Registry (Map)           │ │
│  │ Server       │  │                                  │ │
│  │ (management  │  │  app-name → {                    │ │
│  │  endpoints)  │  │    pid, status, restarts,        │ │
│  └──────────────┘  │    uptime, health, config        │ │
│                     │  }                               │ │
│  ┌──────────────┐  └──────────┬───────────────────────┘ │
│  │ Config       │             │                         │
│  │ Loader       │             ▼                         │
│  └──────────────┘  ┌──────────────────────────────────┐ │
│                     │  Process Supervisor               │ │
│                     │                                  │ │
│                     │  ┌────────────┐ ┌────────────┐  │ │
│                     │  │ App 1      │ │ App 2      │  │ │
│                     │  │ (cluster:4)│ │ (fork:1)   │  │ │
│                     │  │ ┌─┐┌─┐┌─┐┌┐│ │ ┌─┐        │  │ │
│                     │  │ │W││W││W││W││ │ │P│        │  │ │
│                     │  │ └─┘└─┘└─┘└┘│ │ └─┘        │  │ │
│                     │  └────────────┘ └────────────┘  │ │
│                     └──────────────────────────────────┘ │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Health       │  │ Log Manager  │  │ PID File     │  │
│  │ Monitor      │  │ (capture +   │  │ Manager      │  │
│  │ (IPC-based)  │  │  rotation)   │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Auto-Restart Engine                              │   │
│  │ (exponential backoff: 1s → 2s → 4s → ... → 30s) │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**Process configuration format (`pm-config.json`):**

```json
{
  "apps": [
    {
      "name": "web-server",
      "script": "./server.js",
      "mode": "cluster",
      "instances": 4,
      "env": {
        "PORT": "3000",
        "NODE_ENV": "production"
      },
      "maxRestarts": 10,
      "maxLogSize": "10MB",
      "gracefulTimeout": 5000
    },
    {
      "name": "background-worker",
      "script": "./worker.js",
      "mode": "fork",
      "instances": 1,
      "env": {
        "QUEUE": "jobs"
      }
    }
  ]
}
```

---

## Deliverables

| File | Description |
|------|-------------|
| `daemon.js` | Main daemon process — manages the process registry, supervisor, and health monitor |
| `pm.js` | CLI tool — human-friendly commands that communicate with the daemon |
| `lib/supervisor.js` | Process supervisor — fork, kill, and manage child process lifecycles |
| `lib/cluster-manager.js` | Cluster mode manager — fork workers, handle graceful reload |
| `lib/restart-engine.js` | Auto-restart with exponential backoff logic |
| `lib/log-manager.js` | Log capture (stdout/stderr piping) and rotation by file size |
| `lib/health-monitor.js` | IPC-based health collection (memory, CPU, event loop delay) |
| `lib/http-api.js` | HTTP management API server (status, start, stop, restart, reload) |
| `lib/pid-manager.js` | PID file creation, validation, and cleanup |
| `lib/config.js` | Configuration loader and validator |
| `pm-config.json` | Example process configuration file |
| `test/` | Integration test scripts — start app, crash it, verify restart, check logs |

---

## Acceptance Criteria

- [ ] `pm start app.js` launches the application as a child process and writes a PID file
- [ ] `pm stop myapp` sends `SIGTERM`, waits for graceful exit, then `SIGKILL` after timeout
- [ ] `pm restart myapp` stops then starts the application
- [ ] `pm status` prints a table: name, PID, status, uptime, restarts, memory, CPU
- [ ] `pm logs myapp` streams the last 20 lines then follows new output (like `tail -f`)
- [ ] Cluster mode forks the configured number of workers sharing the same port
- [ ] Crashed processes auto-restart with exponential backoff (1s, 2s, 4s, 8s, 16s, 30s cap)
- [ ] Backoff resets to 1s after the process runs stably for 60 seconds
- [ ] Log files rotate when exceeding the configured maximum size
- [ ] Health monitor collects and reports `process.memoryUsage()`, `process.cpuUsage()`, and event loop delay via IPC
- [ ] `POST /reload/myapp` performs zero-downtime restart in cluster mode (new workers ready before old ones die)
- [ ] HTTP API returns JSON responses with appropriate status codes
- [ ] PID files are cleaned up on daemon shutdown and when processes exit
- [ ] Environment variables from config are passed to child processes
- [ ] Zero npm packages — only `require('node:...')` imports

---

## Estimated Effort

**15-20 hours** for a developer who has completed the prerequisite modules.

| Phase | Hours |
|-------|-------|
| Daemon + process supervisor (fork/kill/track) | 3-4 |
| Cluster mode + graceful reload | 2-3 |
| Auto-restart with exponential backoff | 1-2 |
| Log capture + rotation | 1-2 |
| IPC health monitoring | 2-3 |
| HTTP management API | 2-3 |
| CLI tool (pm.js) | 2-3 |
| PID files + config + integration tests | 2-3 |

---

## Hints

- The daemon itself should detach from the terminal. Use `child_process.spawn` with `detached: true` and `stdio: 'ignore'` to daemonize, then `unref()` the child
- For the CLI-to-daemon communication, a Unix domain socket (via `node:net`) is faster than HTTP, but HTTP is simpler to debug — consider supporting both
- Exponential backoff: `delay = Math.min(baseDelay * Math.pow(2, restartCount), maxDelay)`
- For log rotation, check file size with `fs.stat()` before each write; when it exceeds the limit, rename the current file with a timestamp suffix and open a new one
- Graceful reload in cluster mode: fork new workers first, wait for their `'listening'` event, then `worker.disconnect()` old workers and set a kill timeout
- Collect event loop delay with `perf_hooks.monitorEventLoopDelay()` — send the p99 value to the daemon via `process.send()`
