import Cocoa
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: capture-window.swift <output.png>\n", stderr)
    exit(1)
}
let path = CommandLine.arguments[1]
let opts: CGWindowListOption = [.optionAll]
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    fputs("no window list\n", stderr)
    exit(1)
}

struct Candidate {
    let wid: Int
    let width: Double
    let height: Double
}

var best: Candidate?
for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    guard (owner == "Photocore" || owner == "photo-engine-mac"), layer == 0, height > 400, width > 600 else { continue }
    if best == nil || (width * height) > (best!.width * best!.height) {
        best = Candidate(wid: wid, width: width, height: height)
    }
}

guard let best else {
    fputs("no Photocore window\n", stderr)
    exit(2)
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
p.arguments = ["-x", "-l", "\(best.wid)", path]
try p.run()
p.waitUntilExit()
FileHandle.standardOutput.write(Data("\(path)\n".utf8))
exit(p.terminationStatus == 0 ? 0 : 3)
