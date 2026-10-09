# See how long a running test gate has left

The whole-suite test gate is the longest wait in a `/development:resolve-issue`
review round. How long it takes depends on how many other gates are sharing the
machine's CPUs at the same time, so an earlier run is a poor guide. The gate's
own log is a better one: `run-gate.zsh` writes every test result to stderr as it
goes, and states when it started. `gate-eta.zsh` reads that log and tells you
how many tests are done and roughly how long the rest will take.

How the results arrive depends on the gate's mode, which its start line names.
In the sequential modes they arrive one test at a time. In parallel mode
(`mode=parallel`), bats releases them one file at a time, in list order: a
file's results reach the log only once that file and every file listed before
it have finished. So in parallel mode `done` moves in jumps, and can stand still
for as long as the slowest earlier file runs.

## Capture the gate's stderr

`gate-eta.zsh` reads a file, so the gate's stderr has to land in one:

```bash
development/skills/resolve-issue/scripts/run-gate.zsh --tests-dir tests \
  > gate.json 2> gate.stderr
```

Before the suite prints its first result, `run-gate.zsh` writes its start line
there — other `run-gate:` notes, such as a shared-CPU notice or a `DEGRADED`
banner, may come before it — for example:

```text
run-gate: start epoch=1791360000 mode=parallel scope=full jobs=4
```

`jobs` is this gate's share of the CPUs. When the gate ends, its count line
also carries the run's wall time in seconds, as a trailing `wall_s=2463.512`.

## Ask how far it has got

While the gate runs, point `gate-eta.zsh` at the file:

```console
$ development/skills/resolve-issue/scripts/gate-eta.zsh --log gate.stderr
412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)
```

The estimate is linear: the time so far, scaled by the tests still to run. Run
it again whenever you want a fresh figure. It only reads the log, so it never
gets in the gate's way.

Add `--json` for one object you can feed to `jq`:

```console
$ development/skills/resolve-issue/scripts/gate-eta.zsh --log gate.stderr --json
{"done":412,"total":1830,"elapsed_s":552,"eta_s":1900,"jobs":4,"state":"running"}
```

## Read the answer

| `state` | What it means |
| ------- | ------------- |
| `no-plan` | The suite has not printed its `1..N` plan line yet, so there is no total. The line says `no plan line`. |
| `withheld` | Fewer than 5 tests, or fewer than 10% of them, are done. That is too few for a fair rate, so no time is given. The line says `ETA withheld`. In parallel mode `done` can stay at 0 until the first listed file finishes; that is normal, and the start line shows the gate has started. |
| `running` | The estimate above. It describes a log with no count line yet. A gate that was killed never prints one, so its log reads `running` for good, with `done` standing still while `elapsed` grows. In the sequential modes, if `done` has not moved between two readings, check that the gate is still alive before trusting the figure. In parallel mode, `done` standing still is normal while a file listed earlier is still running; if it stays still for longer than any one file should take, check that the gate is still alive. There `done` is a floor on the tests finished, so the estimate tends to overstate the time left, by less as the run goes on. |
| `finished` | The gate has ended: its count line is in the log, or every planned test has a result. A `done` below `total` means the suite stopped short of its plan, for example when a file's setup failed. With the count line, the elapsed time is the gate's own measured wall time, so it is the same on every reading; without it, elapsed is `unknown`. |

`unknown` and `jobs=?` mean the log does not say. A log written by an older
`run-gate.zsh`, or a TAP-only `--tap-out` file, has no start line. Give the
start yourself with `--started <epoch seconds>`, and, while the gate is still
running, the elapsed time and the estimate come back. `jobs` stays unknown.

`gate-eta.zsh` exits `0` whenever it could read the log, whatever the state. It
exits `2`, with nothing on stdout, when it is called wrongly or the log cannot
be read.
