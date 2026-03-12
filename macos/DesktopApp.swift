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
    private let fileManager = FileManager()

    private let bundleFallbackProjectDir = Bundle.main.bundleURL.deletingLastPathComponent()

    private lazy var appSupportBaseURL: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
    private var mainLoadingOverlay: NSView!
    private var settingsPanel: NSPanel?
    private var settingsQwenPopup: NSPopUpButton?
    private var settingsAsrPopup: NSPopUpButton?
    private var settingsSummaryLabel: NSTextField?
    private var logPanel: NSPanel?
    private var logTextView: NSTextView?
    private var modeBadgeLabel: NSTextField?

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
        loadSetupSummary()
        appendLog("アプリを起動しました。")
        appendLog(usesBundledRuntime ? "内蔵ランタイム版として起動しています。" : "開発モードとして起動しています。")
        fetchLatestReleaseInfo(showCurrentMessage: false)
        if !isSetupComplete() {
            presentScreen(.setup)
            updateStatus(initialStatusMessage())
        } else if bundledRuntimeNeedsRefresh() {
            presentScreen(.main)
            updateStatus("アプリ更新を反映しています。初回だけ少し待ってください。")
            ensureBundledRuntimeInstalled(force: true) { [weak self] success in
                guard let self else { return }
                if success {
                    self.startBackendIfNeeded()
                } else {
                    self.presentScreen(.setup)
                    self.updateStatus("更新用ランタイムの準備に失敗しました。もう一度セットアップしてください。")
                }
            }
        } else {
            presentScreen(.main)
            updateStatus("前回のセットアップが見つかりました。音声生成画面を開いています。")
            startBackendIfNeeded()
        }
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
            return "セットアップ済みです。音声生成画面を開いています。"
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
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.94, alpha: 1).cgColor
        window.contentView = root

        let headerCard = cardView(cornerRadius: 18)
        headerCard.layer?.shadowRadius = 10
        headerCard.layer?.shadowOpacity = 0.05

        let eyebrow = label("KANTAN VOICE CLONE", fontSize: 11, weight: .semibold)
        eyebrow.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        toolbarTitleLabel = label("かんたんボイスクローン", fontSize: 24, weight: .bold)
        toolbarSubtitleLabel = wrappingLabel("セットアップと音声生成を迷わず切り替えられる macOS アプリです。", fontSize: 12, weight: .regular)
        toolbarSubtitleLabel.textColor = NSColor(calibratedWhite: 0.38, alpha: 1)
        let badgeContainer = pillLabel("セットアップ")
        modeBadgeLabel = badgeContainer.subviews.compactMap { $0 as? NSTextField }.first

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
        statusLabel.textColor = NSColor(calibratedRed: 0.14, green: 0.35, blue: 0.24, alpha: 1)
        statusLabel.maximumNumberOfLines = 1

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        [eyebrow, toolbarTitleLabel, badgeContainer, buttonStack].forEach { headerCard.addSubview($0) }
        headerCard.addSubview(statusLabel)
        headerCard.addSubview(toolbarSubtitleLabel)
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
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),

            headerCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerCard.topAnchor.constraint(equalTo: root.topAnchor),

            eyebrow.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 20),
            eyebrow.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 14),

            toolbarTitleLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 20),
            toolbarTitleLabel.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 2),

            badgeContainer.leadingAnchor.constraint(equalTo: toolbarTitleLabel.trailingAnchor, constant: 12),
            badgeContainer.centerYAnchor.constraint(equalTo: toolbarTitleLabel.centerYAnchor),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            buttonStack.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -18),
            buttonStack.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 18),

            toolbarSubtitleLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 20),
            toolbarSubtitleLabel.topAnchor.constraint(equalTo: toolbarTitleLabel.bottomAnchor, constant: 6),
            toolbarSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            statusLabel.leadingAnchor.constraint(equalTo: headerCard.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: toolbarSubtitleLabel.bottomAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -12),

            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: headerCard.trailingAnchor, constant: -18),

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
        let title = label("最初はこの画面だけで大丈夫です", fontSize: 34, weight: .bold)
        let body = wrappingLabel(
            "初回は 1 回だけセットアップを行います。完了後はこのアプリがそのままメイン画面へ進み、次回以降は起動直後から音声生成画面を開きます。",
            fontSize: 15,
            weight: .regular
        )
        body.maximumNumberOfLines = 0

        let summaryCard = highlightCard()
        let stepsCard = cardView(cornerRadius: 22)
        let summaryTitle = label("現在の設定", fontSize: 15, weight: .semibold)
        setupModelSummaryLabel = wrappingLabel("Qwen-TTS: 準備中", fontSize: 14, weight: .medium)
        setupAsrSummaryLabel = wrappingLabel("文字起こし: 準備中", fontSize: 14, weight: .medium)
        [summaryTitle, setupModelSummaryLabel, setupAsrSummaryLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            summaryCard.addSubview($0)
        }

        let stepsTitle = label("進め方", fontSize: 15, weight: .semibold)
        let stepsStack = NSStackView(views: [
            setupStepRow(number: "1", title: "セットアップする", description: "必要な実行環境を用意します。初回は少し時間がかかります。"),
            setupStepRow(number: "2", title: "自動でメイン画面へ", description: "セットアップ完了後はそのまま音声生成画面を開きます。"),
            setupStepRow(number: "3", title: "次回以降はすぐ使える", description: "2 回目以降はこの画面を飛ばして、起動直後にメインへ入ります。"),
        ])
        stepsStack.orientation = .vertical
        stepsStack.spacing = 12
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        [stepsTitle, stepsStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            stepsCard.addSubview($0)
        }

        setupStatusLabel = wrappingLabel("初回セットアップ前です。", fontSize: 14, weight: .medium)
        setupStatusLabel.textColor = NSColor(calibratedRed: 0.18, green: 0.41, blue: 0.31, alpha: 1)

        setupPrimaryButton = primaryButton("セットアップする", action: #selector(handleSetup))
        setupStartButton = secondaryLargeButton("すでに完了しているので起動する", action: #selector(handleStart))
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

        [badge, title, body, summaryCard, stepsCard, setupStatusLabel, actionsRow, helper].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            mainCard.addSubview($0)
        }

        NSLayoutConstraint.activate([
            mainCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 54),
            mainCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -54),
            mainCard.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            mainCard.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),

            badge.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            badge.topAnchor.constraint(equalTo: mainCard.topAnchor, constant: 30),

            title.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),

            body.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),

            summaryCard.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            summaryCard.widthAnchor.constraint(equalTo: mainCard.widthAnchor, multiplier: 0.44),
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

            stepsCard.leadingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: 18),
            stepsCard.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -34),
            stepsCard.topAnchor.constraint(equalTo: summaryCard.topAnchor),
            stepsCard.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor),

            stepsTitle.leadingAnchor.constraint(equalTo: stepsCard.leadingAnchor, constant: 20),
            stepsTitle.topAnchor.constraint(equalTo: stepsCard.topAnchor, constant: 18),
            stepsStack.leadingAnchor.constraint(equalTo: stepsCard.leadingAnchor, constant: 20),
            stepsStack.trailingAnchor.constraint(equalTo: stepsCard.trailingAnchor, constant: -20),
            stepsStack.topAnchor.constraint(equalTo: stepsTitle.bottomAnchor, constant: 14),
            stepsStack.bottomAnchor.constraint(lessThanOrEqualTo: stepsCard.bottomAnchor, constant: -18),

            setupStatusLabel.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 34),
            setupStatusLabel.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 24),
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
        mainLoadingOverlay = buildMainLoadingOverlay()
        card.addSubview(mainLoadingOverlay)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            webView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),

            mainLoadingOverlay.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            mainLoadingOverlay.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            mainLoadingOverlay.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            mainLoadingOverlay.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        webView.loadHTMLString(
            """
            <html><body style=\"font-family:-apple-system; background:#f4f6f1; color:#1f2c22; margin:0; min-height:100vh; display:flex; align-items:stretch;\">
            <div style=\"display:grid; grid-template-columns:1.6fr 0.95fr; gap:18px; width:100%; padding:24px;\">
              <section style=\"background:#ffffff; border:1px solid #d7dfd4; border-radius:24px; padding:28px; box-shadow:0 12px 40px rgba(26,42,31,0.06); display:flex; flex-direction:column; justify-content:center;\">
                <div style=\"display:inline-flex; align-items:center; width:max-content; padding:8px 12px; border-radius:999px; background:#e7efe7; color:#2c5a42; font-size:12px; font-weight:700; margin-bottom:16px;\">音声生成画面を準備しています</div>
                <h1 style=\"font-size:36px; line-height:1.18; margin:0 0 14px;\">準備ができ次第、この場所にそのままメイン画面が表示されます。</h1>
                <p style=\"font-size:15px; line-height:1.8; color:#56655b; margin:0; max-width:720px;\">セットアップ済みなら通常は自動で起動します。読み込みに少し時間がかかる場合は、右上の「ログ」で状態を確認できます。モデル変更や文字起こしの再設定は「設定」から行えます。</p>
              </section>
              <aside style=\"display:flex; flex-direction:column; gap:18px;\">
                <div style=\"background:#ffffff; border:1px solid #d7dfd4; border-radius:22px; padding:22px;\">
                  <div style=\"font-size:15px; font-weight:700; margin-bottom:10px;\">この画面でできること</div>
                  <ul style=\"margin:0; padding-left:18px; color:#4f6056; line-height:1.8; font-size:14px;\">
                    <li>参照音声のアップロード</li>
                    <li>文字起こしと読み上げ文の入力</li>
                    <li>音声生成と保存</li>
                  </ul>
                </div>
                <div style=\"background:#f0f5ef; border:1px solid #d1ddd2; border-radius:22px; padding:22px;\">
                  <div style=\"font-size:15px; font-weight:700; margin-bottom:8px;\">困ったとき</div>
                  <div style=\"font-size:14px; line-height:1.75; color:#506358;\">起動が止まって見えるときはログを確認してください。更新がある場合は、上部バーの青いボタンからそのままアップデートできます。</div>
                </div>
              </aside>
            </div>
            </body></html>
            """,
            baseURL: nil
        )

        return container
    }

    private func buildMainLoadingOverlay() -> NSView {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.95, alpha: 0.98).cgColor
        overlay.layer?.cornerRadius = 18

        let badge = pillLabel("音声生成画面を準備中")
        let title = label("このウィンドウの中に、そのまま本体画面が表示されます。", fontSize: 30, weight: .bold)
        let body = wrappingLabel("通常は自動で起動します。読み込みに時間がかかるときは右上の『ログ』で状態を確認できます。モデル変更や文字起こしの入れ直しは『設定』から行えます。", fontSize: 14, weight: .regular)

        let leftCard = highlightCard()
        let rightCard = cardView(cornerRadius: 22)
        [leftCard, rightCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview($0)
        }

        let leftTitle = label("ここでできること", fontSize: 15, weight: .semibold)
        let leftBody = wrappingLabel("参照音声のアップロード、文字起こし、読み上げ文の入力、音声生成まで、このままアプリ内で進めます。", fontSize: 13, weight: .regular)
        let rightTitle = label("困ったとき", fontSize: 15, weight: .semibold)
        let rightBody = wrappingLabel("起動が止まって見える場合はログを確認してください。新しいリリースがあるときは、上の青いボタンからそのまま更新できます。", fontSize: 13, weight: .regular)
        [leftTitle, leftBody].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            leftCard.addSubview($0)
        }
        [rightTitle, rightBody].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rightCard.addSubview($0)
        }

        [badge, title, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview($0)
        }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            badge.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 28),

            title.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 18),

            body.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),

            leftCard.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 28),
            leftCard.widthAnchor.constraint(equalTo: overlay.widthAnchor, multiplier: 0.52),
            leftCard.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 20),
            leftCard.bottomAnchor.constraint(lessThanOrEqualTo: overlay.bottomAnchor, constant: -28),

            rightCard.leadingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: 16),
            rightCard.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -28),
            rightCard.topAnchor.constraint(equalTo: leftCard.topAnchor),
            rightCard.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor),

            leftTitle.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor, constant: 20),
            leftTitle.topAnchor.constraint(equalTo: leftCard.topAnchor, constant: 18),
            leftBody.leadingAnchor.constraint(equalTo: leftCard.leadingAnchor, constant: 20),
            leftBody.trailingAnchor.constraint(equalTo: leftCard.trailingAnchor, constant: -20),
            leftBody.topAnchor.constraint(equalTo: leftTitle.bottomAnchor, constant: 8),
            leftBody.bottomAnchor.constraint(equalTo: leftCard.bottomAnchor, constant: -18),

            rightTitle.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 20),
            rightTitle.topAnchor.constraint(equalTo: rightCard.topAnchor, constant: 18),
            rightBody.leadingAnchor.constraint(equalTo: rightCard.leadingAnchor, constant: 20),
            rightBody.trailingAnchor.constraint(equalTo: rightCard.trailingAnchor, constant: -20),
            rightBody.topAnchor.constraint(equalTo: rightTitle.bottomAnchor, constant: 8),
            rightBody.bottomAnchor.constraint(equalTo: rightCard.bottomAnchor, constant: -18),
        ])

        return overlay
    }

    private func showMainLoadingOverlay(_ visible: Bool) {
        mainLoadingOverlay?.isHidden = !visible
    }

    private func presentScreen(_ mode: ScreenMode) {
        currentScreenMode = mode
        setupScreenView.isHidden = mode != .setup
        mainScreenView.isHidden = mode != .main
        switch mode {
        case .setup:
            toolbarSubtitleLabel.isHidden = false
            toolbarSubtitleLabel.stringValue = "初回セットアップだけに集中できる画面です。完了後は自動でメインへ進みます。"
            modeBadgeLabel?.stringValue = "セットアップ"
            showMainLoadingOverlay(true)
        case .main:
            toolbarSubtitleLabel.isHidden = false
            toolbarSubtitleLabel.stringValue = "音声生成画面を広く表示しています。設定とログは右上から開けます。"
            modeBadgeLabel?.stringValue = "メイン画面"
            showMainLoadingOverlay(true)
        }
    }

    private func setupStepRow(number: String, title: String, description: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 0.98, alpha: 1).cgColor
        row.layer?.cornerRadius = 16
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true

        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.34, alpha: 1).cgColor
        circle.layer?.cornerRadius = 16
        circle.translatesAutoresizingMaskIntoConstraints = false

        let numberLabel = label(number, fontSize: 13, weight: .bold)
        numberLabel.textColor = .white
        circle.addSubview(numberLabel)

        let titleLabel = label(title, fontSize: 14, weight: .semibold)
        let bodyLabel = wrappingLabel(description, fontSize: 12, weight: .regular)
        bodyLabel.textColor = NSColor(calibratedWhite: 0.40, alpha: 1)

        [circle, titleLabel, bodyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }

        NSLayoutConstraint.activate([
            circle.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            circle.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            circle.widthAnchor.constraint(equalToConstant: 32),
            circle.heightAnchor.constraint(equalToConstant: 32),

            numberLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            bodyLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])

        return row
    }

    private func cardView(cornerRadius: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.96).cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 0.84, alpha: 1).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.08
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)
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
        } else {
            button.bezelColor = NSColor(calibratedWhite: 0.97, alpha: 1)
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
            setupStartButton?.isEnabled = true
        } else {
            setupStatusLabel?.stringValue = "初回セットアップ前です。まずは『セットアップする』を押してください。"
            setupStartButton?.isEnabled = false
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
            if self.logTextView?.string == "まだログはありません。" {
                self.logTextView?.string = ""
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
        fileManager.fileExists(atPath: projectFile(".git").path)
    }

    private func runtimeLooksInstalled() -> Bool {
        fileManager.fileExists(atPath: projectFile(".venv/bin/python").path)
    }

    private func installedRuntimeVersion() -> String {
        (try? String(contentsOf: runtimeVersionFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func bundledRuntimeNeedsRefresh() -> Bool {
        guard usesBundledRuntime else { return false }
        guard runtimeLooksInstalled() else { return true }
        return installedRuntimeVersion() != bundledRuntimeVersion
    }

    private func isSetupComplete() -> Bool {
        runtimeLooksInstalled()
    }

    private func presentDefaultScreen() {
        presentScreen(isSetupComplete() ? .main : .setup)
    }

    private func readmeURL() -> URL {
        let runtimeReadme = projectFile("README.md")
        if fileManager.fileExists(atPath: runtimeReadme.path) {
            return runtimeReadme
        }
        if let bundledReadmeURL {
            return bundledReadmeURL
        }
        return bundleFallbackProjectDir.appendingPathComponent("README.md")
    }

    private func writeRuntimeSettings() throws {
        let configDir = currentProjectDir.appendingPathComponent("config", isDirectory: true)
        try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
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
        if !force && fileManager.fileExists(atPath: extractedModelMapURL.path) && installedVersion == bundledRuntimeVersion {
            completion(true)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fm = self.fileManager
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
                let fm = self.fileManager
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
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            updateStatus("\(relativePath) が見つかりませんでした。")
            return
        }

        let process = Process()
        process.currentDirectoryURL = currentProjectDir
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { env[$0.key] = $0.value }
        if fileManager.fileExists(atPath: extractedModelMapURL.path) {
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
            if self.fileManager.fileExists(atPath: self.extractedModelMapURL.path) {
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
                    self?.presentDefaultScreen()
                    self?.showMainLoadingOverlay(true)
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
                self.showMainLoadingOverlay(true)
                self.waitForBackendAndLoad()
            } catch {
                self.setBusy(false)
                self.presentDefaultScreen()
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
                        self?.showMainLoadingOverlay(false)
                        self?.updateStatus("起動しました。設定とログは上のボタンから開けます。")
                        self?.webView.load(URLRequest(url: targetURL))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.8)
            }

            DispatchQueue.main.async {
                self?.setBusy(false)
                self?.presentDefaultScreen()
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 510),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "設定"
        panel.center()
        panel.isFloatingPanel = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.95, alpha: 1).cgColor
        panel.contentView = root

        let title = label("設定", fontSize: 28, weight: .bold)
        let subtitle = wrappingLabel("音声品質と文字起こし設定、サポート導線をここでまとめて管理できます。", fontSize: 13, weight: .regular)
        settingsSummaryLabel = wrappingLabel("", fontSize: 13, weight: .medium)

        let modelCard = highlightCard()
        modelCard.layer?.cornerRadius = 22
        let supportCard = cardView(cornerRadius: 22)
        [modelCard, supportCard].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

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
        let reopenASRButton = secondaryLargeButton("ASR を再インストール", action: #selector(handleInstallASR))
        let openReadmeButton = secondaryLargeButton("README を開く", action: #selector(handleHelp))
        let openReleasesButton = secondaryLargeButton("GitHub / リリース", action: #selector(handleOpenReleases))
        let modelSectionTitle = label("モデル設定", fontSize: 16, weight: .bold)
        let modelSectionBody = wrappingLabel("Qwen-TTS と文字起こしモデルを切り替えます。変更後は保存してください。", fontSize: 12, weight: .regular)
        let supportSectionTitle = label("サポートと補助機能", fontSize: 16, weight: .bold)
        let supportSectionBody = wrappingLabel("ASR の入れ直し、README、GitHub / Release への移動をここにまとめています。", fontSize: 12, weight: .regular)

        [title, subtitle, settingsSummaryLabel!, modelSectionTitle, modelSectionBody, qwenLabel, qwenPopup, asrLabel, asrPopup, saveButton, supportSectionTitle, supportSectionBody, reopenASRButton, openReadmeButton, openReleasesButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        [modelSectionTitle, modelSectionBody, qwenLabel, qwenPopup, asrLabel, asrPopup, saveButton].forEach { modelCard.addSubview($0) }
        [supportSectionTitle, supportSectionBody, reopenASRButton, openReadmeButton, openReleasesButton].forEach { supportCard.addSubview($0) }
        [title, subtitle, settingsSummaryLabel!].forEach { root.addSubview($0) }

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

            modelCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            modelCard.topAnchor.constraint(equalTo: settingsSummaryLabel!.bottomAnchor, constant: 20),
            modelCard.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.53),
            modelCard.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            supportCard.leadingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: 16),
            supportCard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            supportCard.topAnchor.constraint(equalTo: modelCard.topAnchor),
            supportCard.bottomAnchor.constraint(equalTo: modelCard.bottomAnchor),

            modelSectionTitle.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            modelSectionTitle.topAnchor.constraint(equalTo: modelCard.topAnchor, constant: 20),
            modelSectionBody.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            modelSectionBody.topAnchor.constraint(equalTo: modelSectionTitle.bottomAnchor, constant: 6),
            modelSectionBody.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -20),

            qwenLabel.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            qwenLabel.topAnchor.constraint(equalTo: modelSectionBody.bottomAnchor, constant: 18),
            qwenPopup.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            qwenPopup.topAnchor.constraint(equalTo: qwenLabel.bottomAnchor, constant: 8),
            qwenPopup.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -20),

            asrLabel.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            asrLabel.topAnchor.constraint(equalTo: qwenPopup.bottomAnchor, constant: 18),
            asrPopup.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            asrPopup.topAnchor.constraint(equalTo: asrLabel.bottomAnchor, constant: 8),
            asrPopup.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -20),

            saveButton.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 20),
            saveButton.topAnchor.constraint(equalTo: asrPopup.bottomAnchor, constant: 24),
            saveButton.trailingAnchor.constraint(equalTo: modelCard.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(lessThanOrEqualTo: modelCard.bottomAnchor, constant: -20),

            supportSectionTitle.leadingAnchor.constraint(equalTo: supportCard.leadingAnchor, constant: 20),
            supportSectionTitle.topAnchor.constraint(equalTo: supportCard.topAnchor, constant: 20),
            supportSectionBody.leadingAnchor.constraint(equalTo: supportCard.leadingAnchor, constant: 20),
            supportSectionBody.topAnchor.constraint(equalTo: supportSectionTitle.bottomAnchor, constant: 6),
            supportSectionBody.trailingAnchor.constraint(equalTo: supportCard.trailingAnchor, constant: -20),

            reopenASRButton.leadingAnchor.constraint(equalTo: supportCard.leadingAnchor, constant: 20),
            reopenASRButton.trailingAnchor.constraint(equalTo: supportCard.trailingAnchor, constant: -20),
            reopenASRButton.topAnchor.constraint(equalTo: supportSectionBody.bottomAnchor, constant: 20),

            openReadmeButton.leadingAnchor.constraint(equalTo: supportCard.leadingAnchor, constant: 20),
            openReadmeButton.trailingAnchor.constraint(equalTo: supportCard.trailingAnchor, constant: -20),
            openReadmeButton.topAnchor.constraint(equalTo: reopenASRButton.bottomAnchor, constant: 12),

            openReleasesButton.leadingAnchor.constraint(equalTo: supportCard.leadingAnchor, constant: 20),
            openReleasesButton.trailingAnchor.constraint(equalTo: supportCard.trailingAnchor, constant: -20),
            openReleasesButton.topAnchor.constraint(equalTo: openReadmeButton.bottomAnchor, constant: 12),
        ])

        settingsPanel = panel
        updateSettingsSummaryLabel()
    }

    private func buildLogPanelIfNeeded() {
        guard logPanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "ログ"
        panel.center()

        let root = NSView(frame: panel.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.95, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "動作ログ")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 28, y: panel.contentView!.bounds.height - 48, width: 320, height: 30)
        title.autoresizingMask = [.maxYMargin]

        let subtitle = NSTextField(wrappingLabelWithString: "セットアップ・起動・更新・バックエンドの状態を時系列で確認できます。困ったときはまずここを見ます。")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 0.34, alpha: 1)
        subtitle.frame = NSRect(x: 28, y: panel.contentView!.bounds.height - 72, width: 620, height: 20)
        subtitle.autoresizingMask = [.maxYMargin, .width]

        let hint = NSTextField(wrappingLabelWithString: "更新が止まって見えるときは、最後の数行にエラーや待機状態が出ていないか確認してください。")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.35, alpha: 1)
        hint.frame = NSRect(x: 28, y: panel.contentView!.bounds.height - 96, width: 640, height: 18)
        hint.autoresizingMask = [.maxYMargin, .width]

        let scrollView = NSScrollView(frame: NSRect(x: 28, y: 28, width: panel.contentView!.bounds.width - 56, height: panel.contentView!.bounds.height - 140))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 18
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.white
        textView.string = "まだログはありません。"
        textView.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        scrollView.documentView = textView

        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(hint)
        root.addSubview(scrollView)
        panel.contentView = root
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
                let fm = self.fileManager
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
        let scriptURL = fileManager.temporaryDirectory.appendingPathComponent("kantan-update-\(UUID().uuidString).sh")
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
            try fileManager.setAttributes([FileAttributeKey.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
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
            ensureBundledRuntimeInstalled(force: true) { [weak self] success in
                guard success else { return }
                self?.updateStatus("セットアップ完了です。音声生成画面を開いています。")
                self?.startBackendIfNeeded()
            }
            return
        }
        updateStatus("セットアップを始めます。初回は時間がかかります。")
        appendLog("セットアップを開始します。")
        runShellScript("setup.command") { [weak self] code in
            if code == 0 {
                self?.updateStatus("セットアップ完了です。音声生成画面を開いています。")
                self?.startBackendIfNeeded()
            } else {
                self?.updateStatus("セットアップに失敗しました。『ログ』を開いて確認してください。")
            }
        }
    }

    @objc private func handleStart() {
        presentScreen(.main)
        showMainLoadingOverlay(true)
        startBackendIfNeeded()
    }

    @objc private func handleShowSettings() {
        buildSettingsPanelIfNeeded()
        if let panel = settingsPanel {
            updateSettingsSummaryLabel()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        if let url = webView.url, url.host == "127.0.0.1" {
            presentScreen(.main)
            showMainLoadingOverlay(false)
            updateStatus("音声生成画面が開きました。設定やログは右上から開けます。")
            webView.evaluateJavaScript("document.querySelectorAll('footer').forEach((node) => node.remove())")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
