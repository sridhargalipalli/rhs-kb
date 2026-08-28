# SyncJobJiggle — handoff brief

Paste this whole file into a new Claude session (Cowork or otherwise), or hand it
to a colleague. It is self-contained: everything needed to pick the work up cold.

## What it is

A Windows scheduled task, `\SyncJobJiggle`, that nudges the mouse pointer one
pixel every 5 minutes so the workstation does not read as idle.

```
Task Scheduler  \SyncJobJiggle
    trigger : daily 09:00:04, repeat every 5 min, ForDuration = PT9H
    settings: ExecutionTimeLimit PT3M, MultipleInstances IgnoreNew,
              StartWhenAvailable True, Hidden True, RunOnlyIfIdle False
        |
        v
wscript.exe "C:\Tools\Sync\run_jiggleonce.vbs"     hidden window, WAITS for the bat
        |
        v
C:\Tools\Sync\run_jiggleonce.bat                   rotates + writes jiggle_log.txt at 1 MB
        |
        v
java -jar C:\Tools\Sync\JiggleOnce.jar             ~2 s, moves the cursor 1px and back
```

Runs on `sridhar.galipalli`'s machine, interactive logon (it must reach the
desktop — a session-0 task cannot inject input).

## The failure that prompted this work

On 08/19 the task went silent from 15:20 until the next day while the machine was
awake. Root cause, confirmed from `Microsoft-Windows-TaskScheduler/Operational`:

* `15:24:42` an instance started and **hung before writing its first log line** —
  no Event 102, no log entry.
* `MultipleInstances = IgnoreNew` then suppressed every trigger behind it.
* `ExecutionTimeLimit` was `PT9H`, so nothing would have reaped it until 00:24.
* `22:20:38` Event 111 — the sleep transition finally killed it, ~7 hours later.

One hung instance cost the entire afternoon, silently.

## Fixes applied 08/20

| Change | Why |
|---|---|
| `ExecutionTimeLimit` PT9H -> **PT3M** | The actual fix. A hang now costs one cycle. |
| VBS `Run(..., 0, False)` -> **`True`** | Fire-and-forget pinned the task result to 0 forever, hiding every failure. |
| Folder moved OneDrive -> **`C:\Tools\Sync`** | The hang preceded the first log write, i.e. in the launch path, all of which touched OneDrive. Suggestive, not proven. |
| `.bat` hardened | Missing-jar guard, best-effort `msg.exe`, exits with the jar's code. |
| `JiggleOnce.jar` rebuilt | Null-guards `MouseInfo.getPointerInfo()`, which returns null (not throws) on a locked workstation. Built `--release 8`; the machine has a JRE but no `javac`. |

Verified 08/20: runs at 18:23, 18:33, 18:35, 18:47 all `exit=0`,
`LastTaskResult : 0`, OneDrive copy dormant, one task, clean Startup folder.

## How to check it

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\Sync\Check-Health.ps1
```

Prints PASS/WARN/FAIL lines and a verdict. Expect `HEALTHY`.

## Known, accepted, not bugs

* **One Event 111 per day** at the end of the 9-hour window. `StopAtDurationEnd`
  is True; runs take 2 s so there is never anything to kill. Cosmetic only.
* **Event 114 "Missed start" every 5 minutes**, each immediately followed by a
  100 Started. That is `StartWhenAvailable` catch-up after a resume, which begins
  its own repetition series. It doubles the run rate for the rest of the day and
  resolves when the window closes.
* **Late boots are fine.** The window runs 9 hours from the first actual run, not
  from 09:00, so booting at 09:30 gives roughly 09:32-18:32.

## If it breaks again

1. Run `Check-Health.ps1` first.
2. A gap of a few minutes with a non-zero `LastTaskResult` = a hang that PT3M
   correctly reaped. Normal.
3. A gap of hours = check `Microsoft-Windows-TaskScheduler/Operational` for a
   100 Started with no matching 102, and the System log for sleep/resume around
   the same time. That distinguishes "machine was off" from "instance hung".
4. `Diagnose-SyncJobJiggle.ps1` in this folder dumps all of that at once.

## Repo

`sridhargalipalli/rhs-kb`, branch `claude/syncjobjiggle-silent-mode-zr3k7t`,
folder `syncjobjiggle/`. `LOG-ANALYSIS.md` has the full evidence trail from 6,253
logged runs. `original/` and `fixed/` hold the before and after scripts.
