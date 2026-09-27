import Foundation
import PhoneScreenKit

/// `PhoneScreen --theme-test <folder or theme.json>`: reads the theme exactly as the app installs it and prints it
/// (exit 0) with readability warnings, or the error (exit 1). For theme authors and AI agents.
enum ThemeTestRunner {
    static func run(_ url: URL) {
        do {
            let theme = try ThemeStore.read(url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(theme))
            for warning in theme.contrastWarnings() {
                FileHandle.standardError.write(Data("⚠ \(warning)\n".utf8))
            }
            FileHandle.standardOutput.write(Data("\nOK\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
