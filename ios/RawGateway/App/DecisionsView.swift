import SwiftUI
import Combine

// MARK: - Decisions View Model

@MainActor
final class DecisionsViewModel: ObservableObject {
    @Published var decisions: [DecisionItem] = []
    @Published var completedDecisionIDs: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var selectedCategory = "All"
    @Published var filterTab: DecisionFilterTab = .all
    @Published var lastRefreshed: Date? = nil

    enum DecisionFilterTab: String, CaseIterable, Identifiable {
        case all = "All"
        case pending = "Pending"
        case completed = "Completed"

        var id: String { rawValue }
    }

    private let settings: Settings
    private let completedKey = "completed_decision_ids"
    private var session = URLSession(configuration: .default)

    init(settings: Settings) {
        self.settings = settings
        loadSavedCompletedIDs()
        loadCachedDecisions()
        Task {
            await fetchDecisions()
        }
    }

    private var baseURL: String {
        if let url = URL(string: settings.dreamAIWebhook.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme,
           let host = url.host {
            let portStr = url.port != nil ? ":\(url.port!)" : ""
            return "\(scheme)://\(host)\(portStr)"
        }
        return "https://aadeshai.xyz"
    }

    private var cacheFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("decisions_today.json")
    }

    // MARK: - Persistence

    private func loadSavedCompletedIDs() {
        if let saved = UserDefaults.standard.stringArray(forKey: completedKey) {
            completedDecisionIDs = Set(saved)
        }
    }

    private func saveCompletedIDs() {
        UserDefaults.standard.set(Array(completedDecisionIDs), forKey: completedKey)
    }

    private func loadCachedDecisions() {
        guard let url = cacheFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(DecisionsResponse.self, from: data),
              let cached = envelope.decisions,
              !cached.isEmpty else { return }
        self.decisions = cached
    }

