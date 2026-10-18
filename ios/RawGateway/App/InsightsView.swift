import SwiftUI
import Combine

// MARK: - Models

struct InsightItem: Identifiable, Codable {
    let id: String
    let timestamp: String?
    let time: String?
    let date: String?
    let title: String?
    let headline: String?
    let summary: String?
    let decisions: [String]?
    let action_items: [String]?
    let key_points: [String]?
    let word_count: Int?
    let utterance_count: Int?
    let processing_time_sec: Double?

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Conversation Insights" : t
    }

    var displayHeadline: String {
        (headline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displaySummary: String {
        (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayDecisions: [String] {
        decisions ?? []
    }

    var displayActionItems: [String] {
        action_items ?? []
    }

    var displayKeyPoints: [String] {
        key_points ?? []
    }

    var displayDate: String {
        if let d = date, !d.isEmpty { return d }
        if let ts = timestamp, ts.count >= 10 { return String(ts.prefix(10)) }
        return ""
    }

    var displayTime: String {
        if let t = time, !t.isEmpty { return t }
        if let ts = timestamp, ts.count >= 19 {
            let start = ts.index(ts.startIndex, offsetBy: 11)
            let end = ts.index(ts.startIndex, offsetBy: 19)
            return String(ts[start..<end])
        }
        return ""
    }
}

// MARK: - View Model

@MainActor
final class InsightsViewModel: ObservableObject {
    @Published var insights: [InsightItem] = []
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorMessage: String? = nil
    @Published var lastRefreshed: Date? = nil

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
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

    /// Fetches existing summaries from the server without triggering an LLM re-run.
    func fetchInsights() async {
        guard !isLoading else { return }
        isLoading = true

        let candidateEndpoints = [
            "\(baseURL)/omi/api/summaries?limit=30",
            "\(baseURL)/dream-ai/api/summaries?limit=30"
        ]

        var loadedData: Data? = nil
        var lastHTTPCode = 0

        for ep in candidateEndpoints {
            guard let url = URL(string: ep) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if !settings.webhookToken.isEmpty {
                request.setValue("Bearer \(settings.webhookToken)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    lastHTTPCode = http.statusCode
                    if http.statusCode == 200 {
                        loadedData = data
                        break
                    }
                }
            } catch {
                // Continue to next candidate
            }
        }

        guard let data = loadedData else {
            isLoading = false
            if insights.isEmpty {
                errorMessage = "Could not reach server (HTTP \(lastHTTPCode > 0 ? "\(lastHTTPCode)" : "connection failed"))."
            }
            return
        }

        do {
            let items = try JSONDecoder().decode([InsightItem].self, from: data)
            self.insights = items
            self.errorMessage = nil
            self.lastRefreshed = Date()
        } catch {
            // Robust fallback: parse JSON array and decode element by element
            if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var recovered: [InsightItem] = []
                for dict in rawArray {
                    if let itemData = try? JSONSerialization.data(withJSONObject: dict),
                       let item = try? JSONDecoder().decode(InsightItem.self, from: itemData) {
                        recovered.append(item)
                    }
                }
                if !recovered.isEmpty {
                    self.insights = recovered
                    self.errorMessage = nil
                    self.lastRefreshed = Date()
                } else {
                    self.errorMessage = "Could not decode summaries: \(error.localizedDescription)"
                }
            } else {
                self.errorMessage = "Could not decode summaries: \(error.localizedDescription)"
            }
        }

        isLoading = false
    }

    /// Specifically called ONLY when user taps "Summarize" to trigger Qwen 3 (8B) LLM analysis.
    func generateOnDemand(minutes: Int = 10) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil

        let candidateEndpoints = [
            "\(baseURL)/omi/api/summarize?minutes=\(minutes)",
            "\(baseURL)/dream-ai/api/summarize?minutes=\(minutes)"
        ]

        var success = false
        var lastHTTPCode = 0

        for ep in candidateEndpoints {
            guard let url = URL(string: ep) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            if !settings.webhookToken.isEmpty {
                request.setValue("Bearer \(settings.webhookToken)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    lastHTTPCode = http.statusCode
                    if http.statusCode == 200 {
                        success = true
                        break
                    }
                }
            } catch {
                // Continue to next candidate
            }
        }

        if success {
            // Pull the newly generated summary immediately
            await fetchInsights()
        } else {
            errorMessage = "Summarization failed (HTTP \(lastHTTPCode > 0 ? "\(lastHTTPCode)" : "timeout")). Make sure Qwen model is running."
        }

        isGenerating = false
    }
}

// MARK: - Insights View

struct InsightsView: View {
    @StateObject private var viewModel: InsightsViewModel
    @Environment(\.scenePhase) private var phase

    init(settings: Settings) {
        _viewModel = StateObject(wrappedValue: InsightsViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    greetingHeader

                    if viewModel.isGenerating {
                        generatingBanner
                    }

                    if let error = viewModel.errorMessage, !viewModel.isGenerating {
                        errorBanner(error)
                    }

                    if viewModel.insights.isEmpty && !viewModel.isLoading && !viewModel.isGenerating {
                        emptyStateCard
                    } else {
                        ForEach(viewModel.insights) { item in
                            InsightCard(item: item)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                        Text("Day Briefing")
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await viewModel.fetchInsights() }
                        } label: {
                            if viewModel.isLoading && !viewModel.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                        .disabled(viewModel.isLoading || viewModel.isGenerating)

                        Button {
                            Task { await viewModel.generateOnDemand(minutes: 10) }
                        } label: {
                            if viewModel.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                    Text("Summarize")
                                }
                                .font(.caption)
                                .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(viewModel.isGenerating)
                    }
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

    // MARK: - Header

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(timeGreeting)
                    .font(.title2).fontWeight(.bold)
                Spacer()
                if let refreshed = viewModel.lastRefreshed {
                    Text("Updated \(refreshed, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Here is what you've discussed, decided, and committed to:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning, Anup 👋" }
        if hour < 17 { return "Good afternoon, Anup 👋" }
        return "Good evening, Anup 👋"
    }

    // MARK: - Status Banners

    private var generatingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analyzing recent conversations…")
                    .font(.subheadline).fontWeight(.semibold)
                Text("Qwen 3 8B is extracting decisions and personalized action items.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task { await viewModel.fetchInsights() }
            }
            .font(.caption).fontWeight(.semibold)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Empty State

    private var emptyStateCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("No Insights Yet Today")
                    .font(.headline)
                Text("Speak into your Keepsake pendant. Conversations will automatically be summarized into personalized decisions and action items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task { await viewModel.fetchInsights() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Insight Card

struct InsightCard: View {
    let item: InsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title & Time
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(item.displayDate) · \(item.displayTime)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let words = item.word_count, words > 0 {
                            Text("· \(words) words")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "sparkle")
                    .font(.subheadline)
                    .foregroundStyle(.yellow)
            }

            // Headline Banner (Personalized Greeting)
            if !item.displayHeadline.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(item.displayHeadline)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Executive Summary
            if !item.displaySummary.isEmpty {
                Text(item.displaySummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            // Decisions Taken
            if !item.displayDecisions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Decisions Taken", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.displayDecisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(.top, 2)
                                Text(decision)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Action Items for Anup
            if !item.displayActionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Action Items for You", systemImage: "checklist")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.displayActionItems, id: \.self) { action in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .padding(.top, 2)
                                Text(action)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Key Points / Context
            if !item.displayKeyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Key Insights", systemImage: "lightbulb.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.displayKeyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(point)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 2)
    }
}
