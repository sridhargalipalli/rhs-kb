# SyncJobJiggle — why it terminates, and how to make it run every 5 min silently

## What the History tab is telling us

Every row in the screenshot shares one Correlation Id (`ae1b3c13-1281-49fe-99a9-173e07278f51`),
so read it bottom-up as the life of a single run:

| Event | Meaning |
|---|---|
| 114 ⚠ | **Missed task start** — a scheduled 5-minute start never happened |
| 129 | Task Scheduler created the action's process |
| 100 | Task started |
| 200 → 201 | Action started → action completed |
| 102 | Task completed |
| **111** | **Task terminated** — Task Scheduler killed the instance |

Two things stand out:

1. **111 lands *after* 102.** The action already finished, yet Task Scheduler
   still had to terminate something. That means the process the action started
   spawned a child that outlived it (classic `cmd.exe` → `powershell.exe`, or a
   jiggle loop that never exits), and the instance was reaped later.
2. **114 is present at all.** Starts are being missed, which on a 5-minute
   repeat means either the machine was asleep/on battery, or the previous
   instance was still running and the multiple-instance rule skipped the new one.

Event 111 is *not* an error in your script. It is Task Scheduler enforcing one
of its own limits, and the event's own message text names which one.

## Ranked causes (most likely first)

1. **Repetition duration is 1 day, not indefinite.** Triggers tab → *Repeat task
   every: 5 minutes* → *for a duration of:* defaults to **1 day**. At the end of
   the day the repetition stops, and if "Stop all running tasks at end of
   repetition duration" is ticked, the running instance is **terminated → Event 111**.
   This is the single most common cause of exactly this pattern.
2. **`Stop the task if it runs longer than`** (Settings tab, default *3 days*;
   people often set 1 hour). If the jiggle action doesn't exit, it is killed on
   the timeout → Event 111 / result `0x41306`.
3. **Battery conditions.** Conditions tab defaults are *"Start the task only if
   the computer is on AC power"* **and** *"Stop if the computer switches to
   battery power"*. Unplug a laptop and you get both symptoms at once —
   missed starts (114) and terminations (111).
4. **Multiple-instance rule = "Stop the existing instance".** If a run takes
   longer than 5 minutes, the next trigger kills the previous one → 111 every cycle.
   If it's set to "Do not start a new instance" instead, you get 114 every cycle.
5. **Sleep / modern standby.** No *Wake the computer to run this task*, and no
   *Run task as soon as possible after a scheduled start is missed* → 114 on every
   trigger while the lid is shut.

## Get the actual reason (30 seconds)

The Event 111 message states the reason verbatim — "due to exceeding the time
allocated for execution", "at the end of the repetition duration", "due to the
computer switching to battery power", etc. Either click that 111 row and read the
**General** pane, or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-SyncJobJiggle.ps1
```

It prints the task definition, the trigger's repetition duration, every setting
listed above, the last-run result code, and the full text of all 111/114/101/203
events, then correlates the misses against sleep/resume events in the System log.

## The fix

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-SyncJobJiggle.ps1 -WhatIf   # preview
powershell -ExecutionPolicy Bypass -File .\Repair-SyncJobJiggle.ps1           # apply
```

It backs up the task XML first and changes only scheduling/conditions, never the
action. Equivalent manual settings:

| Tab | Setting | Value |
|---|---|---|
| Triggers | Repeat task every | 5 minutes |
| Triggers | for a duration of | **Indefinitely** |
| Triggers | Stop task if it runs longer than | **unchecked** |
| Triggers | Expire | **unchecked** |
| Conditions | Start only if on AC power | **unchecked** |
| Conditions | Stop if switches to battery | **unchecked** |
| Conditions | Start only if idle | **unchecked** |
| Settings | Stop the task if it runs longer than | **3 minutes** (short, so a hung run dies before the next trigger) |
| Settings | If the task is already running | **Do not start a new instance** |
| Settings | Run task as soon as possible after a missed start | **checked** |
| Settings | If the task fails, restart every | 1 minute, up to 3 times |

The short execution limit plus *Do not start a new instance* is the key pair: a
wedged run is cleaned up on its own schedule instead of being killed by the next
trigger, so the 111/114 alternation stops.

## Making it genuinely silent