    private func saveToCache(_ envelope: DecisionsResponse) {
        guard let url = cacheFileURL,
              let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - API Fetching

    func fetchDecisions() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let urlString = "\(baseURL)/omi/api/decisions/today"
        guard let url = URL(string: urlString) else {
            isLoading = false
            errorMessage = "Invalid endpoint URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0

        let token = settings.webhookToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                isLoading = false
                errorMessage = "Invalid server response"
                return
            }

            guard httpResp.statusCode == 200 else {
                isLoading = false
                errorMessage = "Server error (\(httpResp.statusCode))"
                return
            }

            let envelope = try JSONDecoder().decode(DecisionsResponse.self, from: data)
            let items = envelope.decisions ?? []
            self.decisions = items
            self.lastRefreshed = Date()
            self.saveToCache(envelope)
            self.isLoading = false
        } catch {
            self.isLoading = false
            if decisions.isEmpty {
                self.errorMessage = "Could not load decisions: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - User Actions

    func toggleDecisionCompleted(id: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if completedDecisionIDs.contains(id) {
            completedDecisionIDs.remove(id)
        } else {
            completedDecisionIDs.insert(id)
        }
        saveCompletedIDs()
    }

    func isCompleted(id: String) -> Bool {
        completedDecisionIDs.contains(id)
    }

    // MARK: - Computed Filters

    var categories: [String] {
        var set = Set<String>()
        for d in decisions {
            if !d.category.isEmpty {
                set.insert(d.displayCategory)
            }
        }
        return ["All"] + set.sorted()
    }

    var completedCount: Int {
        decisions.filter { completedDecisionIDs.contains($0.id) }.count
    }

    var pendingCount: Int {
        decisions.count - completedCount
    }

    var filteredDecisions: [DecisionItem] {
        decisions.filter { item in
            // Category filter
            if selectedCategory != "All" && item.displayCategory != selectedCategory {
                return false
            }
            // Tab filter
            switch filterTab {
            case .all:
                return true
            case .pending:
                return !completedDecisionIDs.contains(item.id)
            case .completed:
                return completedDecisionIDs.contains(item.id)
            }
        }
    }
}

// MARK: - Embedded Today Decisions Block View

struct TodayDecisionsBlockView: View {
    @ObservedObject var viewModel: DecisionsViewModel
    @State private var showFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppColors.emeraldPillBackground)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.verdictEmerald)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("The Verdict")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColors.textPrimary)

                        if viewModel.decisions.count > 0 {
                            Text("\(viewModel.decisions.count)")
                                .font(AppTypography.monoTag)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppColors.emeraldPillBackground)
                                .foregroundStyle(AppColors.verdictEmerald)
                                .clipShape(Capsule())
                        }
                    }

                    Text("Decisions & Strategic Calls Made Today")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button {
                        Task { await viewModel.fetchDecisions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .padding(8)
                            .background(AppColors.secondaryCardBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Decisions List Preview (up to 3 items)
            if viewModel.decisions.isEmpty && !viewModel.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundStyle(AppColors.textTertiary)
                    Text("No decisions recorded yet today")
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("Speak into your pendant throughout the day to automatically track decisions and calls.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                let previewItems = Array(viewModel.decisions.prefix(3))
                VStack(spacing: 10) {
                    ForEach(previewItems) { item in
                        DecisionCard(
                            item: item,
                            isCompleted: viewModel.isCompleted(id: item.id),
                            onToggle: {
                                viewModel.toggleDecisionCompleted(id: item.id)
                            }
                        )
                    }
                }

                // "See All" button
                if viewModel.decisions.count > 3 {
                    Button {
                        showFullScreen = true
                    } label: {
                        HStack {
                            Text("See All \(viewModel.decisions.count) Decisions")
                                .font(AppTypography.cardTitle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppColors.brandIndigo)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppColors.indigoPillBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
        .sheet(isPresented: $showFullScreen) {
            DecisionsView(viewModel: viewModel)
        }
    }
}

// MARK: - Full Decisions View Screen

struct DecisionsView: View {
    @ObservedObject var viewModel: DecisionsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter Controls Bar
                VStack(spacing: 10) {
                    // Segmented Filter: All / Pending / Completed
                    Picker("Filter", selection: $viewModel.filterTab) {
                        ForEach(DecisionsViewModel.DecisionFilterTab.allCases) { tab in
                            switch tab {
                            case .all:
                                Text("All (\(viewModel.decisions.count))").tag(tab)
                            case .pending:
                                Text("Pending (\(viewModel.pendingCount))").tag(tab)
                            case .completed:
                                Text("Completed (\(viewModel.completedCount))").tag(tab)
                            }
                        }
                    }
                    .pickerStyle(.segmented)

                    // Category Filter Chips
                    if viewModel.categories.count > 2 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.categories, id: \.self) { cat in
                                    Button {
                                        viewModel.selectedCategory = cat
                                    } label: {
                                        Text(cat)
                                            .font(AppTypography.caption)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                viewModel.selectedCategory == cat
                                                    ? AppColors.verdictEmerald
                                                    : AppColors.secondaryCardBackground
                                            )
                                            .foregroundStyle(
                                                viewModel.selectedCategory == cat
                                                    ? Color.white
                                                    : AppColors.textPrimary
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppColors.cardBackground)

                Divider()
                    .background(AppColors.cardBorder)

                // Decision Cards List
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.filteredDecisions.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                                    .font(.system(size: 36))
                                    .foregroundStyle(AppColors.textTertiary)
                                Text("No matching decisions")
                                    .font(AppTypography.cardTitle)
                                    .foregroundStyle(AppColors.textSecondary)
                                Text("Try selecting a different filter or category above.")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        } else {
                            ForEach(viewModel.filteredDecisions) { item in
                                DecisionCard(
                                    item: item,
                                    isCompleted: viewModel.isCompleted(id: item.id),
                                    onToggle: {
                                        viewModel.toggleDecisionCompleted(id: item.id)
                                    }
                                )
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    await viewModel.fetchDecisions()
                }
            }
            .background(AppColors.background)
            .navigationTitle("The Verdict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let dateStr = viewModel.lastRefreshed {
                        Text(dateStr, style: .time)
                            .font(AppTypography.monoTag)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(AppColors.brandIndigo)
                }
            }
        }
    }
}
