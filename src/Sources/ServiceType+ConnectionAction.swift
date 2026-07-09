enum ServiceConnectionAction: Equatable {
    case authCommand(AuthCommand)
    case promptForQwenEmail
    case promptForZAIAPIKey
}

extension ServiceType {
    var connectionAction: ServiceConnectionAction {
        switch self {
        case .claude:
            return .authCommand(.claudeLogin)
        case .codex:
            return .authCommand(.codexLogin)
        case .copilot:
            return .authCommand(.copilotLogin)
        case .gemini:
            return .authCommand(.geminiLogin)
        case .kimi:
            return .authCommand(.kimiLogin)
        case .qwen:
            return .promptForQwenEmail
        case .antigravity:
            return .authCommand(.antigravityLogin)
        case .kiro:
            return .authCommand(.kiroLogin)
        case .grok:
            return .authCommand(.xaiLogin)
        case .zai:
            return .promptForZAIAPIKey
        case .cursor:
            return .authCommand(.cursorLogin)
        case .codebuddy:
            return .authCommand(.codebuddyLogin)
        case .gitlab:
            return .authCommand(.gitlabLogin)
        case .kilo:
            return .authCommand(.kiloLogin)
        }
    }
}
