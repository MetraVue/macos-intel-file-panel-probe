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

func keyboardOpen(pid: pid_t, path: String) -> Bool {
    report("keyboard-driver-started")
    guard CGPreflightPostEventAccess() else {
        report("keyboard-input-unavailable")
        return false
    }

    func send(_ code: CGKeyCode, flags: CGEventFlags = [], character: UniChar? = nil) {
        for pressed in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed) else { continue }
            event.flags = flags
            if var character { event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character) }
            event.post(tap: .cghidEventTap)
        }
    }

    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        report("keyboard-target-not-frontmost")
        return false
    }
    report("keyboard-target-frontmost")
    send(5, flags: [.maskCommand, .maskShift])
    report("go-to-shortcut-posted")
    Thread.sleep(forTimeInterval: 1.5)
    send(0, flags: .maskCommand)
    for character in path.utf16 {
        send(0, character: character)
        Thread.sleep(forTimeInterval: 0.015)
    }
    report("absolute-path-posted")
    Thread.sleep(forTimeInterval: 1.8)
    send(36)
    report("go-to-return-posted")
    Thread.sleep(forTimeInterval: 2.0)
    send(36)
    report("open-return-posted")
    return true
}

let mode = CommandLine.arguments[1]
if mode == "keyboard-open" {
    guard let pid = pid_t(CommandLine.arguments[2]) else { exit(4) }
    exit(keyboardOpen(pid: pid, path: CommandLine.arguments[3]) ? 0 : 4)
}
let confirmOpen = mode == "confirm-open"
let isOpen = mode == "open" || confirmOpen
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let filename = confirmOpen ? CommandLine.arguments[3] : "sample.txt"
let sample = directory.appendingPathComponent(filename)
let destination = directory.appendingPathComponent("output.txt")
let bytes = Data((confirmOpen ? UUID().uuidString : "sample\n").utf8)
if isOpen { try bytes.write(to: sample) }
let initialDirectory = confirmOpen ? directory.appendingPathComponent("empty", isDirectory: true) : directory
if confirmOpen {
    try FileManager.default.createDirectory(at: initialDirectory, withIntermediateDirectories: false)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
DispatchQueue.main.async {
    report("constructor-started")
    let panel: NSSavePanel
    if isOpen {
        let open = NSOpenPanel()
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        panel = open
    } else {
        panel = NSSavePanel()
        panel.nameFieldStringValue = "output.txt"
    }
    report("constructor-returned")
    panel.directoryURL = initialDirectory
    app.activate(ignoringOtherApps: true)

    let start = Date()
    var didSeeWindow = false
    var didSeeKeyWindow = false
    var keyWindowPresent = false
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
        if confirmOpen && didSeeWindow && panel.isKeyWindow && !didSeeKeyWindow {
            didSeeKeyWindow = true
            keyWindowPresent = true
            report("open-panel-key")
        }
        if confirmOpen && didSeeKeyWindow && keyWindowPresent != panel.isKeyWindow {
            keyWindowPresent = panel.isKeyWindow
            report(keyWindowPresent ? "open-panel-key-restored" : "open-panel-key-lost")
        }
        if !confirmOpen && didSeeWindow && panel.isKeyWindow && !didSendInput && elapsed >= 1 {
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
        if !confirmOpen && elapsed >= 6 && !didEscape && panel.isKeyWindow && CGPreflightPostEventAccess() {
            didEscape = true
            report("native-escape-posted")
            key(53)
        }
        if !confirmOpen && elapsed >= 9 {
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
    if isOpen {
        guard let url = panel.url, url.resolvingSymlinksInPath() == sample.resolvingSymlinksInPath() else {
            report("open-selected-url-mismatch")
            exit(3)
        }
        report("open-selected-url-verified")
        guard (try? Data(contentsOf: url)) == bytes else {
            report("open-sample-read-mismatch")
            exit(3)
        }
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
