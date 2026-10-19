import SwiftUI

// MARK: - Live Speech Card

struct LiveSpeechCard: View {
    @ObservedObject var service: LiveSpeechService
    var isRecording: Bool
    var compact: Bool

    @State private var autoScroll = true
    @State private var showFullScreen = false
    @State private var copiedAlert = false

    init(service: LiveSpeechService, isRecording: Bool = false, compact: Bool = false) {
        self.service = service
        self.isRecording = isRecording
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isRecording && service.isConnected ? AppColors.emeraldPillBackground : AppColors.cardBorder)
                        .frame(width: 32, height: 32)
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isRecording && service.isConnected ? AppColors.verdictEmerald : AppColors.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(compact ? "Latest speech" : "Live Speech Stream")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)

                        if isRecording && service.isConnected {
                            Circle()
                                .fill(AppColors.verdictEmerald)
                                .frame(width: 6, height: 6)
                        }
                    }

                    Text(isRecording ? (service.isConnected ? "Listening now" : "Waiting for speech service") : "Capture is off")
                        .font(AppTypography.caption)
                        .foregroundStyle(isRecording && service.isConnected ? AppColors.verdictEmerald : AppColors.textSecondary)
                }

                Spacer()

                // Waveform indicator
                if !compact {
                    WaveformVisualizerView(
                        isActive: service.isReceivingAudio || isRecording,
                        barCount: 5,
                        barWidth: 3,
                        maxBarHeight: 18,
                        activeColor: AppColors.verdictEmerald
                    )
                }

                // Controls
                HStack(spacing: 8) {
                    if !compact {
                        Button {
                            autoScroll.toggle()
                        } label: {
                            Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(autoScroll ? AppColors.brandIndigo : AppColors.textTertiary)
                        }
                        .accessibilityLabel("Toggle auto-scroll")
                    }

                    Button {
                        showFullScreen = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                            if compact { Text("Open") }
                        }
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.brandIndigo)
                    }
                    .accessibilityLabel("Full screen speech")
                }
            }

            if !compact { Divider().overlay(AppColors.divider) }

            // Transcript Scroll Feed
            if service.transcripts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(AppColors.textTertiary.opacity(0.6))
                        .padding(.top, 12)

                    Text(isRecording
                         ? "Listening for your next memory."
                         : "Start capture on Device to save a new memory.")
                        .font(AppTypography.secondaryBody)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 72 : 160)
            } else {
                if compact {
                    Text(service.transcripts.last?.text ?? "")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(service.transcripts) { entry in
                                    TranscriptRowView(entry: entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: 220)
                        .onChange(of: service.transcripts.count) { _ in
                            if autoScroll, let last = service.transcripts.last {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
        .appCard(padding: 14, cornerRadius: 16)
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenLiveSpeechView(service: service, isRecording: isRecording)
        }
    }
}

// MARK: - Transcript Row View

struct TranscriptRowView: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.speaker)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)

                // Source badge
                Text(entry.displaySource)
                    .font(AppTypography.monoTag)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(entry.isCheckpoint ? AppColors.emeraldPillBackground : AppColors.indigoPillBackground)
                    .foregroundStyle(entry.isCheckpoint ? AppColors.verdictEmerald : AppColors.brandIndigo)
                    .clipShape(Capsule())

                if let lang = entry.language, !lang.isEmpty, lang != "unknown" {
                    Text(lang)
                        .font(AppTypography.monoTag)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(AppColors.secondaryCardBackground)
                        .foregroundStyle(AppColors.textTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if let dur = entry.duration_sec, dur > 0 {
                    Text("\(String(format: "%.1f", dur))s · \(entry.time)")
                        .font(AppTypography.monoTag)
                        .foregroundStyle(AppColors.textTertiary)
                } else if !entry.time.isEmpty {
                    Text(entry.time)
                        .font(AppTypography.monoTag)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }

            Text(entry.text)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(AppColors.secondaryCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Full Screen Live Speech View

struct FullScreenLiveSpeechView: View {
    @ObservedObject var service: LiveSpeechService
    var isRecording: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var autoScroll = true
    @State private var showCopiedBanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top status bar
                HStack(spacing: 12) {
                    WaveformVisualizerView(
                        isActive: service.isReceivingAudio || isRecording,
                        barCount: 7,
                        barWidth: 4,
                        maxBarHeight: 24,
                        activeColor: AppColors.verdictEmerald
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ambient Stream")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)
                        Text(service.connectionStatus)
                            .font(AppTypography.caption)
                            .foregroundStyle(service.isConnected ? AppColors.verdictEmerald : AppColors.textSecondary)
                    }

                    Spacer()

                    Button {
                        autoScroll.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                            Text("Auto-Scroll")
                        }
                        .font(AppTypography.caption)
                        .foregroundStyle(autoScroll ? AppColors.brandIndigo : AppColors.textSecondary)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(AppColors.cardBackground)

                Divider()
                    .overlay(AppColors.divider)

                // Large Scrolling Transcript Area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(service.transcripts) { entry in
                                TranscriptRowView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: service.transcripts.count) { _ in
                        if autoScroll, let last = service.transcripts.last {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                if showCopiedBanner {
                    Text("Transcript copied to clipboard")
                        .font(AppTypography.caption)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(AppColors.verdictEmerald.opacity(0.15))
                        .foregroundStyle(AppColors.verdictEmerald)
                        .clipShape(Capsule())
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(AppColors.background)
            .navigationTitle("Live Speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(AppColors.brandIndigo)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let text = service.transcripts.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
                        UIPasteboard.general.string = text
                        withAnimation { showCopiedBanner = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showCopiedBanner = false }
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
            }
        }
    }
}
