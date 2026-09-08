// Manual UI test driver for a new synthetic fixture, never user documents.
// Coordinates must be obtained from the current UI before each invocation.
import Foundation
import CoreGraphics

guard CommandLine.arguments.count == 5,
      let sx = Double(CommandLine.arguments[1]), let sy = Double(CommandLine.arguments[2]),
      let dx = Double(CommandLine.arguments[3]), let dy = Double(CommandLine.arguments[4]) else {
    fatalError("Usage: drag sourceX sourceY destinationX destinationY")
}
guard CGPreflightPostEventAccess() else { fatalError("UI event posting is not authorized") }
let source = CGEventSource(stateID: .hidSystemState)
func event(_ type: CGEventType, x: Double, y: Double) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
}
event(.mouseMoved, x: sx, y: sy)
Thread.sleep(forTimeInterval: 0.15)
event(.leftMouseDown, x: sx, y: sy)
Thread.sleep(forTimeInterval: 0.4)
for step in 1...40 {
    let fraction = Double(step) / 40
    event(.leftMouseDragged, x: sx + (dx-sx)*fraction, y: sy + (dy-sy)*fraction)
    Thread.sleep(forTimeInterval: 0.025)
}
Thread.sleep(forTimeInterval: 0.3)
event(.leftMouseUp, x: dx, y: dy)
