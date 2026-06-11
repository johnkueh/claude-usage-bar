import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var usage: [String: UsageState] = [:]
    var lastRefresh: Date?
    var refreshing = false
    var menuOpen = false
    var unknownLoginEmail: String?
    let defaults = UserDefaults.standard

    var autopilotOn: Bool {
        get { defaults.bool(forKey: "autopilot") }
        set { defaults.set(newValue, forKey: "autopilot") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.delegate = self
        if let button = statusItem.button {
            button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            button.imagePosition = .imageTrailing
            button.title = "·"
        }
        rebuildMenu()
        refresh()

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }

        // Verification hook: DEBUG_SHOOT=1 renders the status item and the open
        // menu to PNGs in /tmp by capturing the app's own windows (no Screen
        // Recording permission needed), then quits.
        if ProcessInfo.processInfo.environment["DEBUG_SHOOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.debugShoot() }
        }
        // DEBUG_SWITCH=<name> exercises the real switch path then quits.
        if let target = ProcessInfo.processInfo.environment["DEBUG_SWITCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.performSwitch(to: target, reason: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        }
    }

    func debugShoot() {
        // Offscreen capture can't reproduce vibrant menu/system text, so render
        // the exact drawing primitives with a forced appearance — the same
        // pixels the menu bar composites — at 3x for legibility.
        func savePNG(_ draw: @escaping (NSRect) -> Void, size: NSSize,
                     appearance: NSAppearance.Name, background: NSColor, to path: String) {
            let scale: CGFloat = 3
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let rect = NSRect(origin: .zero, size: size)
                background.setFill()
                rect.fill()
                draw(rect)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }

        let active = AccountStore.activeAccount()
        let state = active.flatMap { usage[$0] }
        var stale = false
        if case .stale = state { stale = true }

        let statusImage = Render.statusText(state?.usage, stale: stale)
        let pad: CGFloat = 6
        let statusSize = NSSize(width: statusImage.size.width + pad * 2, height: 24)
        savePNG({ rect in
            statusImage.draw(at: NSPoint(x: pad, y: (rect.height - statusImage.size.height) / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
        }, size: statusSize, appearance: .darkAqua,
           background: NSColor(calibratedWhite: 0.1, alpha: 1), to: "/tmp/cub-status-dark.png")
        savePNG({ rect in
            statusImage.draw(at: NSPoint(x: pad, y: (rect.height - statusImage.size.height) / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
        }, size: statusSize, appearance: .aqua,
           background: NSColor(calibratedWhite: 0.93, alpha: 1), to: "/tmp/cub-status-light.png")

        for (index, name) in AccountStore.accounts().enumerated() {
            let title = Render.accountTitle(name: name, state: usage[name])
            let size = NSSize(width: title.size().width + 24, height: title.size().height + 12)
            savePNG({ _ in
                title.draw(at: NSPoint(x: 12, y: 6))
            }, size: size, appearance: .darkAqua,
               background: NSColor(calibratedWhite: 0.16, alpha: 1), to: "/tmp/cub-row-\(index)-\(name).png")
        }
        let dump = menu.items.map { item -> String in
            if item.isSeparatorItem { return "---" }
            let text = (item.attributedTitle?.string ?? item.title).replacingOccurrences(of: "\n", with: " ⏎ ")
            let state = item.state == .on ? " [✓]" : ""
            let sub = item.submenu.map { " ▸ [" + $0.items.map(\.title).joined(separator: " | ") + "]" } ?? ""
            return text + state + sub
        }.joined(separator: "\n")
        try? dump.write(toFile: "/tmp/cub-menu.txt", atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    // MARK: - Refresh

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let names = AccountStore.accounts()
        let active = AccountStore.activeAccount()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var result: [String: UsageState] = [:]
            var liveEmail: String?

            for name in names {
                guard let token = AccountStore.token(for: name) else {
                    result[name] = self.fallback(name, "no token")
                    continue
                }
                let (usage, error) = UsageAPI.fetchUsage(token: token)
                if let usage {
                    result[name] = .fresh(usage)
                    UsageCache.save(name, usage)
                } else {
                    result[name] = self.fallback(name, error)
                }
                if name == active, case .fresh = result[name]! {
                    liveEmail = UsageAPI.fetchEmail(token: token)
                }
            }

            DispatchQueue.main.async {
                self.usage = result
                self.lastRefresh = Date()
                self.refreshing = false
                self.reconcileEmail(liveEmail, active: active)
                self.updateStatusButton()
                self.rebuildMenu()
                self.runAutopilot()
            }
        }
    }

    func fallback(_ name: String, _ reason: String) -> UsageState {
        if let cached = UsageCache.load(name) { return .stale(cached, reason) }
        return .unavailable(reason == "token expired" ? "token expired — switch once to refresh" : reason)
    }

    // Detect a login the app doesn't know: the live credential's email differs
    // from every email we've seen. Offer to save it as a new account.
    func reconcileEmail(_ liveEmail: String?, active: String?) {
        guard let liveEmail, let active else { return }
        let knownEmails = AccountStore.accounts().compactMap { defaults.string(forKey: "email-\($0)") }
        let activeEmail = defaults.string(forKey: "email-\(active)")
        if activeEmail == nil || activeEmail == liveEmail {
            defaults.set(liveEmail, forKey: "email-\(active)")
            unknownLoginEmail = nil
        } else if knownEmails.contains(liveEmail) {
            unknownLoginEmail = nil   // a known account logged in outside the app; not new
        } else {
            unknownLoginEmail = liveEmail
        }
    }

    // MARK: - Status bar (statusline format: S:NN%/<reset> over W:NN%/<reset>)

    func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let active = AccountStore.activeAccount()
        let state = active.flatMap { usage[$0] }
        var stale = false
        if case .stale = state { stale = true }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = Render.statusText(state?.usage, stale: stale)
        if let u = state?.usage {
            button.toolTip = String(format: "%@ — 5h %.0f%%, wk %.0f%%", active ?? "?", u.fiveHourPct, u.sevenDayPct)
        } else {
            button.toolTip = "Claude Usage — no data yet"
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    func rebuildMenu() {
        // While the menu is tracking, update rows in place; a full rebuild
        // would yank items out from under the highlight.
        if menuOpen {
            updateOpenMenu()
            return
        }
        menu.removeAllItems()
        let active = AccountStore.activeAccount()

        if let email = unknownLoginEmail {
            let item = NSMenuItem(title: "New login detected — save \(email)…",
                                  action: #selector(addAccount), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        for name in AccountStore.accounts() {
            let item = NSMenuItem(title: name, action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.attributedTitle = Render.accountTitle(name: name, state: usage[name])
            item.state = name == active ? .on : .off
            item.toolTip = name == active
                ? (defaults.string(forKey: "email-\(name)") ?? "Active account")
                : "Switch to \(name)"
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let autopilot = NSMenuItem(title: "Autopilot", action: #selector(toggleAutopilot), keyEquivalent: "")
        autopilot.target = self
        autopilot.state = autopilotOn ? .on : .off
        autopilot.toolTip = defaults.string(forKey: "autopilot-last-reason")
            ?? "Auto-switch to the account with more headroom when this one runs hot"
        menu.addItem(autopilot)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        if let lastRefresh { refreshItem.toolTip = "Updated \(Render.shortTime(lastRefresh))" }
        menu.addItem(refreshItem)

        let manage = NSMenuItem(title: "Manage Accounts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccount), keyEquivalent: "")
        add.target = self
        sub.addItem(add)
        for name in AccountStore.accounts() where name != active {
            let remove = NSMenuItem(title: "Remove \(name)…", action: #selector(removeAccount(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = name
            sub.addItem(remove)
        }
        sub.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sub.addItem(login)
        manage.submenu = sub
        menu.addItem(manage)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func updateOpenMenu() {
        let active = AccountStore.activeAccount()
        for item in menu.items {
            guard let name = item.representedObject as? String,
                  item.action == #selector(switchAccount(_:)) else { continue }
            item.attributedTitle = Render.accountTitle(name: name, state: usage[name])
            item.state = name == active ? .on : .off
        }
    }

    // MARK: - Actions

    @objc func refreshNow() { refresh() }

    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              name != AccountStore.activeAccount() else { return }
        performSwitch(to: name, reason: nil)
    }

    func performSwitch(to name: String, reason: String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, output) = AccountStore.switchTo(name)
            DispatchQueue.main.async {
                if ok {
                    let detail = reason ?? "New sessions and agents now use \(name)"
                    AccountStore.notify(title: "Claude account → \(name)", message: detail)
                } else {
                    AccountStore.notify(title: "Claude account switch failed",
                                        message: output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                self?.refresh()
            }
        }
    }

    func runAutopilot() {
        guard autopilotOn, let active = AccountStore.activeAccount() else { return }
        let lastSwitch = defaults.object(forKey: "autopilot-last-switch") as? Date
        guard let decision = Autopilot.decide(active: active, usage: usage, lastSwitch: lastSwitch) else { return }
        defaults.set(Date(), forKey: "autopilot-last-switch")
        defaults.set(decision.reason, forKey: "autopilot-last-reason")
        performSwitch(to: decision.target, reason: decision.reason)
    }

    @objc func toggleAutopilot() {
        autopilotOn.toggle()
        rebuildMenu()
        if autopilotOn { runAutopilot() }
    }

    @objc func addAccount() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save the current login as an account"
        alert.informativeText = unknownLoginEmail.map { "Live login: \($0)\n\nName this account (e.g. personal, work)." }
            ?? "First /login as the account in any Claude session, then name it here. The live login will be saved under this name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "account name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil else {
            errorAlert("Account names use letters, numbers, dashes.")
            return
        }
        guard !AccountStore.accounts().contains(name) else {
            errorAlert("An account named '\(name)' already exists.")
            return
        }
        let (ok, output) = AccountStore.snapshot(name)
        if ok {
            if let email = unknownLoginEmail { defaults.set(email, forKey: "email-\(name)") }
            unknownLoginEmail = nil
            AccountStore.notify(title: "Account saved", message: "'\(name)' added and marked active")
        } else {
            errorAlert(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        refresh()
    }

    @objc func removeAccount(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove '\(name)'?"
        alert.informativeText = "Deletes the saved credential snapshot on this Mac. The login itself isn't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try AccountStore.remove(name)
            defaults.removeObject(forKey: "email-\(name)")
        } catch {
            errorAlert(error.localizedDescription)
        }
        refresh()
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            errorAlert("Launch at Login failed: \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    func errorAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude Usage"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
