import SwiftUI
import Combine

// MARK: - App Theme Mode

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Theme Manager

public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    private let key = "app_theme_mode"

    @Published public var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: key)
        }
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: key) ?? AppTheme.system.rawValue
        self.currentTheme = AppTheme(rawValue: saved) ?? .system
    }

    public func setTheme(_ theme: AppTheme) {
        currentTheme = theme
    }
}

// MARK: - Semantic Color Tokens

public enum AppColors {
    // Dynamic Surface Colors (Adapts to Light / Dark automatically)
    public static var background: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
                : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
        })
    }

    public static var cardBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
                : UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)
        })
    }

    public static var secondaryCardBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1.0)
                : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1.0)
        })
    }

    public static var cardBorder: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.08)
                : UIColor(white: 0.0, alpha: 0.07)
        })
    }

    public static var divider: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.06)
                : UIColor(white: 0.0, alpha: 0.06)
        })
    }

    // Dynamic Text Colors
    public static var textPrimary: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.98, green: 0.98, blue: 1.00, alpha: 1.0)
                : UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        })
    }

    public static var textSecondary: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.65, green: 0.68, blue: 0.76, alpha: 1.0)
                : UIColor(red: 0.40, green: 0.44, blue: 0.52, alpha: 1.0)
        })
    }

    public static var textTertiary: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.45, green: 0.48, blue: 0.56, alpha: 1.0)
                : UIColor(red: 0.60, green: 0.64, blue: 0.72, alpha: 1.0)
        })
    }

    // Brand & Semantic Accents
    public static let brandIndigo = Color(red: 0.39, green: 0.36, blue: 0.95)
    public static let verdictEmerald = Color(red: 0.06, green: 0.73, blue: 0.51)
    public static let actionBlue = Color(red: 0.23, green: 0.51, blue: 0.96)
    public static let warningAmber = Color(red: 0.96, green: 0.62, blue: 0.04)
    public static let errorRose = Color(red: 0.94, green: 0.27, blue: 0.38)
    public static let accentCyan = Color(red: 0.02, green: 0.71, blue: 0.83)
    public static let purpleAccent = Color(red: 0.66, green: 0.35, blue: 0.94)

    // Soft Pill Badges
    public static var emeraldPillBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 0.15)
                : UIColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 0.10)
        })
    }

    public static var indigoPillBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.39, green: 0.36, blue: 0.95, alpha: 0.18)
                : UIColor(red: 0.39, green: 0.36, blue: 0.95, alpha: 0.10)
        })
    }

    public static var bluePillBackground: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 0.18)
                : UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 0.10)
        })
    }
}

// MARK: - Semantic Typography Tokens

public enum AppTypography {
    public static let appTitle = Font.system(.title, design: .rounded).weight(.bold)
    public static let sectionTitle = Font.system(.headline, design: .rounded).weight(.semibold)
    public static let cardTitle = Font.system(.subheadline, design: .default).weight(.semibold)
    public static let body = Font.system(.body, design: .default)
    public static let secondaryBody = Font.system(.subheadline, design: .default)
    public static let caption = Font.system(.caption, design: .default)
    public static let metricNumber = Font.system(.title2, design: .rounded).weight(.bold)
    public static let monoTag = Font.system(.caption2, design: .monospaced)
}

// MARK: - Card Surface ViewModifier

public struct AppCardModifier: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 16

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            )
    }
}

public extension View {
    func appCard(padding: CGFloat = 16, cornerRadius: CGFloat = 16) -> some View {
        modifier(AppCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}