The **Hidden** checkbox only hides the task from the Task Scheduler list — it does
not suppress the console window. For an interactive-logon task you need one of:

* **`Run-Silent.vbs`** (included) — `wscript.exe "C:\Path\Run-Silent.vbs"` as the
  action. `WScript.Shell.Run(cmd, 0, True)` gives a truly hidden window and still
  propagates the exit code back to Task Scheduler.
* **Windows 11:** `conhost.exe --headless powershell.exe -NoProfile -File script.ps1`
  — headless, no window, no flash.
* `powershell -WindowStyle Hidden` alone still flashes a window for ~100 ms.

**Do not** switch to *"Run whether user is logged on or not"* to get silence. That
runs the task in **session 0**, where it has no access to the interactive desktop —
anything doing input injection, UI automation, or session/presence work will run
and "succeed" while doing nothing. Keep *Run only when user is logged on* +
`Interactive` logon type and use the VBS/conhost shim instead.

## Files

| File | Purpose |
|---|---|
| `Check-JiggleScript.ps1` | Read-only. Validates the VBS the task launches: existence, OneDrive placeholder state, hard-coded paths, Java version drift. `-Run` executes it visibly. |
| `Diagnose-SyncJobJiggle.ps1` | Read-only. Dumps definition, settings, return codes, and the real 111/114 messages. |
| `Repair-SyncJobJiggle.ps1` | Applies the table above. Backs up first, supports `-WhatIf`. |
| `LOG-ANALYSIS.md` | Findings from 6,253 runs in jiggle_log.txt/.prev. Start here. |
| `original/` | The scripts as found on the machine, for reference. |
| `fixed/` | Corrected `.vbs` (waits, propagates exit code), hardened `.bat`, and null-guarded `JiggleOnce.java`. |

## The action being launched

```
Program : C:\Windows\System32\wscript.exe
Args    : "C:\Users\sridhar.galipalli\OneDrive - eClinicalWorks\Desktop\Sync\run_jiggleonce.vbs"
Start in: (empty)
```

Quoting is correct, so the space in `OneDrive - eClinicalWorks` is handled. Two
structural problems remain regardless of what the VBS contains:

**1. The script lives inside OneDrive.** That makes the task fragile in three
independent ways:

* **Files On-Demand** can dehydrate `run_jiggleonce.vbs` into a cloud-only
  placeholder. `wscript.exe` then blocks on a network hydration at launch — which
  looks exactly like the Event 111 termination and Event 114 missed starts, and
  would explain failing intermittently rather than always.
* OneDrive can rename it into a **conflict copy** (`run_jiggleonce-DESKTOP-XYZ.vbs`),
  leaving the task pointed at a path that no longer exists.
* **Known Folder Move** can relocate Desktop entirely, changing the path underneath
  the task.

Fix: move the script to a plain local folder such as `C:\Tools\Sync\` and repoint
the action there. Nothing about this script benefits from being synced.

**2. "Start in" is empty.** Any relative path inside the VBS — a jar, a config, a
log file — resolves against `C:\Windows\System32`, not the Sync folder. Set
*Start in* to the script's folder.

## The Java question

If the VBS shells out to a version-numbered Java path, e.g.

```vb
sh.Run """C:\Program Files\Java\jre1.8.0_401\bin\javaw.exe"" -jar jiggle.jar", 0, True
```

then every Java update renames that folder and the launch fails — silently, because
the window is hidden. `Check-JiggleScript.ps1` extracts each hard-coded path from
the VBS, tests it, inventories the Java runtimes actually installed, and flags the
mismatch.

The durable fix is to stop baking the version into the path:

```vb
Dim sh  : Set sh  = CreateObject("WScript.Shell")
Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")
Dim javaw : javaw = sh.ExpandEnvironmentStrings("%JAVA_HOME%") & "\bin\javaw.exe"
If Not fso.FileExists(javaw) Then javaw = "javaw.exe"   ' fall back to PATH
sh.Run """" & javaw & """ -jar ""C:\Tools\Sync\jiggle.jar""", 0, True
```

Note also that `sh.Run cmd, 0, False` (no wait) returns immediately, so the VBS
exits while its child keeps running. Task Scheduler logs 102 *task completed*, then
has to reap the orphan later — which is the 102-then-111 ordering seen in the
History tab. Use `True` to wait, so the task's lifetime matches the work's.
