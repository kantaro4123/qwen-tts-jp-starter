import AppKit
import Foundation
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private struct QwenOption {
        let label: String
        let modelID: String
    }

    private let qwenOptions: [QwenOption] = [
        .init(label: "高精度 1.7B", modelID: "Qwen/Qwen3-TTS-12Hz-1.7B-Base"),
        .init(label: "軽量 0.6B", modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-Base"),
    ]
    private let asrOptions = ["small", "base", "medium"]
    private let backendPort = "7860"
    private let releasesURL = URL(string: "https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest")!
    private let selectionDefaults = UserDefaults.standard
    private let qwenDefaultsKey = "selectedQwenModelID"
    private let asrDefaultsKey = "selectedLocalASRModel"

    private let bundleFallbackProjectDir = Bundle.main.bundleURL.deletingLastPathComponent()

    private lazy var appSupportBaseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KantanVoiceClone", isDirectory: true)
    }()

    private lazy var runtimeRootURL: URL = {
        appSupportBaseURL.appendingPathComponent("runtime", isDirectory: true)
    }()

    private lazy var bundledModelsRootURL: URL = {
        appSupportBaseURL.appendingPathComponent("bundled-models", isDirectory: true)
    }()

    private lazy var bundledRuntimeArchiveURL: URL? = {
        Bundle.main.url(forResource: "runtime", withExtension: "tar.gz")
    }()

    private lazy var bundledReadmeURL: URL? = {
        Bundle.main.url(forResource: "README", withExtension: "md")
    }()

    private lazy var bundledRuntimeVersion: String = {
        if let url = Bundle.main.url(forResource: "runtime-version", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }()

    private lazy var bundledModelsArchiveURL: URL? = {
        Bundle.main.url(forResource: "bundled-models", withExtension: "tar.gz")
    }()

    private lazy var bundledModelsMetadataURL: URL? = {
        Bundle.main.url(forResource: "bundled-model-map", withExtension: "json")
    }()

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
    private var qwenPopup: NSPopUpButton!
    private var asrPopup: NSPopUpButton!

    private var activeTask: Process?
    private var backendProcess: Process?
    private var backendStdout: Pipe?
    private var backendStderr: Pipe?

    private var usesBundledRuntime: Bool {
        bundledRuntimeArchiveURL != nil
    }

    private var currentProjectDir: URL {
        usesBundledRuntime ? runtimeRootURL : bundleFallbackProjectDir
    }

    private var runtimeVersionFileURL: URL {
        runtimeRootURL.appendingPathComponent(".runtime-version")
    }

    private var bundledModelsVersionFileURL: URL {
        bundledModelsRootURL.appendingPathComponent(".bundle-version")
    }

    private var extractedModelMapURL: URL {
        bundledModelsRootURL.appendingPathComponent("model-map.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        loadSelectionDefaults()
        webView.loadHTMLString(
            """
            <html><body style="font-family:-apple-system; background:#f7f7f4; color:#264033; display:flex; align-items:center; justify-content:center; height:100vh; margin:0;">
            <div style="text-align:center; max-width:580px; padding:0 24px;">
              <h1 style="font-size:30px; margin-bottom:14px;">かんたんボイスクローン</h1>
              <p style="font-size:15px; line-height:1.75; color:#3a5547;">
                上のパネルで <strong>①セットアップ</strong> を押し、<br>
                完了したら <strong>②起動</strong> を押してください。<br>
                アプリが起動すると、ここに画面が表示されます。
              </p>
            </div>
            </body></html>
            """,
            baseURL: nil
        )
        updateStatus(initialStatusMessage())
        appendLog("アプリを起動しました。")
        appendLog(usesBundledRuntime ? "内蔵ランタイム版として起動しています。" : "開発モードとして起動しています。")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateProcess(&activeTask)
        terminateProcess(&backendProcess)
    }

    private func initialStatusMessage() -> String {
        "まず ①セットアップ を押してください。終わったら ②起動 を押すとアプリが立ち上がります。"
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1240, height: 920)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "かんたんボイスクローン"
        window.center()
        window.minSize = NSSize(width: 1040, height: 800)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let heroTitle = label("かんたんボイスクローン", fontSize: 28, weight: .bold)
        let heroBody = wrappingLabel("Qwen-TTS を、日本語でわかりやすく始めるための macOS アプリです。起動、セットアップ、ローカル文字起こし追加まで、このアプリの中だけで進められます。", fontSize: 14, weight: .regular)
        statusLabel = wrappingLabel("準備中...", fontSize: 13, weight: .medium)
        statusLabel.textColor = NSColor(calibratedRed: 0.16, green: 0.41, blue: 0.29, alpha: 1)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        qwenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        qwenPopup.translatesAutoresizingMaskIntoConstraints = false
        qwenPopup.addItems(withTitles: qwenOptions.map(\ .label))
        qwenPopup.target = self
        qwenPopup.action = #selector(handleSelectionChange)

        asrPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        asrPopup.translatesAutoresizingMaskIntoConstraints = false
        asrPopup.addItems(withTitles: asrOptions)
        asrPopup.target = self
        asrPopup.action = #selector(handleSelectionChange)

        let qwenLabel = label("Qwen-TTS モデル（音声品質）", fontSize: 13, weight: .semibold)
        let asrLabel = label("音声認識モデル（文字起こし）", fontSize: 13, weight: .semibold)
        let qwenStack = NSStackView(views: [qwenLabel, qwenPopup])
        qwenStack.orientation = .vertical
        qwenStack.spacing = 6
        qwenStack.translatesAutoresizingMaskIntoConstraints = false
        let asrStack = NSStackView(views: [asrLabel, asrPopup])
        asrStack.orientation = .vertical
        asrStack.spacing = 6
        asrStack.translatesAutoresizingMaskIntoConstraints = false
        let selectionRow = NSStackView(views: [qwenStack, asrStack])
        selectionRow.orientation = .horizontal
        selectionRow.spacing = 14
        selectionRow.distribution = .fillEqually
        selectionRow.translatesAutoresizingMaskIntoConstraints = false

        let flowHint = wrappingLabel("はじめての方は ①セットアップ（初回のみ）→ ②起動 の順に進めてください。", fontSize: 13, weight: .regular)
        flowHint.textColor = NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.64, alpha: 1)

        startButton = actionButton("② 起動", action: #selector(handleStart))
        setupButton = actionButton("① セットアップ", action: #selector(handleSetup))
        updateButton = actionButton("更新確認", action: #selector(handleUpdate))
        installASRButton = actionButton("音声認識を追加（任意）", action: #selector(handleInstallASR))
        helpButton = actionButton("ヘルプを開く", action: #selector(handleHelp))

        let buttonRow1 = NSStackView(views: [setupButton, startButton, updateButton])
        buttonRow1.orientation = .horizontal
        buttonRow1.spacing = 12
        buttonRow1.distribution = .fillEqually
        buttonRow1.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow2 = NSStackView(views: [installASRButton, helpButton])
        buttonRow2.orientation = .horizontal
        buttonRow2.spacing = 12
        buttonRow2.distribution = .fillEqually
        buttonRow2.translatesAutoresizingMaskIntoConstraints = false

        let topCard = containerCard()
        [heroTitle, heroBody, flowHint, selectionRow, statusLabel, spinner, buttonRow1, buttonRow2].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            topCard.addSubview($0)
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
        [logLabel, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            logCard.addSubview($0)
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

            heroTitle.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            heroTitle.topAnchor.constraint(equalTo: topCard.topAnchor, constant: 22),

            heroBody.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            heroBody.topAnchor.constraint(equalTo: heroTitle.bottomAnchor, constant: 10),
            heroBody.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),

            flowHint.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            flowHint.topAnchor.constraint(equalTo: heroBody.bottomAnchor, constant: 8),
            flowHint.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),

            selectionRow.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            selectionRow.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -24),
            selectionRow.topAnchor.constraint(equalTo: flowHint.bottomAnchor, constant: 10),
            selectionRow.heightAnchor.constraint(equalToConstant: 56),

            statusLabel.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: selectionRow.bottomAnchor, constant: 12),
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
            buttonRow2.bottomAnchor.constraint(equalTo: topCard.bottomAnchor, constant: -22),

            webCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webCard.topAnchor.constraint(equalTo: topCard.bottomAnchor, constant: 18),
            webCard.heightAnchor.constraint(equalToConstant: 370),

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

    private func selectedQwenModelID() -> String {
        let index = max(0, qwenPopup.indexOfSelectedItem)
        return qwenOptions[index].modelID
    }

    private func selectedASRModel() -> String {
        let index = max(0, asrPopup.indexOfSelectedItem)
        return asrOptions[index]
    }

    private func loadSelectionDefaults() {
        let savedQwen = selectionDefaults.string(forKey: qwenDefaultsKey) ?? qwenOptions[0].modelID
        let savedASR = selectionDefaults.string(forKey: asrDefaultsKey) ?? asrOptions[0]
        if let qIndex = qwenOptions.firstIndex(where: { $0.modelID == savedQwen }) {
            qwenPopup.selectItem(at: qIndex)
        }
        if let aIndex = asrOptions.firstIndex(of: savedASR) {
            asrPopup.selectItem(at: aIndex)
        }
    }

    private func persistSelectionDefaults() {
        selectionDefaults.set(selectedQwenModelID(), forKey: qwenDefaultsKey)
        selectionDefaults.set(selectedASRModel(), forKey: asrDefaultsKey)
    }

    private func settingsPayload() -> Data? {
        let payload: [String: String] = [
            "qwen_tts_model_id": selectedQwenModelID(),
            "local_asr_model": selectedASRModel(),
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    }

    private func setBusy(_ busy: Bool) {
        [startButton, setupButton, updateButton, installASRButton, helpButton].forEach { $0.isEnabled = !busy }
        qwenPopup.isEnabled = !busy
        asrPopup.isEnabled = !busy
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
        currentProjectDir.appendingPathComponent(name)
    }

    private func projectHasGit() -> Bool {
        FileManager.default.fileExists(atPath: projectFile(".git").path)
    }

    private func runtimeLooksInstalled() -> Bool {
        FileManager.default.fileExists(atPath: projectFile(".venv/bin/python").path)
    }

    private func isSetupComplete() -> Bool {
        runtimeLooksInstalled()
    }

    private func readmeURL() -> URL {
        let runtimeReadme = projectFile("README.md")
        if FileManager.default.fileExists(atPath: runtimeReadme.path) {
            return runtimeReadme
        }
        if let bundledReadmeURL {
            return bundledReadmeURL
        }
        return bundleFallbackProjectDir.appendingPathComponent("README.md")
    }

    private func writeRuntimeSettings() throws {
        persistSelectionDefaults()
        let configDir = currentProjectDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let settingsURL = configDir.appendingPathComponent("settings.json")
        if let data = settingsPayload() {
            try data.write(to: settingsURL)
            appendLog("設定を書き込みました: \(selectedQwenModelID()) / ASR \(selectedASRModel())")
        }
    }

    private func ensureBundledModelBundleInstalled(force: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let archiveURL = bundledModelsArchiveURL, let metadataURL = bundledModelsMetadataURL else {
            completion(true)
            return
        }

        let installedVersion = (try? String(contentsOf: bundledModelsVersionFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if !force && FileManager.default.fileExists(atPath: extractedModelMapURL.path) && installedVersion == bundledRuntimeVersion {
            completion(true)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: self.bundledModelsRootURL, withIntermediateDirectories: true)
                if fm.fileExists(atPath: self.bundledModelsRootURL.path) {
                    let contents = try fm.contentsOfDirectory(at: self.bundledModelsRootURL, includingPropertiesForKeys: nil)
                    for item in contents {
                        try fm.removeItem(at: item)
                    }
                }

                let process = Process()
                process.currentDirectoryURL = self.bundledModelsRootURL
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", archiveURL.path, "-C", self.bundledModelsRootURL.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }

                let raw = try Data(contentsOf: metadataURL)
                let relMap = try JSONSerialization.jsonObject(with: raw) as? [String: String] ?? [:]
                var absMap: [String: String] = [:]
                for (modelID, relPath) in relMap {
                    absMap[modelID] = self.bundledModelsRootURL.appendingPathComponent(relPath).path
                }
                let data = try JSONSerialization.data(withJSONObject: absMap, options: [.prettyPrinted])
                try data.write(to: self.extractedModelMapURL)
                try self.bundledRuntimeVersion.write(to: self.bundledModelsVersionFileURL, atomically: true, encoding: .utf8)
                DispatchQueue.main.async {
                    self.appendLog("同梱モデルを展開しました。")
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.appendLog("同梱モデルの展開に失敗しました: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    private func ensureBundledRuntimeInstalled(force: Bool = false, completion: @escaping (Bool) -> Void) {
        guard usesBundledRuntime else {
            do {
                try writeRuntimeSettings()
                completion(true)
            } catch {
                updateStatus("設定の書き込みに失敗しました: \(error.localizedDescription)")
                completion(false)
            }
            return
        }
        guard let archiveURL = bundledRuntimeArchiveURL else {
            completion(false)
            return
        }

        let installedVersion = (try? String(contentsOf: runtimeVersionFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if !force && runtimeLooksInstalled() && installedVersion == bundledRuntimeVersion {
            do {
                try writeRuntimeSettings()
            } catch {
                updateStatus("設定の書き込みに失敗しました: \(error.localizedDescription)")
                completion(false)
                return
            }
            ensureBundledModelBundleInstalled(force: force, completion: completion)
            return
        }

        setBusy(true)
        updateStatus("内蔵ランタイムを準備しています。初回は少し時間がかかります。")
        appendLog("内蔵ランタイムの展開を開始します。")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: self.appSupportBaseURL, withIntermediateDirectories: true)
                if fm.fileExists(atPath: self.runtimeRootURL.path) {
                    try fm.removeItem(at: self.runtimeRootURL)
                }

                let process = Process()
                process.currentDirectoryURL = self.appSupportBaseURL
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", archiveURL.path, "-C", self.appSupportBaseURL.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async {
                        self.setBusy(false)
                        self.updateStatus("内蔵ランタイムの展開に失敗しました。")
                        completion(false)
                    }
                    return
                }

                try self.bundledRuntimeVersion.write(to: self.runtimeVersionFileURL, atomically: true, encoding: .utf8)
                try self.writeRuntimeSettings()
                self.ensureBundledModelBundleInstalled(force: force) { success in
                    self.setBusy(false)
                    if success {
                        self.updateStatus("内蔵ランタイムの準備が終わりました。次は『起動』を押してください。")
                        self.appendLog("内蔵ランタイムの展開が完了しました。")
                    } else {
                        self.updateStatus("内蔵ランタイムは展開できましたが、同梱モデルの展開に失敗しました。")
                    }
                    completion(success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.updateStatus("内蔵ランタイムの展開に失敗しました: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }

    private func runShellScript(_ relativePath: String, extraEnvironment: [String: String] = [:], completion: ((Int32) -> Void)? = nil) {
        guard activeTask == nil else {
            updateStatus("別の処理が進行中です。終わるまで待ってください。")
            return
        }

        do {
            try writeRuntimeSettings()
        } catch {
            updateStatus("設定の書き込みに失敗しました: \(error.localizedDescription)")
            return
        }

        let scriptURL = projectFile(relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            updateStatus("\(relativePath) が見つかりませんでした。")
            return
        }

        let process = Process()
        process.currentDirectoryURL = currentProjectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { env[$0.key] = $0.value }
        if FileManager.default.fileExists(atPath: extractedModelMapURL.path) {
            env["QWEN_TTS_MODEL_MAP_PATH"] = extractedModelMapURL.path
        }
        process.environment = env

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

    private func runShellCommand(_ command: String, completion: ((Int32) -> Void)? = nil) {
        guard activeTask == nil else {
            updateStatus("別の処理が進行中です。終わるまで待ってください。")
            return
        }

        let process = Process()
        process.currentDirectoryURL = currentProjectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment

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

        let launch = { [weak self] in
            guard let self else { return }
            guard self.isSetupComplete() else {
                let alert = NSAlert()
                alert.messageText = "セットアップが済んでいません"
                alert.informativeText = "先に ①セットアップ を実行してください。"
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            let process = Process()
            process.currentDirectoryURL = self.currentProjectDir
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [self.projectFile("run.command").path]

            var environment = ProcessInfo.processInfo.environment
            environment["QWEN_TTS_NO_OPEN_BROWSER"] = "1"
            environment["QWEN_TTS_PORT"] = self.backendPort
            if FileManager.default.fileExists(atPath: self.extractedModelMapURL.path) {
                environment["QWEN_TTS_MODEL_MAP_PATH"] = self.extractedModelMapURL.path
            }
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            self.backendStdout = stdout
            self.backendStderr = stderr

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
                self.setBusy(true)
                self.updateStatus("起動準備中です。アプリ本体が立ち上がるまで少し待ってください。")
                self.appendLog("バックエンドを起動します。")
                try process.run()
                self.backendProcess = process
                self.waitForBackendAndLoad()
            } catch {
                self.setBusy(false)
                self.updateStatus("起動に失敗しました: \(error.localizedDescription)")
            }
        }

        if usesBundledRuntime && !runtimeLooksInstalled() {
            ensureBundledRuntimeInstalled { success in
                if success {
                    launch()
                }
            }
            return
        }

        launch()
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

    @objc private func handleSelectionChange() {
        persistSelectionDefaults()
        let qwenLabelText = qwenOptions[max(0, qwenPopup.indexOfSelectedItem)].label
        updateStatus("選択中: \(qwenLabelText)  /  ASR: \(selectedASRModel())")
    }

    @objc private func handleStart() {
        startBackendIfNeeded()
    }

    @objc private func handleSetup() {
        if usesBundledRuntime {
            ensureBundledRuntimeInstalled(force: true) { _ in }
            return
        }

        updateStatus("セットアップを始めます。初回は数分かかることがあります。")
        appendLog("セットアップを開始します。")
        runShellScript("setup.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("セットアップ完了です。②起動 を押してください。")
            } else {
                self?.updateStatus("セットアップに失敗しました。下のログを確認してください。")
            }
        }
    }

    @objc private func handleUpdate() {
        if usesBundledRuntime {
            updateStatus("内蔵アプリ版ではアプリ内更新は使えません。最新リリースを開きます。")
            openURL(releasesURL)
            return
        }

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
        let install = { [weak self] in
            guard let self else { return }
            guard self.isSetupComplete() else {
                self.updateStatus("先に『初回セットアップ』を実行してください。")
                return
            }
            self.updateStatus("ローカル文字起こしを追加します。")
            self.appendLog("ローカル文字起こしの導入を開始します。")
            self.runShellScript("install_local_asr.command") { [weak self] code in
                if code == 0 {
                    self?.updateStatus("ローカル文字起こしの追加が終わりました。")
                } else {
                    self?.updateStatus("ローカル文字起こしの追加に失敗しました。ログを確認してください。")
                }
            }
        }

        if usesBundledRuntime && !runtimeLooksInstalled() {
            ensureBundledRuntimeInstalled { success in
                if success {
                    install()
                }
            }
            return
        }

        install()
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
