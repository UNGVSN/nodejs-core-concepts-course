# E02: CSV Transform Pipeline

## Objective

Build a complete streaming CSV-to-JSON pipeline that reads a CSV file, parses rows into objects, filters rows by a condition, transforms field values, and writes the result as a JSON array — all without loading the entire dataset into memory. You will use `require('node:stream').pipeline()` to wire the stages together with proper error propagation and backpressure handling.

## Prerequisites

- Module 05 / Lesson 01 — Stream Fundamentals
- Module 05 / Lesson 03 — Writable Streams
- Module 05 / Lesson 04 — Backpressure Mechanics
- Module 05 / Lesson 05 — Duplex and Transform Streams
- Module 05 / Lesson 06 — Piping and Pipeline

## Instructions

1. **Generate test CSV data.** Write `generate-csv.js` that creates a file `employees.csv` with 50,000 rows and these columns: `id`, `name`, `department`, `salary`, `start_date`, `active`. Randomize values across 5 departments. Include some rows with missing fields, extra commas, and quoted fields containing commas to stress your parser.

```js
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const filePath = path.join(__dirname, 'employees.csv');
const ws = fs.createWriteStream(filePath);

const depts = ['Engineering', 'Sales', 'Marketing', 'Finance', 'Operations'];
const names = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank', 'Grace'];

ws.write('id,name,department,salary,start_date,active\n');

for (let i = 1; i <= 50000; i++) {
  const name = names[i % names.length] + ` "${i}"`;  // quoted field with comma-safe name
  const dept = depts[i % depts.length];
  const salary = 40000 + Math.floor(Math.random() * 160000);
  const year = 2010 + Math.floor(Math.random() * 15);
  const month = String(1 + Math.floor(Math.random() * 12)).padStart(2, '0');
  const active = Math.random() > 0.15 ? 'true' : 'false';
  ws.write(`${i},${name},${dept},${salary},${year}-${month}-01,${active}\n`);
}

ws.end(() => console.log('Generated employees.csv'));
```

2. **Create a `CsvParserTransform`.** Extend `require('node:stream').Transform`. This stream accepts raw text chunks, handles line splitting across chunk boundaries (reuse the remainder pattern from E01), parses the first line as headers, and emits one object per subsequent row in `objectMode`. Track `rowsParsed` and `malformedRows` counters.

```js
'use strict';

const { Transform } = require('node:stream');

class CsvParserTransform extends Transform {
  constructor() {
    super({ readableObjectMode: true });
    this.remainder = '';
    this.headers = null;
    this.rowsParsed = 0;
    this.malformedRows = 0;
  }

  _transform(chunk, encoding, callback) {
    const text = this.remainder + chunk.toString();
    const lines = text.split('\n');
    this.remainder = lines.pop();  // incomplete last line

    for (const line of lines) {
      if (!line.trim()) continue;
      if (!this.headers) {
        this.headers = this._parseLine(line);
        continue;
      }
      const fields = this._parseLine(line);
      if (fields.length !== this.headers.length) {
        this.malformedRows++;
        continue;
      }
      const obj = {};
      for (let i = 0; i < this.headers.length; i++) {
        obj[this.headers[i]] = fields[i];
      }
      this.rowsParsed++;
      this.push(obj);
    }
    callback();
  }

  _flush(callback) {
    // Process any remaining data
    if (this.remainder.trim() && this.headers) {
      const fields = this._parseLine(this.remainder);
      if (fields.length === this.headers.length) {
        const obj = {};
        for (let i = 0; i < this.headers.length; i++) {
          obj[this.headers[i]] = fields[i];
        }
        this.rowsParsed++;
        this.push(obj);
      }
    }
    callback();
  }

  _parseLine(line) {
    // Handle quoted fields — implement in step 3
  }
}
```

3. **Handle quoted CSV fields.** Implement `_parseLine(line)`. If a field starts with `"`, read until the closing `"`, allowing commas inside. A simple state machine: iterate characters, toggle an `inQuotes` flag on `"`, and only split on `,` when `inQuotes` is false. This does not need to be a full RFC 4180 parser — just handle the double-quote wrapping case.

4. **Create a `FilterTransform`.** An `objectMode` Transform stream that accepts a predicate function in its constructor. Only rows where the predicate returns `true` are passed through. Track `passed` and `rejected` counts. Filter: `active === 'true'` AND `salary >= 80000`.

```js
class FilterTransform extends Transform {
  constructor(predicate) {
    super({ objectMode: true, highWaterMark: 16 });
    this.predicate = predicate;
    this.passed = 0;
    this.rejected = 0;
  }

  _transform(obj, encoding, callback) {
    if (this.predicate(obj)) {
      this.passed++;
      callback(null, obj);
    } else {
      this.rejected++;
      callback();
    }
  }
}
```

