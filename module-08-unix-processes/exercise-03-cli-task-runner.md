# E03: CLI Task Runner

## Objective

Build a mini `make` / task runner that reads task definitions from a JSON configuration file, resolves task dependencies into an execution order, spawns child processes for each task, runs independent tasks in parallel, and reports success or failure. This exercise combines dependency graph resolution with child process management.

## Prerequisites

- Module 08 / Lesson 03 — Child Processes (exec)
- Module 08 / Lesson 04 — Child Processes (spawn, fork)
- Module 04 / Lesson 03 — Reading Files

## Instructions

1. Create a file called `task-runner.js`. Add `'use strict';` at the top. Require `node:child_process`, `node:fs`, and `node:path`.

2. Create a `tasks.json` configuration file with this structure:
   ```json
   {
     "tasks": {
       "clean": {
         "command": "rm -rf dist",
         "description": "Remove build artifacts"
       },
       "lint": {
         "command": "echo 'Linting source files...' && sleep 1 && echo 'Lint passed'",
         "description": "Run linter",
         "depends": []
       },
       "compile": {
         "command": "echo 'Compiling TypeScript...' && sleep 2 && echo 'Build complete'",
         "description": "Compile source code",
         "depends": ["clean", "lint"]
       },
       "test": {
         "command": "echo 'Running tests...' && sleep 1 && echo '42 tests passed'",
         "description": "Run test suite",
         "depends": ["compile"]
       },
       "deploy": {
         "command": "echo 'Deploying to production...' && sleep 1 && echo 'Deployed v1.0'",
         "description": "Deploy the application",
         "depends": ["test"]
       }
     }
   }
   ```

3. Write a function `loadConfig(filePath)` that reads and parses the JSON file. Validate that every task referenced in a `depends` array actually exists in the config. Throw a clear error if a dependency is missing.

4. Write a function `topologicalSort(tasks, target)` that performs a topological sort on the dependency graph starting from the target task. Return an array of task names in execution order. Detect circular dependencies and throw an error if found (use a visited/visiting state approach).

5. Write a function `findParallelGroups(sortedTasks, taskDefs)` that groups tasks into "waves" — tasks within the same wave have no dependencies on each other and can run in parallel. For example, if `compile` depends on both `clean` and `lint`, then `clean` and `lint` are in wave 1 and `compile` is in wave 2.

6. Write a function `runTask(name, command)` that spawns the command using `child_process.spawn` with `{ shell: true }`. Capture stdout and stderr. Return a Promise that resolves with `{ name, exitCode, stdout, stderr, duration }`. Measure duration with `process.hrtime.bigint()`.

7. Write the main execution function `runPipeline(groups)`:
   - Iterate over each wave sequentially.
   - Within each wave, run all tasks in parallel using `Promise.all`.
   - If any task in a wave fails (non-zero exit), abort the pipeline immediately. Do not start subsequent waves.
   - Log each task's start, completion (with duration), and any output.

8. Format the output with clear visual markers:
   ```
   ─── Wave 1 (parallel) ───────────────────
   [clean]   ✓ done in 0.05s
   [lint]    ✓ done in 1.02s
   ─── Wave 2 ──────────────────────────────
   [compile] ✓ done in 2.01s
   ─── Wave 3 ──────────────────────────────
   [test]    ✓ done in 1.03s
   ─── Wave 4 ──────────────────────────────
   [deploy]  ✓ done in 1.01s
   ─────────────────────────────────────────
   Pipeline complete: 5 tasks in 5.12s
   ```
   (Use ASCII characters for the checkmark: write `done` or `PASS` instead of emoji.)

9. Accept the target task name as a CLI argument:
   ```bash
   node task-runner.js deploy          # runs clean -> lint -> compile -> test -> deploy
   node task-runner.js compile         # runs clean -> lint -> compile only
   node task-runner.js --config other.json test  # use alternate config
   ```

10. Add a `--dry-run` flag that prints the execution plan (waves and tasks) without actually running anything. Add a `--list` flag that prints all available tasks with their descriptions and dependencies.

## Break-Then-Harden Challenge

1. **Circular dependency.** Add `"depends": ["deploy"]` to the `clean` task, creating a cycle. Observe your runner either hanging forever or crashing with a stack overflow. Fix it by implementing proper cycle detection in `topologicalSort` using a three-state coloring (white/gray/black). Report the exact cycle path in the error message.

2. **Task timeout.** Replace one task's command with `sleep 60`. Observe the runner hanging. Fix it by adding a per-task timeout (default 30 seconds). If a task exceeds its timeout, kill the child process and fail the pipeline with a clear timeout error.

3. **Command injection.** If your runner passes task names or arguments directly into a shell command, a malicious `tasks.json` could contain `"command": "rm -rf /"`. Verify that commands are only read from the trusted config file and that user-supplied CLI arguments (like the target task name) are never interpolated into shell commands.

## Expected Output

```
$ node task-runner.js deploy

Loading tasks from tasks.json...
Resolving dependency graph for target: deploy
Execution plan: clean, lint -> compile -> test -> deploy

─── Wave 1 (parallel) ───────────────────
  [clean]    starting: rm -rf dist
  [lint]     starting: echo 'Linting source files...' && sleep 1 && echo 'Lint passed'
  [clean]    PASS (0.05s)
  [lint]     PASS (1.02s)
─── Wave 2 ──────────────────────────────
  [compile]  starting: echo 'Compiling TypeScript...' && sleep 2 && echo 'Build complete'
  [compile]  PASS (2.01s)
─── Wave 3 ──────────────────────────────
  [test]     starting: echo 'Running tests...' && sleep 1 && echo '42 tests passed'
  [test]     PASS (1.03s)
─── Wave 4 ──────────────────────────────
  [deploy]   starting: echo 'Deploying to production...' && sleep 1 && echo 'Deployed v1.0'
  [deploy]   PASS (1.01s)
─────────────────────────────────────────
Pipeline complete: 5 tasks in 5.12s

$ node task-runner.js --list

Available tasks:
  clean     Remove build artifacts
  lint      Run linter
  compile   Compile source code          [depends: clean, lint]
  test      Run test suite               [depends: compile]
  deploy    Deploy the application       [depends: test]

$ node task-runner.js --dry-run deploy

Dry run — execution plan for: deploy
  Wave 1: clean, lint (parallel)
  Wave 2: compile
  Wave 3: test
  Wave 4: deploy
  Total: 5 tasks in 4 waves
```

## Bonus

1. Add task output caching: hash each task's command and its dependency outputs. If nothing changed since the last run, skip the task and print `[cached]`. Store hashes in a `.task-cache.json` file.

2. Implement environment variable support in task commands: allow `${ENV_VAR}` syntax in command strings and expand them from `process.env` before execution.

## Hints

1. Topological sort with cycle detection: maintain `visiting` (gray) and `visited` (black) sets. If you encounter a node that is in `visiting`, you have found a cycle.
2. To find parallel groups, compute the "depth" of each task (longest path from any root). Tasks at the same depth can run in parallel.
3. `child_process.spawn(command, [], { shell: true })` lets you run shell commands with pipes and `&&` chains.
4. `Promise.all` rejects on the first failure — catch individual task promises and collect results to report which specific task failed.
5. `process.hrtime.bigint()` returns nanoseconds. Divide by `1e9` for seconds, or `1e6` for milliseconds.
