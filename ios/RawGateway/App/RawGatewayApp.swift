import SwiftUI
import UIKit

final class Gateway {
    static let shared = Gateway()
    let settings = Settings()
    let store: ChunkStore?
    let receiver: PendantReceiver?
    let uploader: Uploader?
    let logger = DiagnosticLogger()
    let liveSpeech: LiveSpeechService
    let startupError: String?

    private init() {
        let liveSpeech = LiveSpeechService(settings: settings)
        self.liveSpeech = liveSpeech
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let store = try ChunkStore(directory: base.appendingPathComponent("RawChunks", isDirectory: true))
            self.store = store
            let uploader = Uploader(store: store, settings: settings)
            self.uploader = uploader
            let receiver = PendantReceiver(store: store, settings: settings, logger: logger)
            self.receiver = receiver
            receiver.checkpointed = { [weak uploader] in uploader?.pump() }
            startupError = nil
            logger.info("App initialized successfully", category: "app")
        } catch {
            store = nil; receiver = nil; uploader = nil
            startupError = "Cannot open capture storage: \(error.localizedDescription). Existing files have been retained."
            logger.error("Startup failed: \(error.localizedDescription)", category: "app")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Uploader.sessionID, let uploader = Gateway.shared.uploader else {
            completionHandler(); return
        }
        uploader.completionHandler = completionHandler
    }
}

@main
struct RawGatewayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var themeManager = ThemeManager.shared
    @AppStorage("keepsake_welcome_seen") private var welcomeSeen = false
    @State private var showWelcome = false
    private let gateway = Gateway.shared
    var body: some Scene {
        WindowGroup {
            if let receiver = gateway.receiver, let uploader = gateway.uploader {
                TabView {
                    TodayView(
                        settings: gateway.settings,
                        receiver: receiver,
                        liveSpeech: gateway.liveSpeech,
                        logger: gateway.logger,
                        uploader: uploader
                    )
                    .tabItem {
                        Label("Today", systemImage: "sparkles")
                    }

                    TimelineView(settings: gateway.settings)
                    .tabItem {
                        Label("Timeline", systemImage: "clock.arrow.circlepath")
                    }

                    GatewayView(
                        settings: gateway.settings,
                        receiver: receiver,
                        uploader: uploader,
                        logger: gateway.logger,
                        liveSpeech: gateway.liveSpeech
                    )
                    .tabItem {
                        Label("Device", systemImage: "wave.3.right.circle")
                    }
                }
                .onAppear { if !welcomeSeen { showWelcome = true } }
                .sheet(isPresented: $showWelcome) {
                    WelcomeView {
                        welcomeSeen = true
                        showWelcome = false
                    }
                }
                .tint(AppColors.brandIndigo)
                .preferredColorScheme(themeManager.currentTheme.colorScheme)
                .environmentObject(themeManager)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("Capture unavailable").font(.title2)
                    Text(gateway.startupError ?? "Unknown storage error")
                }.padding()
            }
        }
    }
}

private struct WelcomeView: View {
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(AppColors.brandIndigo)
                Text("Your moments, remembered.")
                    .font(AppTypography.appTitle)
                Text("Keepsake saves what matters from your conversations and helps you find it later.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                Label("Connect your pendant on the Device tab", systemImage: "wave.3.right.circle")
                Label("Choose Live, checkpoints, or archive only", systemImage: "arrow.up.right.circle")
                Label("Find memories and next steps on Today", systemImage: "sparkles")
                Spacer()
                Button("Explore Keepsake", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
            }
            .padding(24)
            .background(AppColors.background)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Skip", action: onFinish) } }
        }
    }
}

// MARK: - Main View

