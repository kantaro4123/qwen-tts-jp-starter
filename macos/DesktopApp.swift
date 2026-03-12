import AppKit
import Foundation
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var webView: WKWebView!
    private var logTextView: NSTextView!
    private var startButton: NSButton!
    private var setupButton: NSButton!
    private var updateButton: NSButton!
    private var installASRButton: NSButton!
    private var helpButton: NSButton!

    private var activeTask: Process?
    private var backendProcess: Process?
    private var backendStdout: Pipe?
    private var backendStderr: Pipe?
    private let projectDir: URL
    private let releasesURL = URL(string: "https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest")!
    private let pythonDownloadURL = URL(string: "https://www.python.org/downloads/macos/")!
    private let backendPort = "7860"

    override init() {
        projectDir = Bundle.main.bundleURL.deletingLastPathComponent()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        webView.loadHTMLString(
            """
            <html><body style="font-family:-apple-system; background:#f7f7f4; color:#264033; display:flex; align-items:center; justify-content:center; height:100vh; margin:0;">
            <div style="text-align:center; max-width:520px;">
              <h1 style="font-size:32px; margin-bottom:12px;">かんたんボイスクローン</h1>
              <p style="font-size:16px; line-height:1.7;">右上のボタンからセットアップや起動を進めてください。<br>起動が終わると、この画面の中にアプリ本体が表示されます。</p>
            </div>
            </body></html>
            """,
            baseURL: nil
        )
        updateStatus("準備完了です。最初は『初回セットアップ』から始めてください。")
        appendLog("アプリを起動しました。")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateProcess(&activeTask)
        terminateProcess(&backendProcess)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1240, height: 880)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "かんたんボイスクローン"
        window.center()
        window.minSize = NSSize(width: 1040, height: 760)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let heroTitle = label("かんたんボイスクローン", fontSize: 28, weight: .bold)
        let heroBody = wrappingLabel("Qwen-TTS を、日本語でわかりやすく始めるための macOS アプリです。セットアップ、起動、更新、ローカル文字起こし追加まで、このアプリ内で進められます。", fontSize: 14, weight: .regular)
        statusLabel = wrappingLabel("準備中...", fontSize: 13, weight: .medium)
        statusLabel.textColor = NSColor(calibratedRed: 0.16, green: 0.41, blue: 0.29, alpha: 1)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        startButton = actionButton("起動", action: #selector(handleStart))
        setupButton = actionButton("初回セットアップ", action: #selector(handleSetup))
        updateButton = actionButton("更新", action: #selector(handleUpdate))
        installASRButton = actionButton("ローカル文字起こしを追加", action: #selector(handleInstallASR))
        helpButton = actionButton("READMEを開く", action: #selector(handleHelp))

        let buttonRow1 = NSStackView(views: [startButton, setupButton, updateButton])
        buttonRow1.orientation = .horizontal
        buttonRow1.spacing = 12
        buttonRow1.distribution = .fillEqually
        buttonRow1.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow2 = NSStackView(views: [installASRButton, helpButton])
        buttonRow2.orientation = .horizontal
        buttonRow2.spacing = 12
        buttonRow2.distribution = .fillEqually
        buttonRow2.translatesAutoresizingMaskIntoConstraints = false

        let topCard = NSView()
        topCard.translatesAutoresizingMaskIntoConstraints = false
        topCard.wantsLayer = true
        topCard.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.94).cgColor
        topCard.layer?.cornerRadius = 22
        topCard.layer?.borderWidth = 1
        topCard.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor

        [heroTitle, heroBody, statusLabel, spinner, buttonRow1, buttonRow2].forEach { subview in
            subview.translatesAutoresizingMaskIntoConstraints = false
            topCard.addSubview(subview)
        }

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")

        let webCard = containerCard()
        webCard.addSubview(webView)

        let logLabel = label("動作ログ", fontSize: 16, weight: .semibold)
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        logTextView = NSTextView()
        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1)
        logTextView.textColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        scrollView.documentView = logTextView

        let logCard = containerCard()
        [logLabel, scrollView].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            logCard.addSubview(view)
        }

        [topCard, webCard, logCard].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),

            topCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topCard.topAnchor.constraint(equalTo: root.topAnchor),
            topCard.heightAnchor.constraint(equalToConstant: 210),

            heroTitle.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            heroTitle.topAnchor.constraint(equalTo: topCard.topAnchor, constant: 22),

            heroBody.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            heroBody.topAnchor.constraint(equalTo: heroTitle.bottomAnchor, constant: 10),
            heroBody.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),

            statusLabel.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: heroBody.bottomAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -12),

            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),

            buttonRow1.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            buttonRow1.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),
            buttonRow1.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            buttonRow1.heightAnchor.constraint(equalToConstant: 38),

            buttonRow2.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            buttonRow2.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),
            buttonRow2.topAnchor.constraint(equalTo: buttonRow1.bottomAnchor, constant: 10),
            buttonRow2.heightAnchor.constraint(equalToConstant: 38),

            webCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webCard.topAnchor.constraint(equalTo: topCard.bottomAnchor, constant: 18),
            webCard.heightAnchor.constraint(equalToConstant: 400),

            webView.leadingAnchor.constraint(equalTo: webCard.leadingAnchor, constant: 14),
            webView.trailingAnchor.constraint(equalTo: webCard.trailingAnchor, constant: -14),
            webView.topAnchor.constraint(equalTo: webCard.topAnchor, constant: 14),
            webView.bottomAnchor.constraint(equalTo: webCard.bottomAnchor, constant: -14),

            logCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            logCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            logCard.topAnchor.constraint(equalTo: webCard.bottomAnchor, constant: 18),
            logCard.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            logLabel.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 16),
            logLabel.topAnchor.constraint(equalTo: logCard.topAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: logCard.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: logLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: logCard.bottomAnchor, constant: -12),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    private func containerCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.94).cgColor
        card.layer?.cornerRadius = 22
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        return card
    }

    private func label(_ text: String, fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.textColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wrappingLabel(_ text: String, fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.textColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setBusy(_ busy: Bool) {
        [startButton, setupButton, updateButton, installASRButton, helpButton].forEach { $0.isEnabled = !busy }
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = text
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            let attributed = NSAttributedString(string: text + "\n")
            self.logTextView.textStorage?.append(attributed)
            self.logTextView.scrollToEndOfDocument(nil)
        }
    }

    private func terminateProcess(_ processRef: inout Process?) {
        guard let process = processRef, process.isRunning else {
            processRef = nil
            return
        }
        process.terminate()
        processRef = nil
    }

    private func projectFile(_ name: String) -> URL {
        projectDir.appendingPathComponent(name)
    }

    private func projectHasGit() -> Bool {
        FileManager.default.fileExists(atPath: projectFile(".git").path)
    }

    private func isSetupComplete() -> Bool {
        FileManager.default.fileExists(atPath: projectFile(".venv").path)
    }

    private func readmeURL() -> URL {
        projectFile("README.md")
    }

    private func runShellScript(_ relativePath: String, extraEnvironment: [String: String] = [:], completion: ((Int32) -> Void)? = nil) {
        guard activeTask == nil else {
            updateStatus("別の処理が進行中です。終わるまで待ってください。")
            return
        }

        let scriptURL = projectFile(relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            updateStatus("\(relativePath) が見つかりませんでした。")
            return
        }

        let process = Process()
        process.currentDirectoryURL = projectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]

        var environment = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.activeTask = nil
                self?.setBusy(false)
                completion?(task.terminationStatus)
            }
        }

        do {
            setBusy(true)
            activeTask = process
            try process.run()
        } catch {
            activeTask = nil
            setBusy(false)
            updateStatus("処理を開始できませんでした: \(error.localizedDescription)")
        }
    }

    private func runShellCommand(_ command: String, extraEnvironment: [String: String] = [:], completion: ((Int32) -> Void)? = nil) {
        guard activeTask == nil else {
            updateStatus("別の処理が進行中です。終わるまで待ってください。")
            return
        }

        let process = Process()
        process.currentDirectoryURL = projectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        var environment = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.activeTask = nil
                self?.setBusy(false)
                completion?(task.terminationStatus)
            }
        }

        do {
            setBusy(true)
            activeTask = process
            try process.run()
        } catch {
            activeTask = nil
            setBusy(false)
            updateStatus("処理を開始できませんでした: \(error.localizedDescription)")
        }
    }

    private func startBackendIfNeeded() {
        if let process = backendProcess, process.isRunning {
            waitForBackendAndLoad()
            return
        }

        guard isSetupComplete() else {
            let alert = NSAlert()
            alert.messageText = "まだセットアップされていません"
            alert.informativeText = "最初に『初回セットアップ』を実行してください。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let process = Process()
        process.currentDirectoryURL = projectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [projectFile("run.command").path]

        var environment = ProcessInfo.processInfo.environment
        environment["QWEN_TTS_NO_OPEN_BROWSER"] = "1"
        environment["QWEN_TTS_PORT"] = backendPort
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        backendStdout = stdout
        backendStderr = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.appendLog(text.trimmingCharacters(in: .newlines))
        }

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.backendStdout?.fileHandleForReading.readabilityHandler = nil
                self?.backendStderr?.fileHandleForReading.readabilityHandler = nil
                self?.backendProcess = nil
                self?.backendStdout = nil
                self?.backendStderr = nil
                self?.setBusy(false)
                self?.updateStatus("アプリ本体が停止しました。もう一度『起動』を押すと再開できます。")
                self?.appendLog("バックエンドが終了しました。終了コード: \(task.terminationStatus)")
            }
        }

        do {
            setBusy(true)
            updateStatus("起動準備中です。アプリ本体が立ち上がるまで少し待ってください。")
            appendLog("バックエンドを起動します。")
            try process.run()
            backendProcess = process
            waitForBackendAndLoad()
        } catch {
            setBusy(false)
            updateStatus("起動に失敗しました: \(error.localizedDescription)")
        }
    }

    private func waitForBackendAndLoad() {
        let targetURL = URL(string: "http://127.0.0.1:\(backendPort)")!
        let start = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date().timeIntervalSince(start) < 120 {
                var request = URLRequest(url: targetURL)
                request.timeoutInterval = 2
                let semaphore = DispatchSemaphore(value: 0)
                var success = false
                URLSession.shared.dataTask(with: request) { _, response, _ in
                    if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                        success = true
                    }
                    semaphore.signal()
                }.resume()
                _ = semaphore.wait(timeout: .now() + 3)

                if success {
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.updateStatus("起動しました。アプリ内の画面からそのまま使えます。")
                        self?.webView.load(URLRequest(url: targetURL))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.8)
            }

            DispatchQueue.main.async {
                self?.setBusy(false)
                self?.updateStatus("起動に時間がかかっています。ログを確認してください。")
            }
        }
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @objc private func handleStart() {
        startBackendIfNeeded()
    }

    @objc private func handleSetup() {
        updateStatus("初回セットアップを始めます。数分かかることがあります。")
        appendLog("初回セットアップを開始します。")
        runShellScript("setup.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("初回セットアップが終わりました。次は『起動』を押してください。")
            } else {
                self?.updateStatus("初回セットアップに失敗しました。ログを確認してください。")
                if let self, !self.isSetupComplete() {
                    self.openURL(self.pythonDownloadURL)
                }
            }
        }
    }

    @objc private func handleUpdate() {
        guard projectHasGit() else {
            updateStatus("配布版ではアプリ内更新は使えません。Releases を開きます。")
            openURL(releasesURL)
            return
        }
        updateStatus("更新を始めます。")
        appendLog("更新を開始します。")
        runShellCommand("git pull && ./setup.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("更新が終わりました。")
            } else {
                self?.updateStatus("更新に失敗しました。ログを確認してください。")
            }
        }
    }

    @objc private func handleInstallASR() {
        guard isSetupComplete() else {
            updateStatus("先に『初回セットアップ』を実行してください。")
            return
        }
        updateStatus("ローカル文字起こしを追加します。")
        appendLog("ローカル文字起こしの導入を開始します。")
        runShellScript("install_local_asr.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("ローカル文字起こしの追加が終わりました。")
            } else {
                self?.updateStatus("ローカル文字起こしの追加に失敗しました。ログを確認してください。")
            }
        }
    }

    @objc private func handleHelp() {
        openURL(readmeURL())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateStatus("起動しました。アプリ内でそのまま使えます。")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
