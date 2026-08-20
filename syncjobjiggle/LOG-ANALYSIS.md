# Log analysis — `jiggle_log.txt` + `jiggle_log.prev`

Covers **6,253 runs from Fri 06/05/2026 13:50 to Thu 08/20/2026 16:37**.

## Headline: this is not a Java problem

| Metric | Value |
|---|---|
| Runs logged | 6,253 |
| `Starting` lines | 6,253 |
| `Finished` lines | 6,246 |
| `exit=0` | 4,537 |
| `exit=1` | 1 |
| Java stack traces | 2 |

Every run that reached the JVM returned 0, with a single exception on 06/29.
That includes the most recent run, **Thu 08/20 16:37:28 → `exit=0`**. `JAVA_HOME`
resolution in the `.bat` works, the jar loads, and it runs in ~2 seconds.
(The 1,708 `Finished` lines with no `exit=` are from an older revision of the
`.bat` that predates exit-code logging.)

So: nothing to update in Java, and nothing wrong with the two scripts that would
stop the task from running.

## The actual failure: the task stopped being triggered

```
Wed 08/19  15:20:06   ... last run
                        ← 25.3 hours of nothing
Thu 08/20  16:37:28   one run, exit=0
```

Run counts per day tell the story:

| Day | Runs | First | Last |
|---|---|---|---|
| Mon 08/17 | 218 | 08:24 | 18:00 |
| Tue 08/18 | 216 | 09:09 | 18:09 |
| **Wed 08/19** | **134** | 09:45 | **15:20** |
| **Thu 08/20** | **1** | 16:37 | 16:37 |

A normal day runs until ~18:00. On 08/19 it stopped at 15:20 mid-afternoon; on
08/20 it fired exactly once, which is the manual test run. There are **no log
lines at all** for the missing window — the `.bat` never executed, so the script
was never invoked. This is a Task Scheduler trigger problem, not a script problem.

Two candidates, both settled by one look at the Triggers tab:

1. **Repetition duration expired.** *Repeat every 5 minutes for a duration of:*
   **1 day** (the default). The repetition ends 24 h after the trigger fired, and
   with *Stop all running tasks at end of repetition duration* ticked, the live
   instance is killed — Event 111 — and nothing runs again until the trigger
   fires afresh.
2. **The machine slept at 15:20 and the trigger never re-armed on wake.** The
   first run of each day clusters at 09:00–09:10, which is the signature of an
   **At log on** trigger. Unlocking a laptop is *not* a logon, so an At-logon
   trigger does not re-fire after sleep/resume. Without *Run task as soon as
   possible after a scheduled start is missed*, the schedule simply lapses —
   which is exactly what Event 114 in the History tab reports.

Candidate 2 fits the simultaneous stop of both series (below) slightly better.
Both are fixed by the same settings change.

## Two overlapping trigger series

The interval histogram is wrong for a single 5-minute repetition:

| Gap between consecutive runs | Count |
|---|---|
| 0 min | 244 |
| 1 min | 934 |
| 2 min | 563 |
| 3 min | 561 |
| 4 min | 1,016 |
| **5 min** | **2,868** |

Zoomed in on Tue 08/18, two independent 5-minute series are interleaved:

```
09:09:56   09:14:26   09:19:25   09:24:25   09:29:26   ...   <- series A
09:10:09   09:15:06   09:20:06   09:25:06   09:30:06   ...   <- series B
```

That is why "doubled" days show ~216 runs against ~108 on single-series days, and
why 244 pairs land in the same minute. Each logon starts another repetition series
while the previous one is still alive. It also explains how the History tab
accumulated 3,799 events.

Fix: set *If the task is already running* to **Do not start a new instance**.

## Seven runs killed mid-flight

Seven `Starting` lines have no matching `Finished`. Every one is immediately
followed by a multi-hour gap:

```
Wed 06/10 12:45:33  ->  next run 15:55:08   (3.2 h)
Tue 06/16 16:55:07  ->  next run 09:10:08   (16.3 h)
Mon 06/29 11:25:07 · Mon 07/13 17:20:06 · Fri 07/17 12:20:06
Thu 08/13 13:25:06 · Mon 08/17 14:44:37
```

The JVM was mid-jiggle when the machine suspended. Harmless, and it accounts for
a handful of the Event 111s — but not for the 25-hour outage.

## `Run(..., 0, False)` in the VBS

```vb
CreateObject("WScript.Shell").Run """" & batPath & """", 0, False
```

`False` means do not wait. `wscript.exe` exits in milliseconds while `cmd.exe` and
`java.exe` keep working for ~2 seconds. Task Scheduler therefore logs **102 task
completed** almost immediately, then reaps the orphaned processes still in the
task's job object — the **102-then-111** ordering visible in the History tab. It
also means the task's recorded result is always 0 no matter what the jar did, so
`exit=1` and the two NPEs were invisible to Task Scheduler.

`fixed/run_jiggleonce.vbs` changes it to `True` and propagates the exit code.

## `NullPointerException` at `JiggleOnce.java:5`

Twice in 6,253 runs (Tue 06/09 09:18, Mon 06/29 17:09 — the latter is the sole
`exit=1`). `MouseInfo.getPointerInfo()` returns null rather than throwing when the
workstation is locked; line 5 dereferences it. See
`fixed/JiggleOnce-null-guard.md`.

## Correction to the earlier note about "Start in"

The empty *Start in* box is harmless here: `run_jiggleonce.bat` begins with
`cd /d "%~dp0"`, so `JiggleOnce.jar` and the log paths resolve against the Sync
folder regardless. Setting it is still tidy, but it was never a fault.

## What to change

| Where | Setting | Value |
|---|---|---|
| Triggers | for a duration of | **Indefinitely** |
| Triggers | Stop all running tasks at end of repetition duration | **unchecked** |
| Settings | Run task as soon as possible after a missed start | **checked** |
| Settings | If the task is already running | **Do not start a new instance** |
| Conditions | Start only if on AC power / Stop on battery | **unchecked** |
| VBS | `Run(..., 0, False)` | → `True` |
| Jar | `MouseInfo.getPointerInfo()` | null-guard it |

`Repair-SyncJobJiggle.ps1` applies every Task Scheduler row above.
