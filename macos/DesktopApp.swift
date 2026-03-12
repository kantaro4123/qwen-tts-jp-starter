import AppKit
import Foundation
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private struct QwenOption {
        let label: String
        let modelID: String
    }

    private struct ReleaseInfo {
        let version: String
        let htmlURL: URL
        let zipAssetURL: URL?
    }

    private enum ScreenMode {
        case setup
        case main
    }

    private let qwenOptions: [QwenOption] = [
        .init(label: "高精度 1.7B", modelID: "Qwen/Qwen3-TTS-12Hz-1.7B-Base"),
        .init(label: "軽量 0.6B", modelID: "Qwen/Qwen3-TTS-12Hz-0.6B-Base"),
    ]
    private let asrOptions = ["small", "base", "medium"]
    private let backendPort = "7860"
    private let repositoryURL = URL(string: "https://github.com/kantaro4123/qwen-tts-jp-starter")!
    private let releasesURL = URL(string: "https://github.com/kantaro4123/qwen-tts-jp-starter/releases/latest")!
    private let releasesAPIURL = URL(string: "https://api.github.com/repos/kantaro4123/qwen-tts-jp-starter/releases/latest")!
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
    private var toolbarTitleLabel: NSTextField!
    private var toolbarSubtitleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var updateButton: NSButton!
    private var settingsButton: NSButton!
    private var logsButton: NSButton!
    private var repoButton: NSButton!
    private var contentContainer: NSView!
    private var setupScreenView: NSView!
    private var mainScreenView: NSView!
    private var setupPrimaryButton: NSButton!
    private var setupStartButton: NSButton!
    private var setupStatusLabel: NSTextField!
    private var setupModelSummaryLabel: NSTextField!
    private var setupAsrSummaryLabel: NSTextField!
    private var webView: WKWebView!
    private var settingsPanel: NSPanel?
    private var settingsQwenPopup: NSPopUpButton?
    private var settingsAsrPopup: NSPopUpButton?
    private var settingsSummaryLabel: NSTextField?
    private var logPanel: NSPanel?
    private var logTextView: NSTextView?

    private var activeTask: Process?
    private var backendProcess: Process?
    private var backendStdout: Pipe?
    private var backendStderr: Pipe?
    private var latestReleaseInfo: ReleaseInfo?
    private var currentScreenMode: ScreenMode = .setup

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
        loadSelectionDefaultsIfNeeded()
        buildWindow()
        presentScreen(.setup)
        loadSetupSummary()
        updateStatus(initialStatusMessage())
        appendLog("アプリを起動しました。")
        appendLog(usesBundledRuntime ? "内蔵ランタイム版として起動しています。" : "開発モードとして起動しています。")
        fetchLatestReleaseInfo(showCurrentMessage: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateProcess(&activeTask)
        terminateProcess(&backendProcess)
    }

    private func currentVersionString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? bundledRuntimeVersion
    }

    private func initialStatusMessage() -> String {
        if isSetupComplete() {
            return "セットアップ済みです。『起動する』を押すとメイン画面へ進みます。"
        }
        return "まず『セットアップする』を押してください。完了したら『起動する』でメイン画面を開けます。"
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1320, height: 900)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "かんたんボイスクローン"
        window.center()
        window.minSize = NSSize(width: 1100, height: 760)

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let headerCard = cardView(cornerRadius: 22)
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        toolbarTitleLabel = label("かんたんボイスクローン", fontSize: 26, weight: .bold)
        toolbarSubtitleLabel = wrappingLabel("セットアップと音声生成を、迷わず分けて進められる macOS アプリです。", fontSize: 13, weight: .regular)
        titleStack.addArrangedSubview(toolbarTitleLabel)
        titleStack.addArrangedSubview(toolbarSubtitleLabel)

        updateButton = toolbarButton("アップデート", filled: true, action: #selector(handleInstallUpdate))
        updateButton.isHidden = true
        repoButton = toolbarButton("GitHub を開く", filled: false, action: #selector(handleOpenRepository))
        logsButton = toolbarButton("ログ", filled: false, action: #selector(handleShowLogs))
        settingsButton = toolbarButton("設定", filled: false, action: #selector(handleShowSettings))

        let buttonStack = NSStackView(views: [updateButton, repoButton, logsButton, settingsButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = wrappingLabel("準備中...", fontSize: 13, weight: .medium)
        statusLabel.textColor = NSColor(calibratedRed: 0.18, green: 0.40, blue: 0.30, alpha: 1)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        headerCard.addSubview(titleStack)
        headerCard.addSubview(buttonStack)
        headerCard.addSubview(statusLabel)
        headerCard.addSubview(spinner)

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        setupScreenView = buildSetupScreen()
        mainScreenView = buildMainScreen()
        [setupScreenView, mainScreenView].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        root.addSubview(headerCard)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),

            headerCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerCard.topAnchor.constraint(equalTo: root.topAnchor),

            titleStack.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 22),
            titleStack.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 18),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            buttonStack.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -22),
            buttonStack.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 20),

            statusLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 22),
            statusLabel.topAnchor.constraint(equalTo: titleStack.bottomAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -18),

            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -22),

            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 18),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    private func buildSetupScreen() -> NSView {
        let container = NSView()

        let mainCard = cardView(cornerRadius: 28)
        container.addSubview(mainCard)

        let badge = pillLabel("はじめてでも迷わないセットアップ")
        let title = label("まずはセットアップしてから起動します", fontSize: 34, weight: .bold)
        let body = wrappingLabel(
            "この画面では、初回セットアップと起動だけに集中できます。設定やログは別画面で開けるので、ここでは順番どおりに進めれば大丈夫です。",
            fontSize: 15,
            weight: .regular
        )
        body.maximumNumberOfLines = 0

        let summaryCard = highlightCard()
        let summaryTitle = label("現在の設定", fontSize: 15, weight: .semibold)
        setupModelSummaryLabel = wrappingLabel("Qwen-TTS: 準備中", fontSize: 14, weight: .medium)
        setupAsrSummaryLabel = wrappingLabel("文字起こし: 準備中", fontSize: 14, weight: .medium)
        [summaryTitle, setupModelSummaryLabel, setupAsrSummaryLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            summaryCard.addSubview($0)
        }

        setupStatusLabel = wrappingLabel("初回セットアップ前です。", fontSize: 14, weight: .medium)
        setupStatusLabel.textColor = NSColor(calibratedRed: 0.18, green: 0.41, blue: 0.31, alpha: 1)

        setupPrimaryButton = primaryButton("セットアップする", action: #selector(handleSetup))
        setupStartButton = secondaryLargeButton("起動する", action: #selector(handleStart))
        let actionsRow = NSStackView(views: [setupPrimaryButton, setupStartButton])
        actionsRow.orientation = .horizontal
        actionsRow.distribution = .fillEqually
        actionsRow.spacing = 14
        actionsRow.translatesAutoresizingMaskIntoConstraints = false

        let helper = wrappingLabel(
            "困ったら上の『設定』でモデルを変えられます。『ログ』を押すと別画面で詳細を確認できます。",
            fontSize: 13,
            weight: .regular
        )
        helper.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)

        [badge, title, body, summaryCard, setupStatusLabel, actionsRow, helper].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            mainCard.addSubview($0)
        }

        NSLayoutConstraint.activate([
            mainCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 90),
            mainCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -90),
            mainCard.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
            mainCard.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -36),

            badge.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            badge.topAnchor.constraint(equalTo: mainCard.topAnchor, constant: 30),

            title.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),

            body.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),

            summaryCard.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            summaryCard.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),
            summaryCard.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 22),

            summaryTitle.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 18),
            summaryTitle.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 16),
            setupModelSummaryLabel.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 18),
            setupModelSummaryLabel.topAnchor.constraint(equalTo: summaryTitle.bottomAnchor, constant: 10),
            setupModelSummaryLabel.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -18),
            setupAsrSummaryLabel.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 18),
            setupAsrSummaryLabel.topAnchor.constraint(equalTo: setupModelSummaryLabel.bottomAnchor, constant: 8),
            setupAsrSummaryLabel.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -18),
            setupAsrSummaryLabel.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: -16),

            setupStatusLabel.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            setupStatusLabel.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 22),
            setupStatusLabel.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),

            actionsRow.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            actionsRow.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),
            actionsRow.topAnchor.constraint(equalTo: setupStatusLabel.bottomAnchor, constant: 20),
            actionsRow.heightAnchor.constraint(equalToConstant: 54),

            helper.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            helper.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),
            helper.topAnchor.constraint(equalTo: actionsRow.bottomAnchor, constant: 18),
            helper.bottomAnchor.constraint(equalTo: mainCard.bottomAnchor, constant: -28),
        ])

        return container
    }

    private func buildMainScreen() -> NSView {
        let container = NSView()
        let card = cardView(cornerRadius: 24)
        container.addSubview(card)

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        card.addSubview(webView)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        webView.loadHTMLString(
            """
            <html><body style=\"font-family:-apple-system; background:#f4f6f3; color:#203027; display:flex; align-items:center; justify-content:center; height:100vh; margin:0;\">
            <div style=\"text-align:center; max-width:560px; padding:0 24px;\">
              <h1 style=\"font-size:30px; margin-bottom:14px;\">起動すると、ここに音声生成画面が出ます</h1>
              <p style=\"font-size:15px; line-height:1.75; color:#496153;\">まだ起動していない場合は、上の状態表示を見ながら『起動する』を押してください。</p>
            </div>
            </body></html>
            """,
            baseURL: nil
        )

        return container
    }

    private func presentScreen(_ mode: ScreenMode) {
        currentScreenMode = mode
        setupScreenView.isHidden = mode != .setup
        mainScreenView.isHidden = mode != .main
        switch mode {
        case .setup:
            toolbarSubtitleLabel.stringValue = "最初はこの画面でセットアップし、終わったら起動します。"
        case .main:
            toolbarSubtitleLabel.stringValue = "音声生成画面を広く表示しています。設定やログは上のボタンから開けます。"
        }
    }

    private func cardView(cornerRadius: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 0.96).cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        return view
    }

    private func highlightCard() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.95, alpha: 1).cgColor
        view.layer?.cornerRadius = 18
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.89, blue: 0.84, alpha: 1).cgColor
        return view
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
        field.textColor = NSColor(calibratedWhite: 0.30, alpha: 1)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func pillLabel(_ text: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.90, alpha: 1).cgColor
        container.layer?.cornerRadius = 999
        container.translatesAutoresizingMaskIntoConstraints = false

        let field = label(text, fontSize: 12, weight: .semibold)
        field.textColor = NSColor(calibratedRed: 0.14, green: 0.38, blue: 0.26, alpha: 1)
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    private func toolbarButton(_ title: String, filled: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        if filled {
            button.contentTintColor = .white
            button.bezelColor = .systemBlue
        }
        return button
    }

    private func primaryButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.contentTintColor = .white
        button.bezelColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.34, alpha: 1)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func secondaryLargeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func storedQwenModelID() -> String {
        selectionDefaults.string(forKey: qwenDefaultsKey) ?? qwenOptions[0].modelID
    }

    private func storedASRModel() -> String {
        selectionDefaults.string(forKey: asrDefaultsKey) ?? asrOptions[0]
    }

    private func currentQwenOption() -> QwenOption {
        qwenOptions.first(where: { $0.modelID == storedQwenModelID() }) ?? qwenOptions[0]
    }

    private func loadSelectionDefaultsIfNeeded() {
        if selectionDefaults.string(forKey: qwenDefaultsKey) == nil {
            selectionDefaults.set(qwenOptions[0].modelID, forKey: qwenDefaultsKey)
        }
        if selectionDefaults.string(forKey: asrDefaultsKey) == nil {
            selectionDefaults.set(asrOptions[0], forKey: asrDefaultsKey)
        }
    }

    private func loadSetupSummary() {
        setupModelSummaryLabel?.stringValue = "Qwen-TTS: \(currentQwenOption().label)"
        setupAsrSummaryLabel?.stringValue = "文字起こしモデル: \(storedASRModel())"
        if isSetupComplete() {
            setupStatusLabel?.stringValue = "セットアップ済みです。このまま『起動する』を押せます。"
        } else {
            setupStatusLabel?.stringValue = "初回セットアップ前です。まずは『セットアップする』を押してください。"
        }
        updateSettingsSummaryLabel()
    }

    private func updateSettingsSummaryLabel() {
        settingsSummaryLabel?.stringValue = "現在: \(currentQwenOption().label) / 文字起こし \(storedASRModel())"
    }

    private func settingsPayload() -> Data? {
        let payload: [String: String] = [
            "qwen_tts_model_id": storedQwenModelID(),
            "local_asr_model": storedASRModel(),
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    }

    private func setBusy(_ busy: Bool) {
        [setupPrimaryButton, setupStartButton, settingsButton, logsButton, repoButton, updateButton].forEach { $0?.isEnabled = !busy }
        settingsQwenPopup?.isEnabled = !busy
        settingsAsrPopup?.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = text
            self.setupStatusLabel?.stringValue = text
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async {
            guard !text.isEmpty else { return }
            if self.logPanel == nil {
                self.buildLogPanelIfNeeded()
            }
            let attributed = NSAttributedString(string: text + "\n")
            self.logTextView?.textStorage?.append(attributed)
            self.logTextView?.scrollToEndOfDocument(nil)
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
        let configDir = currentProjectDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let settingsURL = configDir.appendingPathComponent("settings.json")
        if let data = settingsPayload() {
            try data.write(to: settingsURL)
            appendLog("設定を書き込みました: \(currentQwenOption().modelID) / ASR \(storedASRModel())")
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
                    for item in contents { try fm.removeItem(at: item) }
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
        updateStatus("セットアップ中です。初回は少し時間がかかります。")
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
                        self.updateStatus("セットアップに失敗しました。")
                        completion(false)
                    }
                    return
                }

                try self.bundledRuntimeVersion.write(to: self.runtimeVersionFileURL, atomically: true, encoding: .utf8)
                try self.writeRuntimeSettings()
                self.ensureBundledModelBundleInstalled(force: force) { success in
                    self.setBusy(false)
                    if success {
                        self.updateStatus("セットアップ完了です。続けて『起動する』を押してください。")
                        self.appendLog("内蔵ランタイムの展開が完了しました。")
                        self.loadSetupSummary()
                    } else {
                        self.updateStatus("ランタイムは展開できましたが、同梱モデルの展開に失敗しました。")
                    }
                    completion(success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.updateStatus("セットアップに失敗しました: \(error.localizedDescription)")
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
                self?.loadSetupSummary()
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
            presentScreen(.main)
            waitForBackendAndLoad()
            return
        }

        let launch = { [weak self] in
            guard let self else { return }
            guard self.isSetupComplete() else {
                self.updateStatus("先にセットアップを完了してください。")
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
                    self?.presentScreen(.setup)
                    self?.updateStatus("音声生成画面が停止しました。もう一度『起動する』を押すと再開できます。")
                    self?.appendLog("バックエンドが終了しました。終了コード: \(task.terminationStatus)")
                }
            }

            do {
                self.setBusy(true)
                self.updateStatus("起動準備中です。音声生成画面が開くまで少し待ってください。")
                self.appendLog("バックエンドを起動します。")
                try process.run()
                self.backendProcess = process
                self.presentScreen(.main)
                self.waitForBackendAndLoad()
            } catch {
                self.setBusy(false)
                self.presentScreen(.setup)
                self.updateStatus("起動に失敗しました: \(error.localizedDescription)")
            }
        }

        if usesBundledRuntime && !runtimeLooksInstalled() {
            ensureBundledRuntimeInstalled { success in
                if success { launch() }
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
                    if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) { success = true }
                    semaphore.signal()
                }.resume()
                _ = semaphore.wait(timeout: .now() + 3)

                if success {
                    DispatchQueue.main.async {
                        self?.setBusy(false)
                        self?.presentScreen(.main)
                        self?.updateStatus("起動しました。設定とログは上のボタンから開けます。")
                        self?.webView.load(URLRequest(url: targetURL))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.8)
            }

            DispatchQueue.main.async {
                self?.setBusy(false)
                self?.presentScreen(.setup)
                self?.updateStatus("起動に時間がかかっています。『ログ』で詳細を確認してください。")
            }
        }
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func buildSettingsPanelIfNeeded() {
        guard settingsPanel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "設定"
        panel.center()

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let title = label("設定", fontSize: 24, weight: .bold)
        let subtitle = wrappingLabel("ここでモデルの変更や、README・リリースページへの移動ができます。", fontSize: 13, weight: .regular)
        settingsSummaryLabel = wrappingLabel("", fontSize: 13, weight: .medium)

        let qwenLabel = label("Qwen-TTS モデル", fontSize: 13, weight: .semibold)
        let qwenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        qwenPopup.translatesAutoresizingMaskIntoConstraints = false
        qwenPopup.addItems(withTitles: qwenOptions.map(\.label))
        if let index = qwenOptions.firstIndex(where: { $0.modelID == storedQwenModelID() }) {
            qwenPopup.selectItem(at: index)
        }
        settingsQwenPopup = qwenPopup

        let asrLabel = label("文字起こしモデル", fontSize: 13, weight: .semibold)
        let asrPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        asrPopup.translatesAutoresizingMaskIntoConstraints = false
        asrPopup.addItems(withTitles: asrOptions)
        if let index = asrOptions.firstIndex(of: storedASRModel()) {
            asrPopup.selectItem(at: index)
        }
        settingsAsrPopup = asrPopup

        let saveButton = primaryButton("設定を保存", action: #selector(handleSaveSettings))
        let reopenASRButton = secondaryLargeButton("文字起こしを入れ直す", action: #selector(handleInstallASR))
        let openReadmeButton = secondaryLargeButton("README を開く", action: #selector(handleHelp))
        let openReleasesButton = secondaryLargeButton("リリースを見る", action: #selector(handleOpenReleases))

        [title, subtitle, settingsSummaryLabel!, qwenLabel, qwenPopup, asrLabel, asrPopup, saveButton, reopenASRButton, openReadmeButton, openReleasesButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -24),

            title.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            title.topAnchor.constraint(equalTo: root.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settingsSummaryLabel!.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settingsSummaryLabel!.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            settingsSummaryLabel!.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            qwenLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            qwenLabel.topAnchor.constraint(equalTo: settingsSummaryLabel!.bottomAnchor, constant: 18),
            qwenPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            qwenPopup.topAnchor.constraint(equalTo: qwenLabel.bottomAnchor, constant: 8),
            qwenPopup.widthAnchor.constraint(equalToConstant: 220),

            asrLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            asrLabel.topAnchor.constraint(equalTo: qwenPopup.bottomAnchor, constant: 18),
            asrPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            asrPopup.topAnchor.constraint(equalTo: asrLabel.bottomAnchor, constant: 8),
            asrPopup.widthAnchor.constraint(equalToConstant: 220),

            saveButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            saveButton.topAnchor.constraint(equalTo: asrPopup.bottomAnchor, constant: 24),
            saveButton.widthAnchor.constraint(equalToConstant: 160),

            reopenASRButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 12),
            reopenASRButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            reopenASRButton.widthAnchor.constraint(equalToConstant: 180),

            openReadmeButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            openReadmeButton.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 12),
            openReadmeButton.widthAnchor.constraint(equalToConstant: 160),

            openReleasesButton.leadingAnchor.constraint(equalTo: openReadmeButton.trailingAnchor, constant: 12),
            openReleasesButton.centerYAnchor.constraint(equalTo: openReadmeButton.centerYAnchor),
            openReleasesButton.widthAnchor.constraint(equalToConstant: 180),
        ])

        settingsPanel = panel
        updateSettingsSummaryLabel()
    }

    private func buildLogPanelIfNeeded() {
        guard logPanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "ログ"
        panel.center()

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        scrollView.documentView = textView

        panel.contentView?.addSubview(scrollView)
        logPanel = panel
        logTextView = textView
    }

    private func versionTuple(_ text: String) -> [Int] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = versionTuple(lhs)
        let right = versionTuple(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func fetchLatestReleaseInfo(showCurrentMessage: Bool) {
        var request = URLRequest(url: releasesAPIURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.appendLog("更新確認に失敗しました: \(error.localizedDescription)") }
                return
            }
            guard let data else { return }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let htmlURLText = json["html_url"] as? String,
                      let htmlURL = URL(string: htmlURLText) else {
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zipURL = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
                let info = ReleaseInfo(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), htmlURL: htmlURL, zipAssetURL: zipURL.flatMap(URL.init(string:)))
                DispatchQueue.main.async {
                    self.latestReleaseInfo = info
                    let hasUpdate = self.isVersion(info.version, newerThan: self.currentVersionString())
                    self.updateButton.isHidden = !hasUpdate
                    if hasUpdate {
                        self.updateButton.title = "アップデート"
                        self.updateStatus("新しいバージョン \(info.version) があります。青いボタンから更新できます。")
                    } else if showCurrentMessage {
                        self.updateStatus("最新版です。")
                    }
                }
            } catch {
                DispatchQueue.main.async { self.appendLog("更新確認の解析に失敗しました: \(error.localizedDescription)") }
            }
        }.resume()
    }

    private func performInAppUpdate() {
        guard let info = latestReleaseInfo else {
            fetchLatestReleaseInfo(showCurrentMessage: true)
            return
        }
        guard let zipURL = info.zipAssetURL else {
            updateStatus("ZIP 配布物が見つからないため、リリースページを開きます。")
            openURL(info.htmlURL)
            return
        }

        setBusy(true)
        updateStatus("アップデートをダウンロードしています…")
        appendLog("アップデートを開始します: \(zipURL.absoluteString)")

        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.updateStatus("アップデートのダウンロードに失敗しました: \(error.localizedDescription)")
                }
                return
            }
            guard let tempURL else {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.updateStatus("アップデートファイルを取得できませんでした。")
                }
                return
            }
            do {
                let fm = FileManager.default
                let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let zipPath = tempDir.appendingPathComponent("latest.zip")
                try fm.moveItem(at: tempURL, to: zipPath)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zipPath.path, tempDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZIP の展開に失敗しました。"])
                }

                guard let appURL = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "新しいアプリ本体が見つかりませんでした。"])
                }

                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.installDownloadedApp(from: appURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.updateStatus("アップデートの準備に失敗しました: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func installDownloadedApp(from appURL: URL) {
        let targetAppURL = Bundle.main.bundleURL
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("kantan-update-\(UUID().uuidString).sh")
        let source = appURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let target = targetAppURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let adminCommand = "/bin/rm -rf '\(target)'; /usr/bin/ditto '\(source)' '\(target)'; /usr/bin/xattr -dr com.apple.quarantine '\(target)' >/dev/null 2>&1 || true; /usr/bin/open '\(target)'"
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = [
            "#!/bin/zsh",
            "set -e",
            "sleep 2",
            "SRC='\(source)'",
            "DST='\(target)'",
            "PARENT_DIR=\"$(dirname \\\"$DST\\\")\"",
            "if [ -w \"$PARENT_DIR\" ]; then",
            "  /bin/rm -rf \"$DST\"",
            "  /usr/bin/ditto \"$SRC\" \"$DST\"",
            "  /usr/bin/xattr -dr com.apple.quarantine \"$DST\" >/dev/null 2>&1 || true",
            "  /usr/bin/open \"$DST\"",
            "else",
            "  /usr/bin/osascript -e \"do shell script \\\"\(adminCommand)\\\" with administrator privileges\"",
            "fi",
        ].joined(separator: "\n")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run()
            updateStatus("アップデートを適用しています。アプリを入れ替えて再起動します。")
            NSApp.terminate(nil)
        } catch {
            updateStatus("アップデートの適用に失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func handleSetup() {
        if usesBundledRuntime {
            ensureBundledRuntimeInstalled(force: true) { _ in }
            return
        }
        updateStatus("セットアップを始めます。初回は時間がかかります。")
        appendLog("セットアップを開始します。")
        runShellScript("setup.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("セットアップ完了です。次は『起動する』を押してください。")
            } else {
                self?.updateStatus("セットアップに失敗しました。『ログ』を開いて確認してください。")
            }
        }
    }

    @objc private func handleStart() {
        startBackendIfNeeded()
    }

    @objc private func handleShowSettings() {
        buildSettingsPanelIfNeeded()
        if let panel = settingsPanel {
            updateSettingsSummaryLabel()
            window.beginSheet(panel)
        }
    }

    @objc private func handleShowLogs() {
        buildLogPanelIfNeeded()
        logPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleOpenRepository() {
        openURL(repositoryURL)
    }

    @objc private func handleOpenReleases() {
        openURL(releasesURL)
    }

    @objc private func handleHelp() {
        openURL(readmeURL())
    }

    @objc private func handleInstallASR() {
        let install = { [weak self] in
            guard let self else { return }
            guard self.isSetupComplete() else {
                self.updateStatus("先にセットアップを完了してください。")
                return
            }
            self.updateStatus("文字起こし機能を入れ直しています。")
            self.appendLog("ローカル文字起こしの再インストールを開始します。")
            self.runShellScript("install_local_asr.command") { [weak self] code in
                if code == 0 {
                    self?.updateStatus("文字起こし機能の準備が終わりました。")
                } else {
                    self?.updateStatus("文字起こし機能の再インストールに失敗しました。")
                }
            }
        }

        if usesBundledRuntime && !runtimeLooksInstalled() {
            ensureBundledRuntimeInstalled { success in
                if success { install() }
            }
            return
        }
        install()
    }

    @objc private func handleSaveSettings() {
        guard let qwenPopup = settingsQwenPopup, let asrPopup = settingsAsrPopup else { return }
        let qwenIndex = max(0, qwenPopup.indexOfSelectedItem)
        let asrIndex = max(0, asrPopup.indexOfSelectedItem)
        selectionDefaults.set(qwenOptions[qwenIndex].modelID, forKey: qwenDefaultsKey)
        selectionDefaults.set(asrOptions[asrIndex], forKey: asrDefaultsKey)
        do {
            try writeRuntimeSettings()
            updateStatus("設定を保存しました。")
            loadSetupSummary()
        } catch {
            updateStatus("設定の保存に失敗しました: \(error.localizedDescription)")
        }
    }

    @objc private func handleInstallUpdate() {
        performInAppUpdate()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        presentScreen(.main)
        updateStatus("音声生成画面が開きました。設定やログは上のボタンから開けます。")
        webView.evaluateJavaScript("document.querySelectorAll('footer').forEach((node) => node.remove())")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
