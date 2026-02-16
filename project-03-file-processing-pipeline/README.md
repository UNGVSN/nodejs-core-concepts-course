# Project 03 — File Processing Pipeline

> One gigabyte of data. Less than 100 megabytes of memory. This project makes you prove that you understand streams, backpressure, worker threads, and the entire Node.js I/O model — by building a streaming ETL pipeline that processes massive files without breaking a sweat.

---

## Overview

This capstone project combines streams, buffers, the file system, worker threads, and cryptography into a configurable file processing pipeline. You will build a streaming ETL (Extract-Transform-Load) engine that reads large files, transforms them through a composable chain of operations, compresses and encrypts the output, and distributes CPU-intensive work across worker threads — all while staying under a strict memory budget.

The pipeline is configured via JSON definition files, making it reusable across different data formats and transformation needs. A CLI interface lets operators run pipelines from the terminal with progress reporting and memory usage stats.

---

## Prerequisite Modules

- **Module 03** — Buffers & Binary Data
- **Module 04** — File System
- **Module 05** — Streams
- **Module 09** — Multi-Threading & Performance
- **Module 10** — Cryptography, Compression & Security

---

## Features to Build

- **Large file reading** — read CSV, JSON Lines, and plain text log files via `node:fs` Readable streams with configurable `highWaterMark`
- **Transform pipeline** — composable chain of Transform stream stages: parse, filter, map, aggregate
- **Gzip and Brotli compression** — compress pipeline output using `node:zlib` transform streams
- **AES-256-GCM encryption** — encrypt pipeline output with authenticated encryption via `node:crypto`
- **Worker thread distribution** — partition work across `node:worker_threads` for CPU-intensive transforms (regex extraction, aggregation)
- **Progress reporting** — emit progress events via `EventEmitter` (bytes read, rows processed, percentage complete, elapsed time)
- **JSON pipeline configuration** — define pipelines declaratively in JSON (source, transforms, output, compression, encryption)
- **Backpressure handling** — respect `highWaterMark` and `drain` events throughout the entire chain, from source to sink
- **Memory-bounded processing** — process 1GB+ files with less than 100MB of heap memory usage
- **Error recovery** — resume from the last successfully processed byte offset on failure

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     cli.js                               │
│  (parse args, load config, start pipeline, report)       │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│                   pipeline.js                            │
│                                                         │
│  ┌──────────┐                                           │
│  │  Config   │──▶ Build pipeline from JSON definition    │
│  │  Loader   │                                           │
│  └──────────┘                                           │
│                                                         │
│  Source ──▶ Transform[] ──▶ Compress ──▶ Encrypt ──▶ Sink│
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │              Stream Pipeline                       │ │
│  │                                                    │ │
│  │  ReadStream ──┬──▶ ParseTransform                  │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               │    FilterTransform                 │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               │    MapTransform                    │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               │    AggregateTransform              │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               │    ZlibCompress                    │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               │    CryptoEncrypt                   │ │
│  │               │       │                            │ │
│  │               │       ▼                            │ │
│  │               └──▶ WriteStream                     │ │
│  └────────────────────────────────────────────────────┘ │
│                                                         │
│  ┌─────────────────┐  ┌────────────────────────┐       │
│  │ Worker Pool     │  │  Progress Reporter     │       │
│  │ (CPU transforms)│  │  (EventEmitter-based)  │       │
│  └─────────────────┘  └────────────────────────┘       │
└─────────────────────────────────────────────────────────┘
```

**Pipeline configuration example (`configs/csv-to-encrypted.json`):**

```json
{
  "source": {
    "path": "./data/transactions.csv",
    "format": "csv",
    "highWaterMark": 65536
  },
  "transforms": [
    { "type": "parse", "options": { "delimiter": "," } },
    { "type": "filter", "options": { "field": "amount", "gt": 1000 } },
    { "type": "map", "options": { "select": ["id", "amount", "date"] } },
    { "type": "aggregate", "options": { "groupBy": "date", "sum": "amount" } }
  ],
  "compression": "gzip",
  "encryption": {
    "algorithm": "aes-256-gcm",
    "passphrase": "env:PIPELINE_KEY"
  },
  "output": {
    "path": "./output/summary.json.gz.enc",
    "highWaterMark": 65536
  },
  "workers": 4
}
```

---

## Deliverables

| File | Description |
|------|-------------|
| `pipeline.js` | Core pipeline engine — builds and executes stream chains from config |
| `cli.js` | CLI interface — parses arguments, loads config, runs pipeline, displays progress |
| `lib/transforms/parse.js` | Transform stream: CSV, JSON Lines, and log format parsers |
| `lib/transforms/filter.js` | Transform stream: filter rows by field conditions |
| `lib/transforms/map.js` | Transform stream: select/rename/compute fields |
| `lib/transforms/aggregate.js` | Transform stream: group-by aggregation with configurable functions |
| `lib/compress.js` | Gzip/Brotli compression wrapper using `node:zlib` |
| `lib/encrypt.js` | AES-256-GCM encryption wrapper using `node:crypto` |
| `lib/worker-pool.js` | Worker thread pool for distributing CPU-intensive transforms |
| `lib/progress.js` | EventEmitter-based progress reporter (bytes, rows, %, ETA) |
| `configs/` | Example pipeline configuration files for CSV, JSON Lines, and log formats |
| `bench/memory-benchmark.js` | Memory usage benchmark — proves <100MB for 1GB+ input |

---

## Acceptance Criteria

- [ ] Pipeline processes CSV files: parses rows, filters by condition, maps fields, aggregates results
- [ ] Pipeline processes JSON Lines files with the same composable transform chain
- [ ] Gzip compression reduces output size; decompressing produces identical data
- [ ] AES-256-GCM encryption produces authenticated ciphertext; decryption recovers original data
- [ ] Worker threads handle CPU-intensive transforms (regex extraction, aggregation) without blocking the main thread
- [ ] Progress reporter emits updates at least every 1% of file completion
- [ ] `stream.pipeline()` is used throughout; backpressure is respected at every stage
- [ ] Processing a 1GB CSV file uses less than 100MB of heap memory (verified with `process.memoryUsage()`)
- [ ] CLI accepts `--config path/to/pipeline.json` and `--verbose` flags
- [ ] Failed pipeline can resume from a checkpoint (byte offset stored on disk)
- [ ] All transforms are independent and composable — any combination works
- [ ] Zero npm packages — only `require('node:...')` imports

---

## Estimated Effort

**12-15 hours** for a developer who has completed the prerequisite modules.

| Phase | Hours |
|-------|-------|
| Pipeline engine + config loader | 2-3 |
| Transform streams (parse, filter, map, aggregate) | 3-4 |
| Compression + encryption wrappers | 1-2 |
| Worker thread pool + distribution | 2-3 |
| CLI interface + progress reporter | 1-2 |
| Memory benchmarking + optimization | 2-3 |
| Error recovery + checkpoint/resume | 1-2 |

---

## Hints

- Use `stream.pipeline()` from `node:stream/promises` for automatic error propagation and cleanup
- For the CSV parser, build a Transform stream that buffers partial lines (a `data` chunk may split mid-row)
- To verify memory usage, sample `process.memoryUsage().heapUsed` on an interval and write results to a file for graphing
- For worker thread distribution, partition line ranges and use `worker.postMessage()` / `parentPort.on('message')` for coordination
- AES-256-GCM requires a 12-byte IV (use `crypto.randomBytes(12)`) and produces an auth tag — store both alongside the ciphertext
- Generate a large test file with a simple script that writes random CSV rows in a loop using `fs.createWriteStream()`
