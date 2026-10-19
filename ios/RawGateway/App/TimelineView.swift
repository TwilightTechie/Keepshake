import SwiftUI

// MARK: - Timeline View (Conversational History Stream)

struct TimelineView: View {
    @StateObject private var viewModel: InsightsViewModel
    @Environment(\.scenePhase) private var phase
    @State private var expandedSessionIDs: Set<String> = []
    @State private var copiedSessionID: String? = nil
    @State private var searchText = ""
    @State private var dateFilter = "All"

    init(settings: Settings) {
        _viewModel = StateObject(wrappedValue: InsightsViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header summary banner
                    timelineHeader

                    if viewModel.insights.isEmpty && !viewModel.isLoading {
                        emptyTimelineCard
                    } else if filteredInsights.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.title2)
                            Text("No matching memories").font(AppTypography.cardTitle)
                            Text("Try another search or date.").font(AppTypography.caption)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                        .appCard()
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(filteredInsights) { item in
                                sessionCard(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .background(AppColors.background)
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search memories")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.brandIndigo)
                        Text("Memory Stream")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.fetchInsights() }
                    } label: {
                        if viewModel.isLoading {
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
                    .disabled(viewModel.isLoading)
                }
            }
            .refreshable {
                await viewModel.fetchInsights()
            }
            .onAppear {
                Task { await viewModel.fetchInsights() }
            }
            .onChange(of: phase) { newPhase in
                if newPhase == .active {
                    Task { await viewModel.fetchInsights() }
                }
            }
        }
    }

    // MARK: - Timeline Header

    private var timelineHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your memories")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("\(filteredInsights.count) of \(viewModel.insights.count) recent summaries")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer()
            Menu {
                ForEach(["All", "Today", "Yesterday"], id: \.self) { option in
                    Button(option) { dateFilter = option }
                }
            } label: {
                Label(dateFilter, systemImage: "calendar")
                    .font(AppTypography.caption)
                    .padding(8)
                    .background(AppColors.cardBackground)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 2)
    }

    private var filteredInsights: [InsightItem] {
        let targetDate: String? = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            switch dateFilter {
            case "Today": return formatter.string(from: Date())
            case "Yesterday": return formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            default: return nil
            }
        }()
        return viewModel.insights.filter { item in
            let matchesDate = targetDate == nil || item.displayDate == targetDate
            let matchesSearch = searchText.isEmpty || ([item.displayTitle, item.displayHeadline, item.displaySummary]
                + item.displayKeyPoints + item.displayDecisions + item.displayActionItems)
                .joined(separator: " ").localizedCaseInsensitiveContains(searchText)
            return matchesDate && matchesSearch
        }
    }

    // MARK: - Session Card

    private func sessionCard(_ item: InsightItem) -> some View {
        let isExpanded = expandedSessionIDs.contains(item.id)

        return VStack(alignment: .leading, spacing: 12) {
            // Top Row: Title, Time, Words, and Copy button
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.textTertiary)

                        Text("\(friendlyDate(item.displayDate)) · \(String(item.displayTime.prefix(5)))")
                            .font(AppTypography.monoTag)
                            .foregroundStyle(AppColors.textTertiary)

                        if isExpanded, let words = item.word_count, words > 0 {
                            Text("· \(words) words")
                                .font(AppTypography.monoTag)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }

                Spacer()

                // Copy markdown button
                Button {
                    copySessionMarkdown(item)
                } label: {
                    Image(systemName: copiedSessionID == item.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copiedSessionID == item.id ? AppColors.verdictEmerald : AppColors.textTertiary)
                        .padding(6)
                        .background(AppColors.secondaryCardBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Headline Banner (Personalized second-person briefing)
            if isExpanded && !item.displayHeadline.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.brandIndigo)
                        .padding(.top, 2)

                    Text(item.displayHeadline)
                        .font(AppTypography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppColors.brandIndigo)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.indigoPillBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Executive Summary
            if !item.displaySummary.isEmpty {
                Text(item.displaySummary)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(isExpanded ? nil : 2)
            }

            // Collapsible Details: Key Highlights & Decisions
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.displayKeyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Highlights")
                                .font(AppTypography.cardTitle)
                                .foregroundStyle(AppColors.textSecondary)

                            ForEach(item.displayKeyPoints, id: \.self) { point in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(AppColors.brandIndigo)
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 7)
                                    Text(point)
                                        .font(AppTypography.caption)
                                        .foregroundStyle(AppColors.textPrimary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.secondaryCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !item.displayDecisions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Decisions Made")
                                .font(AppTypography.cardTitle)
                                .foregroundStyle(AppColors.verdictEmerald)

                            ForEach(item.displayDecisions, id: \.self) { dec in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppColors.verdictEmerald)
                                        .padding(.top, 2)
                                    Text(dec)
                                        .font(AppTypography.caption)
                                        .foregroundStyle(AppColors.textPrimary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.emeraldPillBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            // Expand / Collapse Toggle Button
            Button {
                toggleExpanded(item.id)
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Show less" : "Read memory")
                        .font(AppTypography.caption)
                        .fontWeight(.medium)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(AppColors.brandIndigo)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private func friendlyDate(_ value: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let display = DateFormatter()
        display.dateStyle = .medium
        return display.string(from: date)
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedSessionIDs.contains(id) {
                expandedSessionIDs.remove(id)
            } else {
                expandedSessionIDs.insert(id)
            }
        }
    }

    private func copySessionMarkdown(_ item: InsightItem) {
        var md = "# \(item.displayTitle)\n"
        md += "**Time**: \(item.displayDate) \(item.displayTime)\n\n"
        if !item.displayHeadline.isEmpty {
            md += "> \(item.displayHeadline)\n\n"
        }
        if !item.displaySummary.isEmpty {
            md += "## Executive Summary\n\(item.displaySummary)\n\n"
        }
        if !item.displayDecisions.isEmpty {
            md += "## Decisions\n"
            for d in item.displayDecisions { md += "- \(d)\n" }
            md += "\n"
        }
        if !item.displayActionItems.isEmpty {
            md += "## Action Items\n"
            for a in item.displayActionItems { md += "- [ ] \(a)\n" }
        }

        UIPasteboard.general.string = md
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedSessionID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if copiedSessionID == item.id {
                copiedSessionID = nil
            }
        }
    }

    // MARK: - Empty State

    private var emptyTimelineCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(AppColors.textTertiary)
            Text("No memories yet")
                .font(AppTypography.cardTitle)
                .foregroundStyle(AppColors.textSecondary)
            Text("Your saved conversation summaries will appear here.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }
}
