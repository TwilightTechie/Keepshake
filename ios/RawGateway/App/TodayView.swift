import SwiftUI

// MARK: - Today View (Executive Home Dashboard)

struct TodayView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var receiver: PendantReceiver
    @ObservedObject var liveSpeech: LiveSpeechService
    @ObservedObject var logger: DiagnosticLogger

    @StateObject private var insightsVM: InsightsViewModel
    @StateObject private var decisionsVM: DecisionsViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.scenePhase) private var phase

    @State private var completedTaskIDs: Set<String> = []
    private let tasksKey = "today_completed_task_ids"

    init(
        settings: Settings,
        receiver: PendantReceiver,
        liveSpeech: LiveSpeechService,
        logger: DiagnosticLogger
    ) {
        self.settings = settings
        self.receiver = receiver
        self.liveSpeech = liveSpeech
        self.logger = logger
        _insightsVM = StateObject(wrappedValue: InsightsViewModel(settings: settings))
        _decisionsVM = StateObject(wrappedValue: DecisionsViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    greetingHeader

                    // 1. Live Speech Stream Dock
                    LiveSpeechCard(service: liveSpeech, isRecording: receiver.running)

                    // 2. The Verdict - Decisions Made Today
                    TodayDecisionsBlockView(viewModel: decisionsVM)

                    // 3. Day Briefing (Personalized Summary)
                    dayBriefingSection

                    // 4. Action Items & Commitments Checklist
                    actionItemsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(AppColors.background)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.brandIndigo)
                        Text("Keepsake AI")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        // Theme appearance menu
                        Menu {
                            ForEach(AppTheme.allCases) { theme in
                                Button {
                                    themeManager.setTheme(theme)
                                } label: {
                                    HStack {
                                        Text(theme.title)
                                        Spacer()
                                        if themeManager.currentTheme == theme {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: themeManager.currentTheme.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(7)
                                .background(AppColors.secondaryCardBackground)
                                .clipShape(Circle())
                        }

                        // Refresh button
                        Button {
                            refreshAll()
                        } label: {
                            if (insightsVM.isLoading || decisionsVM.isLoading) && !insightsVM.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .padding(7)
                                    .background(AppColors.secondaryCardBackground)
                                    .clipShape(Circle())
                            }
                        }
                        .disabled(insightsVM.isLoading || insightsVM.isGenerating)

                        // Summarize button
                        Button {
                            Task { await insightsVM.generateOnDemand(minutes: 10) }
                        } label: {
                            if insightsVM.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 11))
                                    Text("Summarize")
                                        .font(AppTypography.caption)
                                        .fontWeight(.semibold)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppColors.brandIndigo)
                                .foregroundStyle(Color.white)
                                .clipShape(Capsule())
                            }
                        }
                        .disabled(insightsVM.isGenerating)
                    }
                }
            }
            .refreshable {
                async let ins: () = insightsVM.fetchInsights()
                async let dec: () = decisionsVM.fetchDecisions()
                _ = await (ins, dec)
            }
            .onAppear {
                loadCompletedTasks()
                refreshAll()
            }
            .onChange(of: phase) { newPhase in
                if newPhase == .active {
                    refreshAll()
                }
            }
        }
    }

    private func refreshAll() {
        Task {
            async let ins: () = insightsVM.fetchInsights()
            async let dec: () = decisionsVM.fetchDecisions()
            _ = await (ins, dec)
        }
    }

    // MARK: - Ambient Greeting & Hardware Badge

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeGreeting)
                        .font(AppTypography.appTitle)
                        .foregroundStyle(AppColors.textPrimary)

                    Text(currentDateFormatted)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                // Hardware Status Pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(receiver.running ? AppColors.verdictEmerald : AppColors.textTertiary)
                        .frame(width: 7, height: 7)

                    Text(hardwareStatusText)
                        .font(AppTypography.monoTag)
                        .foregroundStyle(receiver.running ? AppColors.textPrimary : AppColors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(receiver.running ? AppColors.emeraldPillBackground : AppColors.secondaryCardBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(receiver.running ? AppColors.verdictEmerald.opacity(0.3) : AppColors.cardBorder, lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, 2)
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 {
            return "Good morning, Anup 👋"
        } else if hour < 17 {
            return "Good afternoon, Anup 👋"
        } else {
            return "Good evening, Anup 👋"
        }
    }

    private var currentDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var hardwareStatusText: String {
        let name = receiver.deviceName.isEmpty ? "Keepsake-P0" : receiver.deviceName
        if receiver.running {
            return "\(name) · 16 kHz Native"
        } else if receiver.status.lowercased().contains("connect") {
            return "\(name) · Connecting"
        } else {
            return "\(name) · Standby"
        }
    }

    // MARK: - Day Briefing Section

    private var dayBriefingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(AppColors.indigoPillBackground)
                        .frame(width: 32, height: 32)
                    Image(systemName: "quote.opening")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.brandIndigo)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Day Briefing")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Executive Synthesis & Key Conversations")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                if let first = insightsVM.insights.first, !first.displayTime.isEmpty {
                    Text(first.displayTime)
                        .font(AppTypography.monoTag)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }

            if insightsVM.isGenerating {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyzing today's conversations...")
                            .font(AppTypography.cardTitle)
                            .foregroundStyle(AppColors.textPrimary)
                        Text("Synthesizing decisions, topics, and key context.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.indigoPillBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let error = insightsVM.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warningAmber)
                    Text(error)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Button("Retry") {
                        Task { await insightsVM.fetchInsights() }
                    }
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.brandIndigo)
                }
                .padding(12)
                .background(AppColors.secondaryCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let latest = insightsVM.insights.first {
                VStack(alignment: .leading, spacing: 12) {
                    // Headline quote banner
                    if !latest.displayHeadline.isEmpty {
                        Text(latest.displayHeadline)
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.brandIndigo)
                            .lineSpacing(3)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.indigoPillBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Executive Summary
                    if !latest.displaySummary.isEmpty {
                        Text(latest.displaySummary)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineSpacing(3)
                    }

                    // Key Points bullets
                    if !latest.displayKeyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Key Highlights")
                                .font(AppTypography.cardTitle)
                                .foregroundStyle(AppColors.textSecondary)

                            ForEach(latest.displayKeyPoints, id: \.self) { point in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(AppColors.brandIndigo)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 6)
                                    Text(point)
                                        .font(AppTypography.body)
                                        .foregroundStyle(AppColors.textPrimary)
                                }
                            }
                        }
                        .padding(12)
                        .background(AppColors.secondaryCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(AppColors.textTertiary)
                    Text("No summaries available yet")
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("Speak into your Keepsake pendant. Conversations will be automatically synthesized here.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Action Items & Commitments Section

    private var actionItemsSection: some View {
        let allActions = allAggregatedActionItems()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(AppColors.bluePillBackground)
                        .frame(width: 32, height: 32)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.actionBlue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Action Items")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)

                        if !allActions.isEmpty {
                            Text("\(allActions.count)")
                                .font(AppTypography.monoTag)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppColors.bluePillBackground)
                                .foregroundStyle(AppColors.actionBlue)
                                .clipShape(Capsule())
                        }
                    }

                    Text("Tasks & Next Steps from Conversations")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()
            }

            if allActions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(AppColors.textTertiary)
                    Text("No pending action items")
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("Action items and commitments identified in your conversations will appear here.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    ForEach(allActions, id: \.self) { task in
                        let isDone = completedTaskIDs.contains(task)
                        Button {
                            toggleTask(task)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isDone ? AppColors.verdictEmerald : AppColors.textTertiary)
                                    .padding(.top, 1)

                                Text(task)
                                    .font(AppTypography.body)
                                    .foregroundStyle(isDone ? AppColors.textTertiary : AppColors.textPrimary)
                                    .strikethrough(isDone, color: AppColors.textTertiary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()
                            }
                            .padding(10)
                            .background(AppColors.secondaryCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private func allAggregatedActionItems() -> [String] {
        var actions: [String] = []
        for insight in insightsVM.insights {
            for action in insight.displayActionItems {
                let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !actions.contains(trimmed) {
                    actions.append(trimmed)
                }
            }
        }
        return actions
    }

    private func toggleTask(_ task: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if completedTaskIDs.contains(task) {
            completedTaskIDs.remove(task)
        } else {
            completedTaskIDs.insert(task)
        }
        UserDefaults.standard.set(Array(completedTaskIDs), forKey: tasksKey)
    }

    private func loadCompletedTasks() {
        if let saved = UserDefaults.standard.stringArray(forKey: tasksKey) {
            completedTaskIDs = Set(saved)
        }
    }
}
