# SyncJobJiggle — log analysis and root cause

Covers **6,253 runs, Fri 06/05/2026 13:50 → Thu 08/20/2026 16:37**, plus the task
definition read back from the machine on 08/20.

## The task definition explains almost everything

```
Trigger    : MSFT_TaskDailyTrigger
Start      : 2025-09-17T09:00:04
Every      : PT5M      (5 minutes)
ForDuration: PT9H      (9 hours)   <-- the window closes at 18:00
StopAtEnd  : True                  <-- terminate whatever is running when it does
Triggers   : 1

MultipleInstances          : IgnoreNew
StartWhenAvailable         : True
ExecutionTimeLimit         : PT9H
DisallowStartIfOnBatteries : False
StopIfGoingOnBatteries     : False
RunOnlyIfIdle              : False
Hidden                     : True
```

**Event 111 "Task terminated" is configured behaviour, not a fault.** The
repetition is scoped to a 9-hour workday. At `start + 9h`, Task Scheduler ends
the repetition, and because *Stop all running tasks at end of repetition
duration* is set, it logs one Event 111 per day. That is the terminate event in
the History tab.

The logs confirm the window precisely — on every day the machine stayed on to the
end, the last run lands within a minute of first run + 9 h:

| Day | First run | +9 h | Last run |
|---|---|---|---|
| 07/23 | 09:00 | 18:00 | 18:00 |
| 07/27 | 09:00 | 18:00 | 18:05 |
| 08/04 | 09:10 | 18:10 | 18:11 |
| 08/05 | 09:00 | 18:00 | 18:00 |
| 08/10 | 09:05 | 18:05 | 18:08 |
| 08/18 | 09:09 | 18:09 | 18:09 |

Days that end earlier (08/11 16:30, 08/12 16:15, 08/19 15:20) end early because
the machine went away, not because the task failed.

## Not a Java problem

| Metric | Value |
|---|---|
| Runs logged | 6,253 |
| `Starting` / `Finished` | 6,253 / 6,246 |
| `exit=0` | 4,537 |
| `exit=1` | 1 |
| Java stack traces | 2 |

Every run that reached the JVM returned 0 bar one, including the most recent —
**Thu 08/20 16:37:28 → `exit=0`**. The `.bat` resolves Java through `%JAVA_HOME%`
with a `java.exe` PATH fallback, so it is already immune to version-folder
renames. Nothing to update. (The 1,708 `Finished` lines with no `exit=` predate
exit-code logging in the `.bat`.)

## The 25-hour gap on 08/19–08/20

```
Wed 08/19  15:20:06   last run   (window would have run to 18:45)
Thu 08/20  16:37:28   one run, exit=0
```

08/19's window opened late at 09:45 and so was due to run to 18:45; it stopped at
15:20. 08/20 produced a single run at 16:37. The shape is consistent with the
machine being off or asleep for that whole period, with `StartWhenAvailable`
firing the missed 09:00 start on resume at 16:37. **The logs cannot distinguish
"machine off" from "task failed to fire"** — the System power events can, which is
what `Diagnose-SyncJobJiggle.ps1` checks. Until that is confirmed, treat this gap
as unexplained rather than as a defect.

## Why some days show double the runs

One trigger, yet 244 pairs of runs land in the same minute and the interval
histogram is wrong for a 5-minute repetition:

| Gap | Count |
|---|---|
| 0 min | 244 |
| 1 min | 934 |
| 2 min | 563 |
| 3 min | 561 |
| 4 min | 1,016 |
| **5 min** | **2,868** |

On Tue 08/18 two series interleave:

```
09:09:56   09:14:26   09:19:25   09:24:25   ...   <- catch-up series
09:10:09   09:15:06   09:20:06   09:25:06   ...   <- original series
```

With a single daily trigger, this is `StartWhenAvailable`: after a sleep/resume,
the catch-up start begins its **own** repetition sequence alongside the one
already scheduled. `IgnoreNew` does not suppress it, because the two series never
overlap in time — each run lasts ~2 seconds. It resolves itself when the window
closes. Days with ~216 runs had a resume; days with ~108 did not.

This also explains days whose last run is past 18:00: the second series carries
its own 9-hour window, so 08/18's 09:09 catch-up ran to 18:09.

## `Run(..., 0, False)` hid every failure

```vb
CreateObject("WScript.Shell").Run """" & batPath & """", 0, False
```

`False` means do not wait: `wscript.exe` exits in milliseconds while `cmd.exe` and
`java.exe` keep working. The task's recorded result was therefore **always 0**,
regardless of what the jar did — which is why the `exit=1` on 06/29 and both NPEs
never appeared in Task Scheduler. `fixed/run_jiggleonce.vbs` waits and propagates
the real exit code.

With the wait in place, `ExecutionTimeLimit` finally matters: at `PT9H` a hung JVM
would sit there all day. `PT3M` kills it before the next trigger.

## Seven runs killed mid-flight

Seven `Starting` lines have no matching `Finished`, each followed immediately by a
multi-hour gap (06/10 12:45, 06/16 16:55, 06/29 11:25, 07/13 17:20, 07/17 12:20,
08/13 13:25, 08/17 14:44). The JVM was mid-jiggle when the machine suspended.
Harmless.

## `NullPointerException` at `JiggleOnce.java:5`

Twice in 6,253 runs — Tue 06/09 09:18 and Mon 06/29 17:09, the latter being the
sole `exit=1`. `MouseInfo.getPointerInfo()` returns null rather than throwing when
the workstation is locked. See `fixed/JiggleOnce-null-guard.md`.

## What is actually worth changing

| Where | Setting | Now | Change to | Why |
|---|---|---|---|---|
| Settings | `ExecutionTimeLimit` | PT9H | **PT3M** | Now that the VBS waits, a hung JVM would otherwise persist for hours |
| Triggers | *Stop all running tasks at end of repetition duration* | True | **unchecked** | Removes the daily Event 111; runs are 2 s so nothing needs killing |
| Triggers | *for a duration of* | 9 hours | leave, **or widen** | Only if you want jiggling outside 09:00–18:00 |
| VBS | `Run(..., 0, False)` | — | **`True`** | Applied — makes the task result meaningful |
| Jar | `MouseInfo.getPointerInfo()` | — | null-guard | Applied in `fixed/`, needs a rebuild |

Everything else in the definition is already correct: battery conditions off,
`RunOnlyIfIdle` false, `StartWhenAvailable` on, `Hidden` on, `IgnoreNew` set.

## Corrections to earlier notes in this repo

* The repetition duration is **9 hours by design**, not the 1-day default. The
  daily Event 111 follows from it and is expected.
* There is **one** trigger, not two. The doubled days come from
  `StartWhenAvailable` catch-up starts.
* The 102-then-111 ordering is most likely the daily end-of-window stop logged
  against the last instance, rather than orphan reaping by the fire-and-forget
  VBS. The VBS fix still stands on its own merits (exit-code propagation).
* The empty *Start in* box is harmless: the `.bat` opens with `cd /d "%~dp0"`.
* Nothing in the logs supports the OneDrive hydration theory.
