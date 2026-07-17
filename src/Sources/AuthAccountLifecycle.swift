import Foundation

/// Tombstones + multi-file seat deletion so Settings remove/add stay honest.
///
/// Bugs this prevents:
/// 1. Remove deletes one `codex-*.json` while materialize / sibling files resurrect the seat
/// 2. OAuth re-login looks like a "no-op" because the new file is collapsed with an old seat
/// 3. Cockpit auto-materialize fights explicit user deletes
enum AuthAccountLifecycle {
    private static let tombstoneFileName = ".vibeproxy-deleted-seats.json"
    private static let tombstoneKey = "seats"

    // MARK: - Public API

    /// Delete every auth file that belongs to the same provider seat as `account`.
    /// For Codex: all files whose JWT/stored `account_id` matches.
    /// For others: the single file path (email-keyed).
    /// Records a tombstone so background materialize cannot revive the seat.
    @discardableResult
    static func deleteAccountCompletely(
        _ account: AuthAccount,
        authDirectory: URL? = nil
    ) -> (deleted: [URL], failed: [URL]) {
        let dir = authDirectory ?? defaultAuthDirectory()
        let targets = filesToDelete(for: account, in: dir)
        var deleted: [URL] = []
        var failed: [URL] = []

        for url in targets {
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(url)
                NSLog("[AuthLifecycle] Deleted %@", url.lastPathComponent)
            } catch {
                failed.append(url)
                NSLog(
                    "[AuthLifecycle] Failed to delete %@: %@",
                    url.lastPathComponent,
                    error.localizedDescription
                )
            }
        }

        if let seatKey = seatKey(for: account) {
            addTombstone(seatKey, authDirectory: dir)
        }

        return (deleted, failed)
    }

    /// Seat key used for tombstones / multi-file matching. Codex: `codex:<account_id>`.
    static func seatKey(for account: AuthAccount) -> String? {
        if account.type == .codex {
            if let id = codexAccountID(in: account.filePath) {
                return "codex:" + id.lowercased()
            }
            // Filename `codex-seat-{uuid}.json`
            let name = account.filePath.deletingPathExtension().lastPathComponent.lowercased()
            if name.hasPrefix("codex-seat-") {
                let id = String(name.dropFirst("codex-seat-".count))
                if !id.isEmpty { return "codex:" + id }
            }
            return nil
        }
        if let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return "\(account.type.rawValue):email:\(email.lowercased())"
        }
        return "\(account.type.rawValue):file:\(account.id.lowercased())"
    }

    static func isTombstoned(_ seatKey: String, authDirectory: URL? = nil) -> Bool {
        loadTombstones(authDirectory: authDirectory).contains(seatKey.lowercased())
    }

    static func clearTombstone(forAccountID accountID: String, authDirectory: URL? = nil) {
        let key = "codex:" + accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        removeTombstone(key, authDirectory: authDirectory)
    }

    static func clearTombstone(seatKey: String, authDirectory: URL? = nil) {
        removeTombstone(seatKey.lowercased(), authDirectory: authDirectory)
    }

    /// After OAuth, clear tombstones for any codex seats present in `authDirectory`.
    static func clearTombstonesForPresentCodexSeats(authDirectory: URL? = nil) {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard file.lastPathComponent.lowercased().hasPrefix("codex-"),
                  let id = codexAccountID(in: file)
            else { continue }
            clearTombstone(forAccountID: id, authDirectory: dir)
        }
    }

    /// Snapshot of auth files (path + mtime) for detecting post-OAuth writes.
    static func authFileSnapshot(authDirectory: URL? = nil) -> [String: Date] {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var snap: [String: Date] = [:]
        for file in files where file.pathExtension == "json" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            snap[file.lastPathComponent] = mtime
        }
        return snap
    }

    /// Files added or updated after `before`.
    static func authFilesChanged(
        since before: [String: Date],
        authDirectory: URL? = nil
    ) -> [URL] {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var changed: [URL] = []
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let old = before[name] {
                if mtime > old.addingTimeInterval(0.5) {
                    changed.append(file)
                }
            } else {
                changed.append(file)
            }
        }
        return changed.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Matching files

    static func filesToDelete(for account: AuthAccount, in authDirectory: URL) -> [URL] {
        // Always include the visible row's file.
        var urls: [URL] = [account.filePath]

        if account.type == .codex, let accountID = codexAccountID(in: account.filePath) {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: authDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for file in files where file.pathExtension == "json" {
                    let name = file.lastPathComponent.lowercased()
                    guard name.hasPrefix("codex-") else { continue }
                    if let id = codexAccountID(in: file),
                       id.caseInsensitiveCompare(accountID) == .orderedSame
                    {
                        urls.append(file)
                    } else if name == "codex-seat-\(accountID.lowercased()).json" {
                        urls.append(file)
                    }
                }
            }
        }

        // Deduplicate by path.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func codexAccountID(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let access = json["access_token"] as? String,
           let id = CodexWorkspaceCredentials.chatgptAccountID(from: access),
           !id.isEmpty
        {
            return id
        }
        if let id = json["account_id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Tombstones

    static func loadTombstones(authDirectory: URL? = nil) -> Set<String> {
        let url = (authDirectory ?? defaultAuthDirectory()).appendingPathComponent(tombstoneFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seats = json[tombstoneKey] as? [String]
        else { return [] }
        return Set(seats.map { $0.lowercased() })
    }

    private static func addTombstone(_ key: String, authDirectory: URL) {
        var seats = loadTombstones(authDirectory: authDirectory)
        seats.insert(key.lowercased())
        saveTombstones(seats, authDirectory: authDirectory)
    }

    private static func removeTombstone(_ key: String, authDirectory: URL? = nil) {
        let dir = authDirectory ?? defaultAuthDirectory()
        var seats = loadTombstones(authDirectory: dir)
        if seats.remove(key.lowercased()) != nil {
            saveTombstones(seats, authDirectory: dir)
        }
    }

    private static func saveTombstones(_ seats: Set<String>, authDirectory: URL) {
        let url = authDirectory.appendingPathComponent(tombstoneFileName)
        let payload: [String: Any] = [
            tombstoneKey: seats.sorted(),
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func defaultAuthDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    }
}
