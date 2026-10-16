import AppKit
import CoreAudio

/// Menu-bar UI: a real NSMenu — submenus for devices, a status submenu (so the
/// top level never changes width), the standard About panel, ⌘Q Quit.
/// Rebuilt on every open; live bits (icon, status lines) refresh on a timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Created on the main thread at launch (both are @MainActor).
    private(set) var settings: BridgeSettings!
    private(set) var controller: BridgeController!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusItems: [NSMenuItem] = []
    private var poll: Timer?

    // MARK: - launch

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.applicationDidFinishLaunchingMain()
        }
    }

    private func applicationDidFinishLaunchingMain() {
        MainActor.assumeIsolated {
            self.settings = BridgeSettings()
            self.controller = BridgeController()
            self.controller.restoreSelection(settings: self.settings)
            self.controller.onError = { [weak self] msg in self?.alert(msg) }
            self.controller.uiPolish = self.settings.usePolish
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "0B77"
        menu.delegate = self
        statusItem.menu = menu
        MainActor.assumeIsolated { self.rebuildMenu() }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
    }

    // MARK: - menu build (main thread throughout)

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { self.rebuildMenu() }
    }

    private func rebuildMenu() {
        guard let settings, let controller else { return }
        menu.removeAllItems()
        statusItems = []
        controller.uiPolish = settings.usePolish
        controller.clampChannels(settings: settings)
        let t = T(pl: settings.usePolish)
        let c = controller

        let toggleTitle = c.isRunning ? t.stop
            : c.speakerConfirmPending ? t.confirmSpeakers : t.start
        menu.addItem(actionItem(title: toggleTitle, action: #selector(doToggle)))

        menu.addItem(.separator())

        addDeviceSubmenu(
            title: t.inputLabel,
            entries: c.inputDevices.map { ($0.id, "\($0.name) (\(t.channelsIn($0.inputChannels)))") },
            selected: c.selectedInputID, enabled: !c.isRunning, action: #selector(pickInput(_:)))
        addDeviceSubmenu(
            title: t.outputLabel,
            entries: c.outputDevices.map { ($0.id, "\($0.name) (\(t.channelsOut($0.outputChannels)))") },
            selected: c.selectedOutputID, enabled: !c.isRunning, action: #selector(pickOutput(_:)))

        let ins = c.inputDevices.first(where: { $0.id == c.selectedInputID })?.inputChannels ?? 6
        let inRange = Array(BridgeController.setRange(channels: ins))
        addIntSubmenu(title: t.inputChannelsLabel, values: inRange, selected: settings.firstInChannel,
                      enabled: !c.isRunning, label: { t.channelSet($0) }, action: #selector(pickInChannel(_:)))

        let outs = c.outputDevices.first(where: { $0.id == c.selectedOutputID })?.outputChannels ?? 20
        let range = Array(BridgeController.pairRange(channels: outs))
        addIntSubmenu(title: t.firstChannelLabel, values: range, selected: settings.firstChannel,
                      enabled: !c.isRunning, label: { t.channelPair($0) }, action: #selector(pickChannel(_:)))
        addIntSubmenu(title: t.bitrateLabel, values: [384, 448, 576, 640],
                      selected: settings.bitrate, enabled: !c.isRunning,
                      label: { t.bitrateUnit($0) }, action: #selector(pickBitrate(_:)))
        addIntSubmenu(title: t.bufferLabel, values: Array(1...8), selected: settings.prefill,
                      enabled: true, label: { t.bufferRow($0) }, action: #selector(pickBuffer(_:)))

        menu.addItem(.separator())

        let statusParent = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for line in statusLines(t) {
            let it = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            it.isEnabled = false
            sm.addItem(it)
            statusItems.append(it)
        }
        statusParent.submenu = sm
        menu.addItem(statusParent)

        menu.addItem(.separator())

        if controller.updateVersion != nil {
            menu.addItem(actionItem(title: "⬇ \(t.updateAvailable(controller.updateVersion!))",
                                    action: #selector(openDownload)))
        } else {
            menu.addItem(actionItem(title: t.checkUpdates, action: #selector(doCheckUpdates)))
            if let note = controller.updateNote {
                let it = NSMenuItem(title: note, action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
        }
        let lang = NSMenuItem(title: t.languageLabel, action: nil, keyEquivalent: "")
        let lm = NSMenu()
        for (key, name) in [("system", t.languageSystem), ("en", "English"), ("pl", "Polski")] {
            let it = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.representedObject = key
            it.state = settings.language == key ? .on : .off
            lm.addItem(it)
        }
        lang.submenu = lm
        menu.addItem(lang)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: t.about, action: #selector(showAboutPanel)))
        menu.addItem(actionItem(title: "\(t.quit) 0B77", action: #selector(NSApplication.terminate(_:)),
                                target: NSApplication.shared))
    }

    private func actionItem(title: String, action: Selector, key: String = "",
                            target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    private func addDeviceSubmenu(title: String, entries: [(AudioDeviceID, String)],
                                 selected: AudioDeviceID?, enabled: Bool,
                                 action: Selector) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = enabled
        let sm = NSMenu()
        for (id, name) in entries {
            let it = NSMenuItem(title: name, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: id)
            it.state = (selected == id) ? .on : .off
            sm.addItem(it)
        }
        parent.submenu = sm
        menu.addItem(parent)
    }

    private func addIntSubmenu(title: String, values: [Int], selected: Int, enabled: Bool,
                              label: (Int) -> String, action: Selector) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = enabled
        let sm = NSMenu()
        for v in values {
            let it = NSMenuItem(title: label(v), action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: v)
            it.state = (selected == v) ? .on : .off
            sm.addItem(it)
        }
        parent.submenu = sm
        menu.addItem(parent)
    }

    private func statusLines(_ t: T) -> [String] {
        guard let controller else { return [] }
        let c = controller
        if c.isRunning {
            var lines = [c.runSummary.isEmpty ? c.statusLine : c.runSummary]
            lines += c.statusLine.components(separatedBy: "\n")
            if let err = c.lastError { lines.append(err) }
            return lines
        }
        var lines = [c.statusLine]
        lines += c.preflightWarnings()
        if let err = c.lastError { lines.append(err) }
        return lines
    }

    private func refreshLive() {
        guard let controller else { return }
        statusItem.button?.image = MenuIcon.image(streaming: controller.isRunning)
        let lines = statusLines(T(pl: settings.usePolish))
        for (i, it) in statusItems.enumerated() where i < lines.count {
            it.title = lines[i]
        }
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "0B77"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: - actions (main thread; controller is @MainActor)

    @objc private func doToggle() {
        MainActor.assumeIsolated { [weak self] in guard let self, let controller = self.controller else { return }; controller.toggle(settings: settings) }
    }

    @objc private func pickInput(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        MainActor.assumeIsolated { [weak self] in self?.controller?.selectedInputID = id }
    }

    @objc private func pickOutput(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        MainActor.assumeIsolated { [weak self] in self?.controller?.selectedOutputID = id }
    }

    @objc private func pickChannel(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? NSNumber)?.intValue else { return }
        MainActor.assumeIsolated { [weak self] in self?.settings?.firstChannel = v }
    }

    @objc private func pickInChannel(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? NSNumber)?.intValue else { return }
        MainActor.assumeIsolated { [weak self] in self?.settings?.firstInChannel = v }
    }

    @objc private func pickBitrate(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? NSNumber)?.intValue else { return }
        MainActor.assumeIsolated { [weak self] in self?.settings?.bitrate = v }
    }

    @objc private func pickBuffer(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? NSNumber)?.intValue else { return }
        MainActor.assumeIsolated { [weak self] in
            self?.settings?.prefill = v
            self?.controller?.applyPrefill(v)
        }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { [weak self] in
            self?.settings?.language = key
            if let s = self?.settings { self?.controller?.uiPolish = s.usePolish }
        }
    }

    @objc private func doCheckUpdates() {
        Task { @MainActor [weak self] in
            await self?.controller?.checkForUpdates(manual: true)
        }
    }

    @objc private func openDownload() {
        MainActor.assumeIsolated { [weak self] in
            if let u = self?.controller?.updateURL, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func showAboutPanel() {
        MainActor.assumeIsolated { [weak self] in
            guard let self, let settings = self.settings, let controller = self.controller else { return }
            let t = T(pl: settings.usePolish)
            let credits = NSMutableAttributedString(string: "\(t.madeBy)\n")
            credits.append(NSAttributedString(
                string: t.repoURL,
                attributes: [.link: t.repoURL, .foregroundColor: NSColor.linkColor]))
            credits.append(NSAttributedString(string: "\n\(t.built(controller.buildDate))"))
            NSApplication.shared.orderFrontStandardAboutPanel(options: [
                .applicationName: "0B77",
                .applicationVersion: controller.appVersion,
                .credits: credits,
            ])
        }
    }
}
