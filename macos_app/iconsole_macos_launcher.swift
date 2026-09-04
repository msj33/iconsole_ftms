import Cocoa
import WebKit

@main
final class IconsoleMacOSLauncher: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var bridgeProcess: Process?
    private var ownsBridgeProcess = false
    private var webPort: Int = 8080
    private let stateDir = ("~/Library/Application Support/iConsoleFTMS" as NSString).expandingTildeInPath
    private let logDir = ("~/Library/Logs/iConsoleFTMS" as NSString).expandingTildeInPath
    private var pidFilePath: String { "\(stateDir)/bridge.pid" }
    private var envFilePath: String { "\(stateDir)/env.sh" }
    private var logFilePath: String { "\(logDir)/bridge.log" }

    static func main() {
        let app = NSApplication.shared
        let delegate = IconsoleMacOSLauncher()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyBundledAppIcon()
        do {
            try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        } catch {
            showFatalAlert("Could not create app state/log folders: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        let env = loadEnvironmentOverrides()
        webPort = Int(env["ICONSOLE_WEB_PORT"] ?? "") ?? 8080

        do {
            try ensureBridgeRunning(environment: env)
        } catch {
            showFatalAlert("Could not start backend: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        createMainWindow()
        loadWebInterface()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyBundledAppIcon() {
        guard let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
              let iconImage = NSImage(contentsOfFile: iconPath) else {
            return
        }
        NSApp.applicationIconImage = iconImage
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard ownsBridgeProcess else { return }
        requestGracefulBridgeQuit()
        if let process = bridgeProcess, process.isRunning {
            process.terminate()
        } else if let pid = readStoredPID() {
            kill(pid_t(pid), SIGTERM)
        }
    }

    private func createMainWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1360, height: 860)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.center()
        window.title = "iConsole FTMS"
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.webView = webView
    }

    private func loadWebInterface() {
        guard let webView else { return }
        let urlString = "http://127.0.0.1:\(webPort)"
        guard let url = URL(string: urlString) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)

        if bridgeHealthcheck() {
            webView.load(request)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if self.bridgeHealthcheck() {
                    DispatchQueue.main.async {
                        webView.load(request)
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async {
                webView.loadHTMLString(self.waitingHTML, baseURL: nil)
            }
        }
    }

    private func ensureBridgeRunning(environment env: [String: String]) throws {
        if let oldPID = readStoredPID(), isProcessAlive(oldPID) {
            kill(pid_t(oldPID), SIGTERM)
            Thread.sleep(forTimeInterval: 0.3)
        }

        guard let executablePath = Bundle.main.path(forResource: "iconsole_ftms", ofType: nil) else {
            throw NSError(domain: "launcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled backend not found"])
        }

        let outputHandle = FileHandle(forWritingAtPath: logFilePath) ?? FileHandle(forUpdatingAtPath: logFilePath)
        if outputHandle == nil {
            FileManager.default.createFile(atPath: logFilePath, contents: nil)
        }
        guard let logHandle = FileHandle(forWritingAtPath: logFilePath) ?? FileHandle(forUpdatingAtPath: logFilePath) else {
            throw NSError(domain: "launcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not open log file"])
        }
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: stateDir)
        var processEnv = ProcessInfo.processInfo.environment
        processEnv["ICONSOLE_APP_VERSION"] = resolveAppVersion()
        for (key, value) in env {
            if key == "ICONSOLE_APP_VERSION" {
                continue
            }
            processEnv[key] = value
        }
        process.environment = processEnv
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        bridgeProcess = process
        ownsBridgeProcess = true
        try "\(process.processIdentifier)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    private func resolveAppVersion() -> String {
        if let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let normalized = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        if let versionFilePath = Bundle.main.path(forResource: "APP_VERSION", ofType: nil),
           let versionText = try? String(contentsOfFile: versionFilePath, encoding: .utf8) {
            let normalized = versionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        return "dev"
    }

    private func loadEnvironmentOverrides() -> [String: String] {
        guard let content = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let normalized = line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            guard let equalIndex = normalized.firstIndex(of: "=") else { continue }
            let key = normalized[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(normalized[normalized.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    private func readStoredPID() -> Int32? {
        guard let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text), pid > 0 else {
            return nil
        }
        return pid
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    private func bridgeHealthcheck() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(webPort)/api/state") else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                ok = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)
        return ok
    }

    private func requestGracefulBridgeQuit() {
        guard let url = URL(string: "http://127.0.0.1:\(webPort)/api/action?action=quit") else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.0

        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 1.2)
        Thread.sleep(forTimeInterval: 0.35)
    }

    private func showFatalAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "iConsole FTMS"
        alert.informativeText = message
        alert.runModal()
    }

    private var waitingHTML: String {
        """
        <!doctype html>
        <html><body style="font-family:-apple-system;padding:24px;background:#0b1427;color:#e8efff;">
        <h2>Starting iConsole FTMS...</h2>
        <p>Backend is not responding yet. Please close and reopen the app if this stays here.</p>
        </body></html>
        """
    }
}
