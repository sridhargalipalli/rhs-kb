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

## Root cause of the 08/19-08/20 outage: one hung instance

Confirmed from `Microsoft-Windows-TaskScheduler/Operational` and the System
power log.

```
08/19 15:20:05   100 Started        -> logged normally, exit=0
08/19 15:24:42   114 + 100 Started  -> NO log line ever written   <-- hung here
                 (nothing for 7 hours; the machine was awake throughout)
08/19 22:20:38   111 Terminated     -> killed by the sleep transition at 22:20:46
08/20 09:09:09     1 Resume
08/20 16:37:27   100 Started        -> manual run while investigating
```

The instance started at 15:24:42 never wrote a line to `jiggle_log.txt` (the last
08/19 entry is 15:20:06) and never produced an Event 102. Task Scheduler held it
as *running* for six hours and fifty-six minutes.

That single hang took out the rest of the day, because of two settings acting
together:

* **`MultipleInstances = IgnoreNew`** suppressed every trigger from 15:25 onward
  while the stuck instance was still nominally running.
* **`ExecutionTimeLimit = PT9H`** meant Task Scheduler would not have reaped it
  until 00:24:42. It never got that far — sleep terminated it first.

The power log rules out the machine being off: it booted 08/19 09:43 (matching the
first jiggle run at 09:45) and did not sleep until 22:20.

**Where the hang was.** The `.bat` writes its `Triggered` line *before* launching
Java, and that line is absent, so the hang happened earlier than the JVM — in
wscript launching cmd, or in cmd's first append to `jiggle_log.txt`. Every step in
that path touched the OneDrive-backed folder, the only component there capable of
blocking on network I/O. Strongly suggestive, not proven.

## Resolution applied 08/20

| Change | Effect |
|---|---|
| `ExecutionTimeLimit` PT9H -> **PT3M** | A hang is now reaped after 3 minutes, so it costs one cycle instead of an afternoon. This is the fix for the outage above. |
| VBS `Run(..., 0, False)` -> **`True`** | The task result is no longer pinned to 0, so failures become visible. |
| Folder moved to **`C:\Tools\Sync`** | Removes OneDrive from the launch path entirely. |
| `.bat` hardened | Missing-jar guard, best-effort `msg.exe`, exits with the jar's code. |
| `JiggleOnce.jar` rebuilt | Null-guards `MouseInfo.getPointerInfo()`. Built with `--release 8` (class version 52) because the machine has a JRE but no `javac`. |

Verified on 08/20: runs at 18:23, 18:33, 18:35 and 18:47 all `exit=0`, `LastTaskResult : 0`,
log writing to `C:\Tools\Sync`, OneDrive copy dormant, exactly one task
referencing the jiggler, nothing in Startup.

Still open, and purely cosmetic: the daily Event 111 at the end of the 9-hour
window, from `StopAtDurationEnd = True`. Runs take two seconds, so there is never
anything to terminate when the window closes.

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
sole `exit=1`. Confirmed against the source: line 5 is

```java
Point p = MouseInfo.getPointerInfo().getLocation();
```

`MouseInfo.getPointerInfo()` returns null rather than throwing when the
workstation is locked or the session is disconnected. `fixed/JiggleOnce.java`
guards it and returns 0, and moves `new Robot()` below the check.

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
