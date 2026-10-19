import SwiftUI

// MARK: - Today View (Executive Home Dashboard)

struct TodayView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var receiver: PendantReceiver
    @ObservedObject var liveSpeech: LiveSpeechService
    @ObservedObject var logger: DiagnosticLogger
    @ObservedObject var uploader: Uploader

    @StateObject private var insightsVM: InsightsViewModel
    @StateObject private var decisionsVM: DecisionsViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.scenePhase) private var phase

    @State private var completedTaskIDs: Set<String> = []
    @State private var showAllTasks = false
    @State private var showBriefingDetails = false
    @State private var actionSearch = ""
    @State private var selectedMemory: InsightItem?
    private let tasksKey = "today_completed_task_ids"

    init(
        settings: Settings,
        receiver: PendantReceiver,
        liveSpeech: LiveSpeechService,
        logger: DiagnosticLogger,
        uploader: Uploader
    ) {
        self.settings = settings
        self.receiver = receiver
        self.liveSpeech = liveSpeech
        self.logger = logger
        self.uploader = uploader
        _insightsVM = StateObject(wrappedValue: InsightsViewModel(settings: settings))
        _decisionsVM = StateObject(wrappedValue: DecisionsViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    greetingHeader
                    captureStatusCard
                    dayBriefingSection
                    actionItemsSection
                    TodayDecisionsBlockView(viewModel: decisionsVM)
                    LiveSpeechCard(service: liveSpeech, isRecording: receiver.running, compact: true)
                    recentMemoriesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .background(AppColors.background)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            .sheet(isPresented: $showAllTasks) {
                NavigationStack {
                    List {
                        ForEach(filteredActions, id: \.self) { task in
                            Button { toggleTask(task) } label: {
                                Label(task, systemImage: completedTaskIDs.contains(task) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(completedTaskIDs.contains(task) ? AppColors.textSecondary : AppColors.textPrimary)
                            }
                        }
                    }
                    .searchable(text: $actionSearch, prompt: "Find an action")
                    .navigationTitle("Action items")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showAllTasks = false } } }
                }
            }
            .sheet(item: $selectedMemory) { item in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !item.displayHeadline.isEmpty {
                                Text(item.displayHeadline)
                                    .font(AppTypography.sectionTitle)
                                    .foregroundStyle(AppColors.brandIndigo)
                            }
                            Text(item.displaySummary)
                                .font(AppTypography.body)
                            ForEach(item.displayKeyPoints, id: \.self) { point in
                                Label(point, systemImage: "circle.fill")
                                    .font(AppTypography.secondaryBody)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .navigationTitle(item.displayTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { selectedMemory = nil } } }
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

            }
        }
        .padding(.horizontal, 2)
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 {
            return "Good morning 👋"
        } else if hour < 17 {
            return "Good afternoon 👋"
        } else {
            return "Good evening 👋"
        }
    }

    private var currentDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }

    private var captureStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: receiver.status.contains("Receiving") ? "waveform.circle.fill" : "waveform.circle")
                .font(.title2)
                .foregroundStyle(receiver.status.contains("Receiving") ? AppColors.verdictEmerald : AppColors.brandIndigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(receiver.status.contains("Receiving") ? "Capturing audio" : receiver.running ? "Connecting to pendant" : "Pendant on standby")
                    .font(AppTypography.cardTitle)
                Text(uploader.pendingCount == 0
                     ? "No saved files waiting"
                     : settings.uploadsEnabled
                       ? "\(uploader.pendingCount) saved \(uploader.pendingCount == 1 ? "file" : "files") waiting to upload"
                       : "\(uploader.pendingCount) saved \(uploader.pendingCount == 1 ? "file" : "files") · uploads paused")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .appCard(padding: 14)
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
                    Text("Latest memory")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("A quick look at your most recent conversation")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                if let first = insightsVM.insights.first, !first.displayTime.isEmpty {
                    Text(String(first.displayTime.prefix(5)))
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
                            .lineLimit(showBriefingDetails ? nil : 2)
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
                            .lineLimit(showBriefingDetails ? nil : 3)
                    }

                    // Key Points bullets
                    if showBriefingDetails && !latest.displayKeyPoints.isEmpty {
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
                    if !latest.displaySummary.isEmpty || !latest.displayKeyPoints.isEmpty {
                        Button(showBriefingDetails ? "Show less" : "Read full memory") {
                            withAnimation { showBriefingDetails.toggle() }
                        }
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(AppColors.brandIndigo)
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
            if !insightsVM.isGenerating {
                Button {
                    Task { await insightsVM.generateOnDemand(minutes: 10) }
                } label: {
                    Label("Summarize the last 10 minutes", systemImage: "sparkles")
                        .font(AppTypography.caption)
                }
                .foregroundStyle(AppColors.brandIndigo)
                .padding(.top, 2)
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

                    Text("Your next steps from conversations")
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
                    let nextActions = Array(allActions.filter { !completedTaskIDs.contains($0) }.prefix(3))
                    if nextActions.isEmpty {
                        Text("You’re caught up for now.")
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(nextActions, id: \.self) { task in
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
                    if allActions.count > 3 || allActions.contains(where: { completedTaskIDs.contains($0) }) {
                        Button("See all \(allActions.count) actions") { showAllTasks = true }
                            .font(AppTypography.cardTitle)
                            .foregroundStyle(AppColors.brandIndigo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
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

    private var filteredActions: [String] {
        let actions = allAggregatedActionItems()
        guard !actionSearch.isEmpty else { return actions }
        return actions.filter { $0.localizedCaseInsensitiveContains(actionSearch) }
    }

    private var recentMemoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent memories")
                .font(AppTypography.sectionTitle)
            if insightsVM.insights.count < 2 {
                Text("More memories will appear as conversations are saved.")
                    .font(AppTypography.secondaryBody)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                ForEach(Array(insightsVM.insights.dropFirst().prefix(2))) { item in
                    Button { selectedMemory = item } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(AppTypography.cardTitle)
                            .lineLimit(1)
                        Text(item.displayHeadline.isEmpty ? item.displaySummary : item.displayHeadline)
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppColors.secondaryCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .appCard()
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
