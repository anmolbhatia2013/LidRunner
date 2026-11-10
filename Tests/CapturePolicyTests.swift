import Foundation
import CoreGraphics
@main struct Tests {
 static func main() {
  var checks = 0
  func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1 }
  let active = CaptureSession(time: 100, phase: "active", sleepDisabled: true)
  check(captureRecoveryAllowed(active, now: 101, lidClosed: true, enabled: true), "active closed session")
  check(!captureRecoveryAllowed(active, now: 108, lidClosed: true, enabled: true), "stale session")
  check(!captureRecoveryAllowed(active, now: 97, lidClosed: true, enabled: true), "future timestamp")
  check(!captureRecoveryAllowed(active, now: 101, lidClosed: false, enabled: true), "open lid")
  check(!captureRecoveryAllowed(active, now: 101, lidClosed: true, enabled: false), "paused")
  check(!captureRecoveryAllowed(nil, now: 101, lidClosed: true, enabled: true), "missing session")
  check(!captureRecoveryAllowed(CaptureSession(time: 100, phase: "stopped", sleepDisabled: true), now: 101, lidClosed: true, enabled: true), "stopped session")
  check(!captureRecoveryAllowed(CaptureSession(time: 100, phase: "active", sleepDisabled: false), now: 101, lidClosed: true, enabled: true), "no power override")
  let main = CGRect(x: 0, y: 30, width: 1728, height: 1087)
  let w = CGRect(x: 544, y: 371, width: 674, height: 408)
  check(centeredOrigin(window: w, screens: [main]) == CGPoint(x:527,y:370), "center scientific calculator")
  let left = CGRect(x: -1920, y:0, width:1920, height:1080)
  check(centeredOrigin(window: CGRect(x:-1800,y:200,width:600,height:400), screens:[main,left]) == CGPoint(x:-1260,y:340), "negative display origin")
  check(centeredOrigin(window: CGRect(x:9000,y:200,width:600,height:400), screens:[main,left]) == CGPoint(x:564,y:374), "offscreen chooses nearest")
  check(centeredOrigin(window: CGRect(x:0,y:0,width:3000,height:2000), screens:[main]) == main.origin, "oversized never hidden title")
  check(centeredOrigin(window: w, screens:[]) == nil, "missing displays")
  check(centeredOrigin(window: .zero, screens:[main]) == nil, "invalid window")
  check(framesNear(w,w.offsetBy(dx:0.5,dy:0.5)), "rounding tolerance")
  check(!framesNear(w,w.offsetBy(dx:0,dy:10)), "real movement")
  check(sharingChromeMatches(title:"Window sharing",description:nil), "sharing label in title")
  check(sharingChromeMatches(title:nil,description:"Window Sharing"), "sharing label in description")
  check(!sharingChromeMatches(title:"Window",description:nil), "unrelated menu")
  check(!sharingChromeMatches(title:nil,description:nil), "missing chrome")
  print("\(checks) capture recovery policy checks passed")
 }
}
