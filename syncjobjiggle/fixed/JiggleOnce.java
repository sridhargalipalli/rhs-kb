import java.awt.*;

public class JiggleOnce {
  public static void main(String[] args) throws Exception {
    // MouseInfo.getPointerInfo() returns null -- it does not throw -- when the
    // workstation is locked or the session is disconnected. The original line 5
    // dereferenced it directly, which is the NullPointerException seen twice in
    // 6,253 runs (06/09 09:18 and 06/29 17:09, the latter the sole exit=1).
    PointerInfo info = MouseInfo.getPointerInfo();
    if (info == null) {
      System.out.println("No pointer info (session locked) - skipping.");
      return;                       // exit 0: nothing to do, not a failure
    }
    Point p = info.getLocation();
    Robot r = new Robot();          // constructed only once there is work to do
    r.mouseMove(p.x + 1, p.y);
    Thread.sleep(50);
    r.mouseMove(p.x, p.y);
  }
}

// Built for distribution with:
//   javac --release 8 -d out JiggleOnce.java
//   jar cfm JiggleOnce.jar manifest.txt -C out .
// Class file major version 52 (Java 8), so it runs on any JRE 8 or newer.
