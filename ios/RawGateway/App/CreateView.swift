import SwiftUI
import UIKit

private struct PostMessage: Decodable {
    let role: String
    let text: String
}

private struct PostDraft: Identifiable, Decodable {
    let id: String
    let platform: String
    let topic: String
    let text: String
    let status: String
    let created_at: String
    let source_date: String
    let messages: [PostMessage]
    let published_url: String?
}

private struct PostListResponse: Decodable {
    let drafts: [PostDraft]
    let x_configured: Bool
    let has_today_context: Bool
}

private struct GeneratedPostsResponse: Decodable {
    let drafts: [PostDraft]
}

private struct ServerErrorResponse: Decodable {
    let detail: String
}

@MainActor
private final class CreateViewModel: ObservableObject {
    @Published var drafts: [PostDraft] = []
    @Published var xConfigured = false
    @Published var isLoading = false
    @Published var isWorking = false
    @Published var errorMessage: String?

    private let settings: Settings
    private var autoAttempted = false

    init(settings: Settings) { self.settings = settings }

    private var baseURL: URL? {
        guard let webhook = URL(string: settings.dreamAIWebhook),
              let scheme = webhook.scheme, let host = webhook.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = webhook.port
        components.path = "/omi/api/posts"
        return components.url
    }

    private var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func request<T: Decodable>(_ path: String = "", method: String = "GET",
                                       body: [String: String]? = nil, dateQuery: Bool = false) async throws -> T {
        guard let baseURL else { throw CreateError.message("Set a valid server address on the Device tab.") }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if !path.isEmpty { components.path += "/" + path }
        if dateQuery { components.queryItems = [URLQueryItem(name: "local_date", value: today)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = method == "POST" && path == "generate" ? 130 : 30
        guard !settings.postsToken.isEmpty else {
            throw CreateError.message("Set the Create API token in Device → Settings & diagnostics → Server & Auth.")
        }
        request.setValue("Bearer \(settings.postsToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CreateError.message("Invalid server response.") }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data).detail)
                ?? "Server returned HTTP \(http.statusCode)."
            throw CreateError.message(detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func load(autoGenerate: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result: PostListResponse = try await request(dateQuery: true)
            drafts = result.drafts
            xConfigured = result.x_configured
            errorMessage = nil
            if autoGenerate && !autoAttempted && result.has_today_context &&
               !drafts.contains(where: { $0.source_date == today }) {
                autoAttempted = true
                Task { await generate(instruction: "") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate(instruction: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result: GeneratedPostsResponse = try await request(
                "generate", method: "POST", body: ["local_date": today, "instruction": instruction])
            drafts.insert(contentsOf: result.drafts, at: 0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revise(id: String, instruction: String) async -> PostDraft? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let result: PostDraft = try await request("\(id)/revise", method: "POST",
                                                       body: ["instruction": instruction])
            replace(result)
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func save(id: String, text: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let result: PostDraft = try await request(id, method: "PUT", body: ["text": text])
            replace(result)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func publish(id: String, text: String) async -> PostDraft? {
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let result: PostDraft = try await request("\(id)/publish", method: "POST", body: ["text": text])
            replace(result)
            errorMessage = nil
            return result
        } catch {
            let failure = error.localizedDescription
            await load(autoGenerate: false)
            errorMessage = failure
            return nil
        }
    }

    private func replace(_ draft: PostDraft) {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index] = draft }
    }

    func draft(id: String) -> PostDraft? { drafts.first(where: { $0.id == id }) }
}

private enum CreateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

struct CreateView: View {
    @StateObject private var model: CreateViewModel
    @State private var prompt = ""

    init(settings: Settings) {
        _model = StateObject(wrappedValue: CreateViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ideas worth sharing")
                            .font(AppTypography.sectionTitle)
                        Text("Turn today's conversations into X posts. Every draft stays private until you review and publish it.")
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Generate ideas", systemImage: "sparkles")
                            .font(.headline)
                        TextField("Try: Write about routing in a practical tone", text: $prompt, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.generate(instruction: instruction)
                                if model.errorMessage == nil { prompt = "" }
                            }
                        } label: {
                            if model.isWorking { ProgressView().frame(maxWidth: .infinity) }
                            else { Label("Generate X drafts", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.brandIndigo)
                        .disabled(model.isWorking)
                    }
                    .padding()
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(AppColors.errorRose)
                    }

                    HStack {
                        Text("Drafts")
                            .font(AppTypography.sectionTitle)
                        Spacer()
                        if model.isLoading { ProgressView() }
                    }

                    if model.drafts.isEmpty && !model.isLoading {
                        Text("Your ideas will appear here. Generate from today's summaries or ask for a specific topic above.")
                            .font(AppTypography.secondaryBody)
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(AppColors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    ForEach(model.drafts) { draft in
                        NavigationLink {
                            PostEditorView(model: model, draftID: draft.id, initialText: draft.text)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(draft.topic, systemImage: "bubble.left.and.text.bubble.right")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(draft.status == "published" ? "Published" :
                                         draft.status == "publish_unknown" ? "Check X" : "Draft")
                                        .font(.caption)
                                        .foregroundStyle(draft.status == "published" ? AppColors.verdictEmerald : AppColors.brandIndigo)
                                }
                                Text(draft.text)
                                    .font(AppTypography.secondaryBody)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(draft.source_date)
                                    .font(.caption2)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .padding()
                            .background(AppColors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
            .background(AppColors.background)
            .navigationTitle("Create")
            .refreshable { await model.load(autoGenerate: false) }
            .task { await model.load() }
        }
    }
}

private struct PostEditorView: View {
    @ObservedObject var model: CreateViewModel
    let draftID: String
    @State private var text: String
    @State private var instruction = ""
    @State private var showPublishConfirmation = false

    init(model: CreateViewModel, draftID: String, initialText: String) {
        self.model = model
        self.draftID = draftID
        _text = State(initialValue: initialText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let draft = model.draft(id: draftID) {
                    Text(draft.topic)
                        .font(AppTypography.sectionTitle)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Post text")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $text)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                            .disabled(draft.status != "draft")
                            .padding(8)
                            .background(AppColors.secondaryCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("\(text.count) / 280 characters")
                            .font(.caption)
                            .foregroundStyle(text.count > 280 ? AppColors.errorRose : AppColors.textSecondary)
                        HStack {
                            Button("Save edits") {
                                Task { _ = await model.save(id: draftID, text: text) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isWorking || text.isEmpty || text.count > 280 || draft.status != "draft")
                            Button("Copy text") { UIPasteboard.general.string = text }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if draft.status == "draft" {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Refine with AI")
                                .font(.headline)
                            ForEach(Array(draft.messages.enumerated()), id: \.offset) { _, message in
                                Text(message.text)
                                    .font(.subheadline)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(message.role == "user" ? AppColors.emeraldPillBackground : AppColors.secondaryCardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            TextField("Make it sharper, simpler, more technical…", text: $instruction, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                            Button("Ask for revision") {
                                let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task {
                                    if text != draft.text {
                                        guard await model.save(id: draftID, text: text) else { return }
                                    }
                                    if let revised = await model.revise(id: draftID, instruction: request) {
                                        text = revised.text
                                        instruction = ""
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isWorking || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding()
                        .background(AppColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        Button {
                            showPublishConfirmation = true
                        } label: {
                            Label(model.xConfigured ? "Post to X" : "Connect X on server to publish", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.xConfigured || model.isWorking || text.isEmpty || text.count > 280)
                        .confirmationDialog("Post this exact text to X?", isPresented: $showPublishConfirmation) {
                            Button("Post to X") {
                                Task { _ = await model.publish(id: draftID, text: text) }
                            }
                        } message: {
                            Text(text)
                        }
                    } else if draft.status == "published", let publishedURL = draft.published_url,
                              let url = URL(string: publishedURL) {
                        Link("View on X", destination: url)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text("Publishing result is uncertain. Check your X profile before attempting another post.")
                            .font(.caption)
                            .foregroundStyle(AppColors.warningAmber)
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(AppColors.errorRose)
                    }
                }
            }
            .padding()
            .padding(.bottom, 80)
        }
        .background(AppColors.background)
        .navigationTitle("X draft")
        .navigationBarTitleDisplayMode(.inline)
    }
}