5. **Create a `MapTransform`.** An `objectMode` Transform stream that applies a mapping function to each object. Transform: convert `salary` to a number, parse `start_date` to extract the year, add a computed `tenure_years` field (current year minus start year), and uppercase `department`.

6. **Create a `JsonStringifyWritable`.** A Writable stream in `objectMode` that writes a valid JSON array to a file. It must write `[` at the start, `,\n` between objects, and `\n]` at the end. Do not accumulate the array in memory — write each object as it arrives via the underlying file descriptor.

7. **Wire it all together with `pipeline()`.** Connect: `fs.createReadStream` -> `CsvParserTransform` -> `FilterTransform` -> `MapTransform` -> `JsonStringifyWritable`. Handle the pipeline callback for errors and completion.

```js
const fs = require('node:fs');
const { pipeline } = require('node:stream');
const path = require('node:path');

const inputPath = path.join(__dirname, 'employees.csv');
const outputPath = path.join(__dirname, 'employees.json');
const startTime = process.hrtime.bigint();

const csvParser = new CsvParserTransform();
const filter = new FilterTransform(
  (row) => row.active === 'true' && parseInt(row.salary, 10) >= 80000
);
const mapper = new MapTransform(/* ... */);
const jsonWriter = new JsonStringifyWritable(outputPath);

pipeline(
  fs.createReadStream(inputPath),
  csvParser,
  filter,
  mapper,
  jsonWriter,
  (err) => {
    if (err) { console.error('Pipeline failed:', err.message); process.exit(1); }
    const elapsed = Number(process.hrtime.bigint() - startTime) / 1e9;
    console.log(`Duration: ${elapsed.toFixed(2)}s`);
  }
);
```

8. **Print statistics.** After the pipeline finishes, report: rows parsed, malformed rows skipped, rows filtered out, rows written, bytes read, bytes written, peak heap usage, and duration.

## Break-Then-Harden Challenge

1. **Remove objectMode from one stage.** Set `objectMode: false` on the `FilterTransform` but leave the other transforms in `objectMode`. Observe the error. This teaches you that every connected objectMode stage must agree on the mode.

2. **Disable backpressure in CsvParserTransform.** Push objects in a tight loop without checking the return value of `this.push()`. Feed a 500,000-row CSV and watch memory grow. Then restore proper `_transform` flow and confirm memory stays flat.

3. **Corrupt the CSV mid-file.** Insert a line with the wrong number of columns at row 25,000. Without error handling, the pipeline crashes or produces malformed objects. Add validation in `CsvParserTransform` that emits a warning and skips malformed rows.

## Expected Output

```
Pipeline: employees.csv → employees.json
  Parsing CSV... (objectMode transforms)
  Rows parsed:     50,000
  Rows filtered:   32,847 (excluded by predicate)
  Rows written:    17,153
  Bytes read:      2,841,092
  Bytes written:   3,412,567
  Duration:        0.87s
  Peak heap:       12.4 MB

Output: employees.json (first 2 records)
[
  {"id":2,"name":"Bob \"2\"","department":"SALES","salary":142830,"start_date":"2018-07-01","active":"true","tenure_years":8},
  {"id":4,"name":"Diana \"4\"","department":"FINANCE","salary":98412,"start_date":"2015-03-01","active":"true","tenure_years":11}
]
```

## Bonus

1. **Add a `--sort <field>` flag.** Since sorting requires all filtered data, implement a `SortTransform` that buffers objects (be honest about the memory cost). Print a warning when the buffered count exceeds a threshold.

2. **Stream to `process.stdout` instead of a file.** Make the output destination configurable via `--output` flag. When set to `-`, pipe JSON to stdout so the tool composes with Unix pipes: `node pipeline.js --output - | head -20`.

## Hints

1. The `_transform(chunk, encoding, callback)` method receives one chunk at a time. Call `this.push(obj)` for each parsed row, then call `callback()` to signal you are ready for the next chunk.

2. For the JSON writable, track whether you have written the first object. If yes, prepend `,\n` before the next `JSON.stringify(obj)`. Write `[` in the constructor or `_construct` method, and `\n]` in `_final`.

3. `pipeline()` from `require('node:stream')` returns a value and accepts a callback. The callback fires with an error if any stage fails, or `null` on success. This is cleaner than chaining `.pipe()` calls, which swallow errors.

4. Splitting CSV fields naively with `line.split(',')` breaks on quoted fields. A simple state machine: iterate characters, toggle an `inQuotes` flag on `"`, and only split on `,` when `inQuotes` is false.

5. Set `{ objectMode: true, highWaterMark: 16 }` on your Transform streams. The `highWaterMark` in objectMode counts objects, not bytes — 16 means buffer up to 16 objects before applying backpressure.
