import AppKit
import ServiceManagement
import DropboxUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let appKeyDefaultsKey = "dropboxAppKey"
    private static let refreshInterval: TimeInterval = 15*60

    private let api = DropboxAPI()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let detailItem = NSMenuItem(title: "Not updated yet", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let connectItem = NSMenuItem(title: "Connect Dropbox…", action: #selector(connect), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var timer: Timer?
    private var hasUsage = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()
        updateLoginItem()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        Task {
            if configuredAppKey == nil || (try? Keychain.refreshToken()) == nil {
                setTitle("Dropbox setup")
                try? await Task.sleep(for: .milliseconds(350))
                connect()
            } else {
                await refresh()
            }
        }
    }

    private var configuredAppKey: String? {
        let value = UserDefaults.standard.string(forKey: Self.appKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        let image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Dropbox usage")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = "Dropbox…"
        button.toolTip = "Dropbox storage usage"
    }

    private func configureMenu() {
        let menu = NSMenu()
        detailItem.isEnabled = false
        updatedItem.isEnabled = false
        menu.addItem(detailItem)
        menu.addItem(updatedItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        connectItem.target = self
        menu.addItem(connectItem)

        let openItem = NSMenuItem(title: "Open Dropbox Plan", action: #selector(openDropboxPlan), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        let quitItem = NSMenuItem(title: "Quit Dropbox Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() {
        Task {
            await refresh(showErrors: true)
        }
    }

    private func refresh(showErrors: Bool = false) async {
        guard let appKey = configuredAppKey else {
            setTitle("Dropbox setup")
            detailItem.title = "Dropbox is not connected"
            return
        }
        if !hasUsage {
            setTitle("Dropbox…")
        }
        do {
            let usage = try await api.spaceUsage(appKey: appKey)
            let title = SpaceFormatter.menuTitle(
                usedBytes: usage.used,
                allocatedBytes: usage.allocation.allocated
            )
            setTitle(title)
            detailItem.title = title
            updatedItem.title = "Updated \(Date().formatted(date: .omitted, time: .shortened))"
            connectItem.title = "Reconnect Dropbox…"
            hasUsage = true
        } catch {
            detailItem.title = "Error: \(error.localizedDescription)"
            if !hasUsage {
                setTitle("Dropbox !")
            }
            if showErrors {
                presentError(error)
            }
        }
    }

    private func setTitle(_ title: String) {
        statusItem.button?.title = title
        statusItem.button?.setAccessibilityLabel("Dropbox usage: \(title)")
    }

    @objc private func connect() {
        NSApp.activate(ignoringOtherApps: true)
        let keyAlert = NSAlert()
        keyAlert.messageText = "Connect Dropbox Usage"
        keyAlert.informativeText = "Create a scoped Dropbox API app, enable account_info.read, then paste its App key here. No App secret is needed."
        keyAlert.alertStyle = .informational
        keyAlert.addButton(withTitle: "Continue")
        keyAlert.addButton(withTitle: "Open App Console")
        keyAlert.addButton(withTitle: "Cancel")
        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        keyField.placeholderString = "Dropbox App key"
        keyField.stringValue = configuredAppKey ?? ""
        keyAlert.accessoryView = keyField
        let response = keyAlert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://www.dropbox.com/developers/apps")!)
            return
        }
        guard response == .alertFirstButtonReturn else {
            return
        }
        let appKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty else {
            presentMessage("App key is required.")
            return
        }

        let verifier = makeCodeVerifier()
        let url = api.authorizationURL(appKey: appKey, verifier: verifier)
        guard NSWorkspace.shared.open(url) else {
            presentMessage("Could not open the Dropbox authorization page.")
            return
        }

        let codeAlert = NSAlert()
        codeAlert.messageText = "Paste the Dropbox authorization code"
        codeAlert.informativeText = "Approve the app in the browser, copy the code Dropbox displays, and paste it below."
        codeAlert.addButton(withTitle: "Connect")
        codeAlert.addButton(withTitle: "Cancel")
        let codeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        codeField.placeholderString = "Authorization code"
        codeAlert.accessoryView = codeField
        guard codeAlert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            presentMessage("Authorization code is required.")
            return
        }

        Task {
            do {
                try await api.exchange(code: code, appKey: appKey, verifier: verifier)
                UserDefaults.standard.set(appKey, forKey: Self.appKeyDefaultsKey)
                await refresh(showErrors: true)
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func openDropboxPlan() {
        NSWorkspace.shared.open(URL(string: "https://www.dropbox.com/account/plan")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError(error)
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func presentError(_ error: Error) {
        presentMessage(error.localizedDescription, style: .critical)
    }

    private func presentMessage(_ message: String, style: NSAlert.Style = .warning) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Dropbox Usage"
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