struct GatewayView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var receiver: PendantReceiver
    @ObservedObject var uploader: Uploader
    @ObservedObject var logger: DiagnosticLogger
    @ObservedObject var liveSpeech: LiveSpeechService
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.scenePhase) private var phase
    @State private var showLogs = false
    @State private var showCheckpoint = false
    @State private var showToken = false
    @State private var showCopiedAlert = false
    @State private var copiedAlertMessage = ""
    @State private var showPruneAlert = false
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceStatusCard
                    captureControlCard
                    liveStreamCard
                    uploadQueueCard
                    DisclosureGroup("Settings & diagnostics", isExpanded: $showAdvanced) {
                        VStack(spacing: 16) {
                            serverCard
                            packetStatsCard
                            diagnosticsCard
                            notesCard
                        }
                        .padding(.top, 12)
                    }
                    .font(.headline)
                    .tint(AppColors.brandIndigo)
                    .padding(16)
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(AppColors.background)
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Appearance", selection: $themeManager.currentTheme) {
                            ForEach(AppTheme.allCases) { theme in
                                Label(theme.title, systemImage: theme.icon).tag(theme)
                            }
                        }
                    } label: {
                        Image(systemName: themeManager.currentTheme.icon)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.brandIndigo)
                    }
                }
            }
            .sheet(isPresented: $showLogs) {
                LogsView(logger: logger, receiver: receiver, uploader: uploader, settings: settings)
            }
            .sheet(isPresented: $showCheckpoint) {
                CheckpointView(uploader: uploader)
            }
            .alert(copiedAlertMessage, isPresented: $showCopiedAlert) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: phase) { newPhase in
                if newPhase == .active { uploader.pump(); logger.refreshFileSize() }
                if newPhase != .active { settings.saveToken(); settings.saveWebhookToken() }
            }
        }
    }

    // MARK: - Device Status Card

    private var deviceStatusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(connectionColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: receiver.running ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                        .font(.title2)
                        .foregroundStyle(connectionColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(receiver.deviceName)
                        .font(.headline)
                    Text(connectionStatusText)
                        .font(.subheadline)
                        .foregroundStyle(connectionColor)
                    if receiver.running {
                        Text(receiver.streamDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                Text(receiver.status.contains("Receiving") ? "Capturing" : receiver.running ? "Connecting" : "Standby")
                    .font(AppTypography.caption)
                    .foregroundStyle(connectionColor)
            }
            .padding()

            if !receiver.firmwareDiagnostics.hasPrefix("Not read") {
                Divider().padding(.horizontal)
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.caption).foregroundStyle(.secondary)
                    Text(receiver.firmwareDiagnostics)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var connectionColor: Color {
        if !receiver.running { return .secondary }
        if receiver.status.contains("Receiving") { return .green }
        if receiver.status.contains("reconnecting") || receiver.status.contains("Reconnecting") { return .orange }
        return .blue
    }

    private var connectionStatusText: String {
        if !receiver.running { return "Disconnected" }
        return receiver.status
    }

    // MARK: - Capture Control Card

    private var captureControlCard: some View {
        VStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if receiver.running { receiver.stop() } else { receiver.start() }
            } label: {
                HStack {
                    Image(systemName: receiver.running ? "stop.circle.fill" : "play.circle.fill")
                    Text(receiver.running ? "Stop Capture" : "Connect & Start Capture")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.running ? .red : .green)

            if !receiver.running {
                Button {
                    receiver.forget()
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Forget Device & Scan Again")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Server Connection & Simple Auth Card

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Server & Auth", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                if receiver.running {
                    Label("Locked during capture", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Webhook Ingestion URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://your-server/omi/webhook/audio", text: $settings.dreamAIWebhook)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(receiver.running)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Simple Auth Token").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(showToken ? "Hide" : "Show") {
                        showToken.toggle()
                    }
                    .font(.caption2)
                }
                HStack {
                    if showToken {
                        TextField("Auth token", text: $settings.webhookToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .monospaced))
                    } else {
                        SecureField("Auth token", text: $settings.webhookToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit { settings.saveWebhookToken() }
            }
            .disabled(receiver.running)

            if !settings.webhookTokenError.isEmpty {
                Label(settings.webhookTokenError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Save Token") {
                    settings.saveWebhookToken()
                    copiedAlertMessage = "Server settings and token saved to Keychain."
                    showCopiedAlert = true
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(receiver.running)

                Button("Reset Defaults") {
                    settings.dreamAIWebhook = "https://aadeshai.xyz/omi/webhook/audio?sample_rate=16000&uid=iphone_user"
                    settings.webhookToken = "keepsake-secret-2026"
                    settings.saveWebhookToken()
                    copiedAlertMessage = "Restored default Dream AI endpoint and secret token."
                    showCopiedAlert = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(receiver.running)
            }

            Text("The simple auth token is passed via HTTP header and URL parameter. Default server secret is stored in Keychain.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Delivery Mode Card

    private var deliveryModeSelection: Binding<DeliveryMode> {
        Binding(get: { settings.deliveryMode }, set: { receiver.changeDeliveryMode(to: $0) })
    }

    private var liveStreamCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Delivery Mode", systemImage: "arrow.up.right.circle")
                .font(.headline)
            ForEach(DeliveryMode.allCases) { mode in
                Button {
                    deliveryModeSelection.wrappedValue = mode
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: settings.deliveryMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(AppColors.brandIndigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode == .live ? "Live" : mode == .checkpoint ? "30-second checkpoints" : "Archive only")
                                .font(AppTypography.cardTitle)
                            Text(mode == .live ? "Send audio as you speak" : mode == .checkpoint ? "Save, then send each 30-second file" : "Keep raw files without transcription")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(settings.deliveryMode == mode ? AppColors.indigoPillBackground : AppColors.secondaryCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            if receiver.running {
                Text("Changing mode safely finishes the current file first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Packet Stats Card (Received this Connection)

    private var packetStatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Received this Connection", systemImage: "chart.bar.fill")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatCell(label: "Notifications", value: "\(receiver.stats.packets)", icon: "envelope.fill", color: .blue,
                         help: "BLE audio packets delivered")
                StatCell(label: "Audio Data", value: formatBytes(receiver.stats.bytes), icon: "arrow.down.circle.fill", color: .indigo,
                         help: "Total bytes received")
                StatCell(label: "Sequence Gaps", value: "\(receiver.stats.gaps)", icon: "exclamationmark.triangle.fill",
                         color: receiver.stats.gaps > 0 ? .orange : .green,
                         help: "Missed packets during BLE transit")
                StatCell(label: "Packet Errors", value: "\(receiver.stats.reordered + receiver.stats.malformed)",
                         icon: "xmark.octagon.fill",
                         color: (receiver.stats.reordered + receiver.stats.malformed) > 0 ? .red : .green,
                         help: "Duplicate, out-of-order, or short")
            }

            if receiver.lastPacket != "None" {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    Text("Last packet: \(receiver.lastPacket) UTC")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("All received audio bytes are preserved bit-exact without modification. Sequence gaps reflect BLE packets dropped over the wireless link.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Upload Queue Card

    private var uploadQueueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved Audio & Uploads", systemImage: "icloud.and.arrow.up")
                    .font(.headline)
                Spacer()
            }
            Toggle("Automatic uploads", isOn: $settings.uploadsEnabled)
                .font(.subheadline)
                .onChange(of: settings.uploadsEnabled) { _ in uploader.pump() }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(uploader.pendingCount)")
                        .font(.title2).fontWeight(.bold).foregroundStyle(.primary)
                    Text("Pending Files")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f MB", receiver.storageMB))
                        .font(.title2).fontWeight(.bold).foregroundStyle(.primary)
                    Text("Local Storage (1 GB max)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("\(uploader.checkpointPendingCount) awaiting transcription · \(uploader.archivePendingCount) archive files")
                .font(.caption)
                .foregroundStyle(.secondary)

            if receiver.storageMB >= 750 {
                Label("Storage is nearing the 1 GB capture limit. Upload the pending files to keep recording.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(uploader.status)
                .font(.subheadline)
                .foregroundStyle(uploader.status.contains("error") || uploader.status.contains("Error") ? .red : .secondary)

            if uploader.status.localizedCaseInsensitiveContains("configure") {
                Button("Set up server") { showAdvanced = true }
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(AppColors.brandIndigo)
            }

            if uploader.lastUploaded != "Never" {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Last confirmed upload: \(uploader.lastUploaded)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    settings.saveToken()
                    uploader.retryNow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Queue Now")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(uploader.busy)

                Button {
                    showCheckpoint = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Inspect Checkpoint Files")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if uploader.archivePendingCount > 0 || uploader.pendingCount > 0 {
                Button(role: .destructive) {
                    showPruneAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(uploader.archivePendingCount > 0
                             ? "Prune \(uploader.archivePendingCount) Archive Files (\(String(format: "%.1f", receiver.storageMB)) MB)"
                             : "Prune All Queued Files (\(String(format: "%.1f", receiver.storageMB)) MB)")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Prune Local Storage?", isPresented: $showPruneAlert, titleVisibility: .visible) {
                    if uploader.archivePendingCount > 0 {
                        Button("Delete \(uploader.archivePendingCount) Archive Files (\(String(format: "%.1f", receiver.storageMB)) MB)", role: .destructive) {
                            uploader.pruneArchiveFiles()
                        }
                    }
                    Button("Delete All \(uploader.pendingCount) Queued Files", role: .destructive) {
                        uploader.pruneAllFiles()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Unconfirmed recordings will be permanently removed and cannot be transcribed or uploaded later.")
                }
            }

            Text(settings.deliveryMode == .checkpoint
                 ? "Checkpoint uploads are required for transcription in this mode. Files remain queued until the server confirms durable storage."
                 : settings.deliveryMode == .live
                   ? "Live audio goes to Dream AI immediately. Automatic uploads archive raw checkpoint files separately when configured."
                   : "Automatic uploads send raw files to the archive server without starting transcription.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Diagnostics & Logs Card

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Local Diagnostic Logs", systemImage: "doc.text.fill")
                    .font(.headline)
                Spacer()
                Text(formatBytes(Int(logger.logFileSize)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let last = logger.entries.last {
                HStack(spacing: 6) {
                    Circle()
                        .fill(logLevelColor(last.level))
                        .frame(width: 6, height: 6)
                    Text(last.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button {
                    let report = logger.generateReport(
                        receiverStatus: receiver.status,
                        deviceName: receiver.deviceName,
                        streamDesc: receiver.streamDescription,
                        stats: receiver.stats,
                        storageMB: receiver.storageMB,
                        pendingChunks: uploader.pendingCount,
                        uploaderStatus: uploader.status
                    )
                    UIPasteboard.general.string = report
                    copiedAlertMessage = "Diagnostic snapshot generated and copied to clipboard."
                    showCopiedAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Generate Report")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Button {
                    showLogs = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                        Text("View Logs")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Button {
                    UIPasteboard.general.string = logger.exportAllFiles()
                    copiedAlertMessage = "All diagnostic log files copied to clipboard."
                    showCopiedAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy All")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            Text("Diagnostic logs are stored locally and automatically deleted after 3 days. BLE events, stream flushes, and recovery actions are logged.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Notes Card

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("System Notes", systemImage: "info.circle")
                .font(.subheadline).fontWeight(.semibold)
            Group {
                Text("• Raw 16 kHz mono PCM16 — no noise filters or downsampling")
                Text("• Keep the app open; closing or swiping away stops capture")
                Text("• Reconnect recovery is automated with watchdog protection")
                Text("• Live transcripts are accessible at https://aadeshai.xyz/dream-ai/")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func logLevelColor(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        default: return .green
        }
    }
}

// MARK: - Stat Cell

struct StatCell: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3).fontWeight(.semibold).foregroundStyle(.primary)
            if let help {
                Text(help).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Logs View

struct LogsView: View {
    @ObservedObject var logger: DiagnosticLogger
    let receiver: PendantReceiver
    let uploader: Uploader
    let settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var showCopiedBanner = false

    var body: some View {
        NavigationStack {
            List {
                if filteredEntries.isEmpty {
                    Text("No log entries found").foregroundStyle(.secondary)
                }
                ForEach(filteredEntries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(levelColor(entry.level))
                                .frame(width: 6, height: 6)
                            Text(entry.category.uppercased())
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(shortTime(entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .searchable(text: $filter, prompt: "Filter logs by category or message")
            .navigationTitle("Diagnostic Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            logger.generateReport(
                                receiverStatus: receiver.status,
                                deviceName: receiver.deviceName,
                                streamDesc: receiver.streamDescription,
                                stats: receiver.stats,
                                storageMB: receiver.storageMB,
                                pendingChunks: uploader.pendingCount,
                                uploaderStatus: uploader.status
                            )
                        } label: {
                            Image(systemName: "sparkles")
                        }

                        Button {
                            UIPasteboard.general.string = logger.exportAllFiles()
                            showCopiedBanner = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showCopiedBanner = false
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showCopiedBanner {
                    Text("Copied all logs to clipboard")
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private var filteredEntries: [DiagnosticLogger.LogEntry] {
        guard !filter.isEmpty else { return logger.entries }
        let q = filter.lowercased()
        return logger.entries.filter {
            $0.message.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        default: return .green
        }
    }

    private func shortTime(_ iso: String) -> String {
        guard iso.count >= 19 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(iso.startIndex, offsetBy: 19)
        return String(iso[start..<end])
    }
}

// MARK: - Checkpoint Viewer

struct ChunkDetail: Identifiable {
    var id: String { name }
    let name: String
    let size: String
    let date: String
    let url: URL
    var headerJSON: String?
}

struct CheckpointView: View {
    @ObservedObject var uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [ChunkDetail] = []
    @State private var selectedChunk: ChunkDetail?

    var body: some View {
        NavigationStack {
            List {
                if chunks.isEmpty {
                    Text("No pending chunks in local storage").foregroundStyle(.secondary)
                }
                ForEach(chunks) { chunk in
                    Button {
                        selectedChunk = chunk
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chunk.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            HStack {
                                Text(chunk.size).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(chunk.date).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Checkpoint Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedChunk) { detail in
                ChunkDetailSheet(chunk: detail)
            }
            .onAppear { loadChunks() }
        }
    }

    private func loadChunks() {
        guard let store = Gateway.shared.store,
              let files = try? store.pending() else { return }
        chunks = files.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                .map { ChunkStore.timestamp($0) } ?? "Unknown"

            var header: String?
            if let data = try? Data(contentsOf: url),
               let firstLineEnd = data.firstIndex(of: 0x0a) {
                header = String(data: data[..<firstLineEnd], encoding: .utf8)
            }

            return ChunkDetail(
                name: url.deletingPathExtension().lastPathComponent,
                size: "\(max(1, size / 1024)) KB",
                date: String(date.prefix(19)),
                url: url,
                headerJSON: header
            )
        }
    }
}

struct ChunkDetailSheet: View {
    let chunk: ChunkDetail
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chunk ID").font(.caption).foregroundStyle(.secondary)
                        Text(chunk.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Size").font(.caption).foregroundStyle(.secondary)
                            Text(chunk.size).font(.headline)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Created").font(.caption).foregroundStyle(.secondary)
                            Text(chunk.date).font(.headline)
                        }
                    }

                    if let header = chunk.headerJSON {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Header Metadata (JSONL Line 1)").font(.caption).foregroundStyle(.secondary)
                            Text(header)
                                .font(.system(.caption, design: .monospaced))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        if let header = chunk.headerJSON {
                            UIPasteboard.general.string = header
                            copied = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text(copied ? "Copied Header" : "Copy Header JSON")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Chunk Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
