import java.awt.*;
public class JiggleOnce {
  public static void main(String[] args) throws Exception {
    Robot r = new Robot();
    Point p = MouseInfo.getPointerInfo().getLocation();
    r.mouseMove(p.x + 1, p.y);
    Thread.sleep(50);
    r.mouseMove(p.x, p.y);
  }
}