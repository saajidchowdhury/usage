import AppKit
import OSLog
import WebKit

struct Window: Decodable, Sendable {
    let utilization: Double
    let resetsAt: Date?

    func percent(at now: Date) -> String {
        guard resetsAt.map({ $0 > now }) ?? true else { return "–" }
        return "\(100 - Int(min(100, max(0, utilization)).rounded()))%"
    }

    func countdown(at now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return "–" }
        let minutes = Int(min(7*24*60, ceil(resetsAt.timeIntervalSince(now)/60)))
        return minutes >= 24*60
            ? String(format: "%dd %02dh", minutes/1440, (minutes/60)%24)
            : String(format: "%dh %02dm", minutes/60, minutes%60)
    }
}

struct Quota: Decodable, Sendable {
    let fiveHour, sevenDay: Window?
}

struct UsageError: LocalizedError {
    let message: String
    var retryAfter: Date? = nil
    var clear = false
    var errorDescription: String? { message }
}

enum Codex {
    static let executable = URL(fileURLWithPath:
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

    struct Response: Decodable {
        struct Snapshot: Decodable {
            struct Limit: Decodable {
                let usedPercent: Double
                let windowDurationMins: Int?
                let resetsAt: Double?
                var window: Window {
                    Window(utilization: usedPercent, resetsAt: resetsAt.map(Date.init(timeIntervalSince1970:)))
                }
            }
            let primary, secondary: Limit?
        }
        struct Result: Decodable {
            let rateLimits: Snapshot
            let rateLimitsByLimitId: [String: Snapshot]?
        }
        let id: Int?
        let result: Result?

        var quota: Quota? {
            guard let result else { return nil }
            let snapshot = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
            let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
            return Quota(
                fiveHour: windows.first { $0.windowDurationMins == 300 }?.window,
                sevenDay: windows.first { $0.windowDurationMins == 10080 }?.window
            )
        }
    }

    static func fetch() throws -> Quota {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UsageError(message: "Codex CLI missing from ChatGPT.app.", clear: true)
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
        }
        let requests = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"usage_bar","version":"1"}}}
        {"method":"initialized"}
        {"id":2,"method":"account/rateLimits/read"}

        """
        try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
        let decoder = JSONDecoder()
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let response = try? decoder.decode(Response.self, from: buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                guard response?.id == 2 else { continue }
                guard let quota = response?.quota else {
                    throw UsageError(message: "Codex could not read quota. Check your ChatGPT sign-in.")
                }
                return quota
            }
        }
        throw UsageError(message: "Codex stopped before returning quota.")
    }
}

final class ClaudeHTTP: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class Claude: NSObject, NSWindowDelegate {
    static let host = "https://claude.ai"
    let store = WKWebsiteDataStore.default()
    var window: NSWindow?
    var onClose: (() -> Void)?
    private let session = URLSession(configuration: .ephemeral, delegate: ClaudeHTTP(), delegateQueue: nil)

    func signIn() {
        if window == nil {
            let bounds = NSRect(x: 0, y: 0, width: 540, height: 660)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = store
            let view = WKWebView(frame: bounds, configuration: config)
            let panel = NSWindow(contentRect: bounds, styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = "Claude Sign-In"
            panel.contentView = view
            panel.delegate = self
            panel.center()
            window = panel
            view.load(URLRequest(url: URL(string: Self.host + "/login")!))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }

    func get<T: Decodable>(_ path: String, cookie: HTTPCookie, decoder: JSONDecoder) async throws -> T {
        var request = URLRequest(url: URL(string: Self.host + path)!, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: [cookie])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: return try decoder.decode(T.self, from: data)
        case 401, 302: throw UsageError(message: "Sign in to Claude from this menu.", clear: true)
        case 429:
            let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 600
            throw UsageError(message: "Claude is throttling requests. Retrying later.",
                             retryAfter: Date().addingTimeInterval(max(120, delay)))
        default: throw UsageError(message: "Claude returned HTTP \(http.statusCode).")
        }
    }

    func fetch() async throws -> Quota {
        struct Organization: Decodable { let uuid: UUID }
        let cookies = await store.httpCookieStore.allCookies().filter {
            ($0.domain == "claude.ai" || $0.domain == ".claude.ai") && $0.path == "/"
        }
        guard let sessionKey = cookies.first(where: { $0.name == "sessionKey" && $0.isSecure }) else {
            throw UsageError(message: "Sign in to Claude from this menu.", clear: true)
        }
        let decoder = Self.decoder()
        let activeOrg = cookies.first { $0.name == "lastActiveOrg" }.flatMap { UUID(uuidString: $0.value) }
        let org: UUID
        if let activeOrg {
            org = activeOrg
        } else {
            let orgs: [Organization] = try await get("/api/organizations", cookie: sessionKey, decoder: decoder)
            guard let first = orgs.first else { throw UsageError(message: "Claude returned no organizations.") }
            org = first.uuid
        }
        return try await get("/api/organizations/\(org.uuidString.lowercased())/usage",
                             cookie: sessionKey, decoder: decoder)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let text = try value.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            guard let date = iso.date(from: text) else { throw URLError(.cannotParseResponse) }
            return date
        }
        return decoder
    }
}

@MainActor
final class UsageBar: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.saajid.UsageBar", category: "quota")
    struct Provider {
        var quota: Quota?
        var detail = "Connecting…"
        var busy = false
        var retryAfter = Date.distantPast
    }

    let claude = Claude()
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let details = [NSMenuItem(), NSMenuItem()]
    let icons = ["claude", "codex"].map { name in
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }
    var providers = [Provider(), Provider()]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        for item in details { menu.addItem(item) }
        menu.addItem(.separator())
        for (title, action) in [
            ("Refresh Now", #selector(refresh)),
            ("Sign In to Claude…", #selector(signIn)),
            ("Quit Usage Bar", #selector(NSApplication.terminate(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
            menu.addItem(item)
        }
        status.menu = menu
        claude.onClose = { [weak self] in self?.refresh() }
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.tolerance = 10
    }

    @objc func signIn() { claude.signIn() }

    @objc func refresh() {
        update(0) { try await self.claude.fetch() }
        update(1) { try await Task.detached(priority: .utility) { try Codex.fetch() }.value }
    }

    func update(_ index: Int, fetch: @escaping @MainActor () async throws -> Quota) {
        guard !providers[index].busy, providers[index].retryAfter <= Date() else { return }
        providers[index].busy = true
        Task {
            defer {
                providers[index].busy = false
                render()
            }
            do {
                let quota = try await fetch()
                providers[index].quota = quota
                providers[index].detail = "Updated " + Date().formatted(date: .omitted, time: .shortened)
                log.notice("Provider \(index, privacy: .public) refreshed. Session: \(quota.fiveHour != nil, privacy: .public), weekly: \(quota.sevenDay != nil, privacy: .public)")
            } catch {
                let failure = error as? UsageError
                if failure?.clear == true { providers[index].quota = nil }
                providers[index].retryAfter = failure?.retryAfter ?? .distantPast
                let suffix = providers[index].quota == nil ? "" : " (last reading)"
                providers[index].detail = error.localizedDescription + suffix
                let underlying = error as NSError
                let diagnostic = failure?.message ?? "\(underlying.domain) \(underlying.code)"
                log.notice("Provider \(index, privacy: .public) refresh failed: \(diagnostic, privacy: .public)")
            }
        }
    }

    func render() {
        let names = ["Claude", "ChatGPT (Codex)"]
        let now = Date()
        var rows: [[(String, String)]] = []
        for (index, provider) in providers.enumerated() {
            let windows = [provider.quota?.fiveHour, provider.quota?.sevenDay]
            rows.append(windows.map { ($0?.percent(at: now) ?? "–", $0?.countdown(at: now) ?? "–") })
            details[index].title = names[index] + " — " + provider.detail
        }
        status.button?.toolTip = zip(names, rows).map { name, row in
            "\(name)\nSession: \(row[0].0) · \(row[0].1)\nWeekly: \(row[1].0) · \(row[1].1)"
        }.joined(separator: "\n\n")
        status.button?.setAccessibilityLabel(status.button?.toolTip)
        status.button?.image = Self.image(rows, icons: icons)
    }

    static func image(_ rows: [[(String, String)]], icons: [NSImage?]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let height = min(25, NSStatusBar.system.thickness)
        let extraLogoSpacing: CGFloat = 2
        let extraCountdownSpacing: CGFloat = 3
        let providerWidth = 101 + extraLogoSpacing + extraCountdownSpacing
        // Match the visible percent-to-countdown gap when Claude shows 11h 31m.
        let providerSpacing: CGFloat = 6.5
        let width = 2*providerWidth + providerSpacing - 1
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (index, row) in rows.enumerated() {
                let x = CGFloat(index)*(providerWidth + providerSpacing)
                let percentRightX = x + 50 + extraLogoSpacing
                let resetX = percentRightX + 5 + extraCountdownSpacing
                icons[index]?.draw(in: NSRect(x: x - 1, y: (height - 23)/2, width: 23, height: 23))
                for (line, (percent, reset)) in row.enumerated() {
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                    let y = (height - 22)/2 + CGFloat(line)*11
                    percent.draw(at: NSPoint(x: percentRightX - percent.size(withAttributes: attributes).width, y: y),
                                 withAttributes: attributes)
                    reset.draw(at: NSPoint(x: resetX, y: y), withAttributes: attributes)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = UsageBar()
app.delegate = delegate
app.run()
