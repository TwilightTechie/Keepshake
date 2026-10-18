import SwiftUI

// MARK: - Decision Item Model

struct DecisionItem: Identifiable, Codable, Equatable {
    let id: String
    let time: String
    let title: String
    let decision: String
    let context_summary: String
    let category: String
    let status: String

    var displayTime: String {
        time.isEmpty ? "" : time
    }

    var displayTitle: String {
        title.isEmpty ? "Decision" : title
    }

    var displayCategory: String {
        category.isEmpty ? "General" : category.capitalized
    }
}

// MARK: - Decisions Response Schema

struct DecisionsResponse: Codable {
    let date: String?
    let total_decisions: Int?
    let decisions: [DecisionItem]?
}

// MARK: - Decision Card View

struct DecisionCard: View {
    let item: DecisionItem
    let isCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Category Pill, Time, & Completion Toggle
            HStack(alignment: .center, spacing: 8) {
                // Category badge
                Text(item.displayCategory)
                    .font(AppTypography.monoTag)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(categoryBackgroundColor)
                    .foregroundStyle(categoryTextColor)
                    .clipShape(Capsule())

                // Time badge
                if !item.displayTime.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(item.displayTime)
                            .font(AppTypography.monoTag)
                    }
                    .foregroundStyle(AppColors.textTertiary)
                }

                Spacer()

                // Interactive Completion Toggle Button
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Image(systemName: isCompleted ? "checkmark.seal.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isCompleted ? AppColors.verdictEmerald : AppColors.textTertiary)

                        Text(isCompleted ? "Completed" : "Mark Done")
                            .font(AppTypography.caption)
                            .foregroundStyle(isCompleted ? AppColors.verdictEmerald : AppColors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isCompleted ? AppColors.emeraldPillBackground : AppColors.secondaryCardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(isCompleted ? AppColors.verdictEmerald.opacity(0.3) : AppColors.cardBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            // Main Decision Statement
            Text(item.decision)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(isCompleted, color: AppColors.textTertiary)

            // Context / Conversation Reference Box
            if !item.title.isEmpty || !item.context_summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !item.title.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppColors.brandIndigo)
                            Text(item.displayTitle)
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    if !item.context_summary.isEmpty && item.context_summary != item.decision {
                        Text(item.context_summary)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.secondaryCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isCompleted ? AppColors.verdictEmerald.opacity(0.4) : AppColors.cardBorder, lineWidth: 1)
        )
        .shadow(
            color: isCompleted ? AppColors.verdictEmerald.opacity(0.08) : Color.black.opacity(0.03),
            radius: isCompleted ? 8 : 4,
            x: 0,
            y: 2
        )
    }

    private var categoryBackgroundColor: Color {
        switch item.category.lowercased() {
        case "technical":
            return AppColors.indigoPillBackground
        case "product":
            return AppColors.actionBlue.opacity(0.12)
        case "legal":
            return Color.orange.opacity(0.12)
        case "financial":
            return AppColors.emeraldPillBackground
        default:
            return AppColors.emeraldPillBackground
        }
    }

    private var categoryTextColor: Color {
        switch item.category.lowercased() {
        case "technical":
            return AppColors.brandIndigo
        case "product":
            return AppColors.actionBlue
        case "legal":
            return Color.orange
        case "financial":
            return AppColors.verdictEmerald
        default:
            return AppColors.verdictEmerald
        }
    }
}
