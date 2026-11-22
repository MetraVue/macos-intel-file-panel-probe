import AppKit
import ApplicationServices
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

func selectOpenFile(pid: pid_t) -> Bool {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
        report("open-input-unavailable")
        return false
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    let desktop = AXUIElementCreateSystemWide()

    func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success ? result : nil
    }

    let until = Date().addingTimeInterval(10)
    while Date() < until {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            var nodes = attribute(app, "AXWindows") as? [AXUIElement] ?? []
            var visited = 0
            while let node = nodes.popLast(), visited < 1000 {
                visited += 1
                nodes.append(contentsOf: attribute(node, "AXChildren") as? [AXUIElement] ?? [])
                let name = ["AXTitle", "AXValue", "AXDescription"].compactMap { attribute(node, $0) as? String }
                guard name.contains("sample.txt") || name.contains("sample"),
                      let position = attribute(node, "AXPosition"), let size = attribute(node, "AXSize"),
                      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
                else { continue }
                var origin = CGPoint.zero
                var extent = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(size as! AXValue, .cgSize, &extent),
                      extent.width > 0, extent.height > 0 else { continue }
                let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
                var hit: AXUIElement?
                var owner: pid_t = 0
                guard AXUIElementCopyElementAtPosition(desktop, Float(point.x), Float(point.y), &hit) == .success,
                      let hit, AXUIElementGetPid(hit, &owner) == .success, owner == pid else { continue }
                for count in [1, 2] {
                    for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
                        let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)
                        event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                        event?.post(tap: .cghidEventTap)
                    }
                    Thread.sleep(forTimeInterval: 0.09)
                }
                report("native-open-file-click-posted")
                return true
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    report("open-file-row-unavailable")
    return false
}

let mode = CommandLine.arguments[1]
if mode == "select-open" {
    guard let pid = pid_t(CommandLine.arguments[2]) else { exit(4) }
    exit(selectOpenFile(pid: pid) ? 0 : 4)
}
let confirmOpen = mode == "confirm-open"
let isOpen = mode == "open" || confirmOpen
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let sample = directory.appendingPathComponent("sample.txt")
let destination = directory.appendingPathComponent("output.txt")
let bytes = Data((confirmOpen ? UUID().uuidString : "sample\n").utf8)
if isOpen { try bytes.write(to: sample) }

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
        if elapsed >= (confirmOpen ? 13 : 9) {
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
    if isOpen,
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
