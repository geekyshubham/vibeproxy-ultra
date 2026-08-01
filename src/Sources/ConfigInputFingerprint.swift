import Foundation

enum ConfigInputFingerprint {
    static func relevantFileURLs(
        in directoryURL: URL,
        userConfigFilename: String = "config.yaml",
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []

        let userConfigURL = directoryURL.appendingPathComponent(userConfigFilename)
        if fileManager.fileExists(atPath: userConfigURL.path) {
            urls.append(userConfigURL)
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return urls
        }

        let credentialFiles = files.filter { file in
            let name = file.lastPathComponent
            guard file.pathExtension == "json" else {
                return false
            }
            return name.hasPrefix("zai-") || name.hasPrefix("openai-compat-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        urls.append(contentsOf: credentialFiles)
        return urls
    }

    static func compute(
        in directoryURL: URL,
        userConfigFilename: String = "config.yaml",
        fileManager: FileManager = .default
    ) -> String {
        let urls = relevantFileURLs(
            in: directoryURL,
            userConfigFilename: userConfigFilename,
            fileManager: fileManager
        )

        guard !urls.isEmpty else {
            return ""
        }

        var parts: [String] = []
        parts.reserveCapacity(urls.count * 2)

        for url in urls {
            parts.append(url.lastPathComponent)
            // Cheap fingerprint: size + mtime. Full SHA-256 every second was a CPU hog.
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                parts.append(String(values.fileSize ?? -1))
                // Sub-second precision matters: an edit that keeps the byte count (say
                // `port: 8317` → `port: 8318`) within the same wall-clock second as the
                // previous write is otherwise invisible, and stays invisible, because the
                // fingerprint never changes again until some later write.
                // String(format:) is unlocalized, so the decimal separator is stable.
                parts.append(String(format: "%.6f", (values.contentModificationDate ?? .distantPast).timeIntervalSince1970))
            } else {
                parts.append("<unreadable>")
            }
        }

        return parts.joined(separator: "\n---\n")
    }
}
