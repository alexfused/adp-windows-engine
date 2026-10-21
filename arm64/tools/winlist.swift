// SPDX-License-Identifier: MIT
// Lists on-screen windows whose owning process runs an executable whose path contains the given
// text (the engine folder), so only the engine's windows are ever looked at or captured.
// Output per line: windowID<TAB>pid<TAB>owner<TAB>title<TAB>WxH<TAB>layer
// Build: swiftc -O winlist.swift -o winlist      Usage: winlist <path substring>
import CoreGraphics
import Darwin
import Foundation

guard CommandLine.arguments.count > 1 else { fputs("usage: winlist <path substring>\n", stderr); exit(2) }
let needle = CommandLine.arguments[1]
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var paths: [Int: String] = [:]
func path(of pid: Int) -> String {
    if let p = paths[pid] { return p }
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
    let p = n > 0 ? String(cString: buf) : ""
    paths[pid] = p
    return p
}
for w in list {
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
    guard path(of: pid).contains(needle) else { continue }
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let id = (w[kCGWindowNumber as String] as? Int) ?? 0
    let title = (w[kCGWindowName as String] as? String) ?? ""
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any]
    let size = "\(Int((b?["Width"] as? Double) ?? 0))x\(Int((b?["Height"] as? Double) ?? 0))"
    print("\(id)\t\(pid)\t\(owner)\t\(title)\t\(size)\t\(layer)")
}
