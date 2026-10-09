import SwiftUI

struct PreferencesAppearance: ViewModifier {
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(colorScheme)
            .tint(accentColor)
            .accentColor(accentColor)
            .environment(\.locale, locale)
            .environment(\.breweryReduceMotion, systemReduceMotion || preferences.values.reduceMotion)
            .transaction { transaction in
                if systemReduceMotion || preferences.values.reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }

    private var colorScheme: ColorScheme? {
        switch preferences.values.theme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
    private var accentColor: Color {
        switch preferences.values.accent {
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "orange": .orange
        case "green": .green
        default: Color(nsColor: .controlAccentColor)
        }
    }
    private var locale: Locale {
        if AppPreferences.isTesting && preferences.values.language == "system" { return Locale(identifier: "en") }
        return preferences.values.language == "system" ? .current : Locale(identifier: preferences.values.language)
    }
}

/// Restores the normal window frame once, and lets AppKit save subsequent moves.
struct RememberWindowFrame: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> WindowAttachment { WindowAttachment() }
    func updateNSView(_ view: WindowAttachment, context: Context) {
        view.remember = enabled && !AppPreferences.isTesting
        view.configureWindow()
    }

    final class WindowAttachment: NSView {
        var remember = false
        private weak var configuredWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }
        func configureWindow() {
            guard let window else { return }
            if configuredWindow !== window {
                configuredWindow = window
                if remember { window.setFrameUsingName("BreweryMainWindow") }
            }
            window.setFrameAutosaveName(remember ? "BreweryMainWindow" : "")
        }
    }
}

private struct BreweryReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var breweryReduceMotion: Bool {
        get { self[BreweryReduceMotionKey.self] }
        set { self[BreweryReduceMotionKey.self] = newValue }
    }
}
