import Foundation
import CoreGraphics

struct CaptureSession: Decodable {
    let time: Double
    let phase: String
    let sleepDisabled: Bool
}

func captureRecoveryAllowed(_ session: CaptureSession?, now: Double, lidClosed: Bool, enabled: Bool) -> Bool {
    guard enabled, lidClosed, let session else { return false }
    return session.phase == "active" && session.sleepDisabled && now - session.time >= -2 && now - session.time < 8
}

// Select the screen containing most of the window. Negative screen origins are valid.
func centeredOrigin(window: CGRect, screens: [CGRect]) -> CGPoint? {
    guard window.width.isFinite, window.height.isFinite, window.minX.isFinite, window.minY.isFinite,
          window.width > 0, window.height > 0 else { return nil }
    let usable = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
    guard let screen = usable.max(by: { a, b in
        func area(_ r: CGRect) -> CGFloat { let i = r.intersection(window); return i.isNull ? 0 : i.width * i.height }
        let aa = area(a), bb = area(b)
        if aa != bb { return aa < bb }
        func distance(_ r: CGRect) -> CGFloat { pow(r.midX-window.midX, 2) + pow(r.midY-window.midY, 2) }
        return distance(a) > distance(b)
    }) else { return nil }
    // Never resize a document. An oversized window keeps its title bar reachable.
    return CGPoint(x: (screen.minX + max(0, (screen.width-window.width)/2)).rounded(),
                   y: (screen.minY + max(0, (screen.height-window.height)/2)).rounded())
}

func framesNear(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX-b.minX) <= 1 && abs(a.minY-b.minY) <= 1 && abs(a.width-b.width) <= 1 && abs(a.height-b.height) <= 1
}

// macOS exposes the sharing button label as AXTitle on the tested build.
func sharingChromeMatches(title: String?, description: String?) -> Bool {
    [title, description].compactMap { $0 }.contains { $0.caseInsensitiveCompare("Window sharing") == .orderedSame }
}
