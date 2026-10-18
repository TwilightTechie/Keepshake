import SwiftUI

struct WaveformVisualizerView: View {
    let isActive: Bool
    var barCount: Int = 6
    var barWidth: CGFloat = 3.5
    var maxBarHeight: CGFloat = 22
    var minBarHeight: CGFloat = 4
    var activeColor: Color = AppColors.verdictEmerald

    @State private var phase: CGFloat = 0.0

    init(
        isActive: Bool,
        barCount: Int = 6,
        barWidth: CGFloat = 3.5,
        maxBarHeight: CGFloat = 22,
        minBarHeight: CGFloat = 4,
        activeColor: Color = AppColors.verdictEmerald
    ) {
        self.isActive = isActive
        self.barCount = barCount
        self.barWidth = barWidth
        self.maxBarHeight = maxBarHeight
        self.minBarHeight = minBarHeight
        self.activeColor = activeColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(isActive ? activeColor : AppColors.textTertiary.opacity(0.35))
                    .frame(width: barWidth, height: currentHeight(for: index))
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.35 + Double(index) * 0.05).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.3),
                        value: phase
                    )
            }
        }
        .frame(height: maxBarHeight)
        .onAppear {
            if isActive {
                phase = 1.0
            }
        }
        .onChange(of: isActive) { active in
            phase = active ? 1.0 : 0.0
        }
    }

    private func currentHeight(for index: Int) -> CGFloat {
        guard isActive else { return minBarHeight }
        // Generate pseudo-random organic bar heights based on phase and index
        let pattern: [CGFloat] = [0.45, 0.85, 1.0, 0.70, 0.90, 0.50]
        let factor = pattern[index % pattern.count]
        let range = maxBarHeight - minBarHeight
        return minBarHeight + range * factor * (0.5 + 0.5 * phase)
    }
}
