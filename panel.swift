import AppKit
import CoreGraphics
import Darwin

func report(_ marker: String) {
    print(marker)
    fflush(stdout)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

let mode = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let sample = directory.appendingPathComponent("sample.txt")
let destination = directory.appendingPathComponent("output.txt")
let bytes = Data("sample\n".utf8)
if mode == "open" { try bytes.write(to: sample) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
DispatchQueue.main.async {
    report("constructor-started")
    let panel: NSSavePanel
    if mode == "open" {
        let open = NSOpenPanel()
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        panel = open
    } else {
        panel = NSSavePanel()
        panel.nameFieldStringValue = "output.txt"
    }
    report("constructor-returned")
    panel.directoryURL = directory
    app.activate(ignoringOtherApps: true)

    let start = Date()
    var didSeeWindow = false
    var didSendInput = false
    var didConfirm = false
    var didEscape = false
    let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
        let elapsed = Date().timeIntervalSince(start)
        if !didSeeWindow {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let onScreen = windows.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() &&
                ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber
            }
            if panel.isVisible && onScreen {
                didSeeWindow = true
                report("panel-visible-on-screen")
            }
        }
        if didSeeWindow && panel.isKeyWindow && !didSendInput && elapsed >= 1 {
            didSendInput = true
            if CGPreflightPostEventAccess() {
                report("native-key-input-posted")
                if mode == "open" { key(0, flags: .maskCommand) }
            } else {
                report("native-key-input-unavailable")
            }
        }
        if didSendInput && !didConfirm && elapsed >= 2 && panel.isKeyWindow && CGPreflightPostEventAccess() {
            didConfirm = true
            key(36)
        }
        if elapsed >= 6 && !didEscape && panel.isKeyWindow && CGPreflightPostEventAccess() {
            didEscape = true
            report("native-escape-posted")
            key(53)
        }
        if elapsed >= 9 {
            report("programmatic-dismissal-requested")
            panel.cancel(nil)
        }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    let response = panel.runModal()
    timer.invalidate()
    if response != .OK {
        report("panel-dismissed-without-confirming")
        exit(2)
    }
    report("panel-confirmed")
    if mode == "open",
       let url = panel.url, url.resolvingSymlinksInPath() == sample.resolvingSymlinksInPath(),
       (try? Data(contentsOf: url)) == bytes {
        report("open-sample-verified")
        exit(0)
    }
    if mode == "save",
       let url = panel.url, url.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath(),
       (try? bytes.write(to: url)) != nil, (try? Data(contentsOf: url)) == bytes {
        report("save-sample-verified")
        exit(0)
    }
    report("confirmed-operation-unverified")
    exit(3)
}
app.run()
