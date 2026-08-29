import Foundation

/// Credentials for the CLIProxyAPI Management UI (`/management.html`).
///
/// CLIProxyAPI disables all `/v0/management/*` routes when `remote-management.secret-key`
/// is empty (HTTP 404: "Management API not found").
enum ManagementCredentials {
    /// The globally-known default key shipped in this (public) repo. A network-
    /// exposed management API must never be protected by only this value.
    static let defaultSecretKey = "viberouter-admin"

    /// Default management key injected into merged-config.yaml.
    /// Enter this in the management.html login field (Authorization: Bearer …).
    static let secretKey = defaultSecretKey

    /// Backend that serves management.html and /v0/management/* (CLIProxyAPI process).
    static let backendPort = 8318

    static var managementHTMLURL: URL {
        URL(string: "http://127.0.0.1:\(backendPort)/management.html")!
    }

    static var backendBaseURL: String {
        "http://127.0.0.1:\(backendPort)"
    }
}
