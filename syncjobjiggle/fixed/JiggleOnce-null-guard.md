# `java.lang.NullPointerException at JiggleOnce.main(JiggleOnce.java:5)`

Seen twice in 6,253 runs (Tue 06/09 09:18, Mon 06/29 17:09). Rare, but it is a
real defect rather than a transient.

Line 5 of a jiggler's `main` is almost always this:

```java
Point p = MouseInfo.getPointerInfo().getLocation();
```

`MouseInfo.getPointerInfo()` returns **null** — it does not throw — when the JVM
has no reachable pointer device: the workstation is locked, the session is
disconnected, or the screen saver is in a secure state. Dereferencing the null
result is the NPE. Both timestamps are consistent with a locked screen.

Guard it and exit cleanly, so a locked session logs a skip instead of a stack
trace and a non-zero exit code:

```java
public static void main(String[] args) throws Exception {
    PointerInfo info = MouseInfo.getPointerInfo();
    if (info == null) {
        System.out.println("No pointer info (session locked or disconnected) - skipping.");
        return;                       // exit 0: nothing to do, not a failure
    }
    Point p = info.getLocation();
    Robot robot = new Robot();
    robot.mouseMove(p.x + 1, p.y);
    robot.mouseMove(p.x, p.y);
}
```

`new Robot()` throws `AWTException` in a headless or session-0 context, which is
the other reason to keep the task running as *Run only when user is logged on*.
