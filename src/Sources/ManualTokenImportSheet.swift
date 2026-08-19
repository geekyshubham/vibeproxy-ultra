import SwiftUI

struct ManualTokenImportSheet: View {
    let serviceType: ServiceType
    let onImport: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste \(serviceType.displayName) tokens")
                .font(.headline)
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pasted)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Account") {
                    onImport(pasted)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var helpText: String {
        switch serviceType {
        case .codex:
            return "Paste ~/.codex/auth.json (the object with tokens.access_token / refresh_token) or a CLIProxy codex-*.json file."
        case .claude:
            return "Paste Claude Code credentials JSON (claudeAiOauth) or a CLIProxy claude-*.json file."
        case .cursor:
            return "Paste Cursor token JSON (accessToken, refreshToken, email) exported from Cockpit or copied from Cursor’s local state."
        case .gemini, .antigravity:
            return "Paste Google OAuth JSON (access_token + refresh_token), typically from oauth_creds.json."
        case .copilot:
            return "Paste a GitHub Copilot oauth JSON object that includes accessToken / access_token."
        case .zai:
            return "Paste a Z.AI API key, or JSON with an api_key field."
        default:
            return "Paste the provider’s auth JSON (must include access_token, and refresh_token when the provider uses one)."
        }
    }
}

struct PasteJSONRequest: Identifiable {
    let type: ServiceType
    var id: String { type.rawValue }
}
