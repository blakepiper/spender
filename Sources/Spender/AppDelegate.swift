import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var snapshot: UsageSnapshot?
    private var refreshTimer: Timer?
    private var refreshing = false
    private var launchMessage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.autosaveName = "com.blake.spender.status-item"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: "Spender")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = " —"
            button.toolTip = "Spender AI usage"
        }
        rebuildMenu()
        configureLaunchAtLogin()
        refresh(force: false)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func refreshNow() {
        refresh(force: true)
    }

    @objc private func toggleLaunchAtLogin() {
        let login = LaunchAtLoginController()
        do {
            switch login.state {
            case .enabled:
                try login.disable()
                UserDefaults.standard.set(true, forKey: "launchAtLoginDisabled")
                launchMessage = "Launch at login disabled"
            case .requiresApproval:
                login.openApprovalSettings()
                launchMessage = "Approve Spender in Login Items"
            case .disabled:
                try login.enable()
                UserDefaults.standard.set(false, forKey: "launchAtLoginDisabled")
                launchMessage = login.state == .requiresApproval
                    ? "Approve Spender in Login Items"
                    : "Launch at login enabled"
            }
        } catch {
            launchMessage = "Login item: \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    @objc private func openConfigurationFolder() {
        let path = SpenderConfig.configurationPath()
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh(force: Bool) {
        guard !refreshing else { return }
        refreshing = true
        rebuildMenu()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let value = try SnapshotLoader().load(force: force)
                DispatchQueue.main.async {
                    self?.snapshot = value
                    self?.refreshing = false
                    self?.updateStatusItem()
                    self?.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.refreshing = false
                    self?.launchMessage = "Refresh failed: \(error.localizedDescription)"
                    self?.updateStatusItem()
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let remaining = snapshot.flatMap({ UsageFormatting.menuBarRemaining($0.providers) }) {
            button.title = " \(remaining)%"
            button.toolTip = "Spender · \(remaining)% left in the tightest quota"
        } else {
            button.title = " —"
            button.toolTip = "Spender · live quota unavailable"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if refreshing {
            let item = NSMenuItem(title: "Refreshing usage…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if let snapshot {
            for (index, provider) in snapshot.providers.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                let heading = provider.providerName + (provider.tierLabel.isEmpty ? "" : " · \(provider.tierLabel)")
                let headingItem = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
                headingItem.isEnabled = false
                headingItem.attributedTitle = NSAttributedString(
                    string: heading,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
                )
                menu.addItem(headingItem)

                if provider.quotaWindows.isEmpty {
                    addDetail(provider.status.isEmpty ? "No live quota data" : provider.status, to: menu)
                } else {
                    for window in provider.quotaWindows {
                        addDetail(UsageFormatting.quota(window), to: menu)
                        if let reset = window.resetAt { addDetail(UsageFormatting.reset(reset), to: menu, indented: true) }
                    }
                }
                addDetail(
                    "Today: \(UsageFormatting.tokens(provider.todayTokens)) tokens · \(provider.todayPrompts) prompts · \(provider.todaySessions) sessions",
                    to: menu
                )
                if !provider.help.isEmpty && provider.help != provider.status {
                    addDetail(provider.help, to: menu)
                }
            }
            menu.addItem(.separator())
            addDetail(UsageFormatting.updated(snapshot.generatedAt), to: menu)
        } else if !refreshing {
            addDetail("No usage snapshot yet", to: menu)
        }

        if !launchMessage.isEmpty { addDetail(launchMessage, to: menu) }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !refreshing
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        switch LaunchAtLoginController().state {
        case .enabled: loginItem.state = .on
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Launch at Login — Approval Required…"
        case .disabled: loginItem.state = .off
        }
        menu.addItem(loginItem)

        let configItem = NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigurationFolder), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Spender", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func addDetail(_ title: String, to menu: NSMenu, indented: Bool = false) {
        let prefix = indented ? "    " : "  "
        let item = NSMenuItem(title: prefix + title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func configureLaunchAtLogin() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard !UserDefaults.standard.bool(forKey: "launchAtLoginDisabled") else { return }
        let login = LaunchAtLoginController()
        do {
            if login.state == .disabled {
                try login.enable()
            }
            if login.state == .requiresApproval {
                launchMessage = "Approve Spender in System Settings → Login Items"
            }
        } catch {
            launchMessage = "Launch at login needs attention: \(error.localizedDescription)"
        }
        rebuildMenu()
    }
}
