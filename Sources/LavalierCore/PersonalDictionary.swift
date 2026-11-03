import Foundation

/// One term per line in a plain text file. Not a secret.
public enum PersonalDictionary {
    public static let seedTerms = ["Lavalier", "ElevenLabs", "Claude"]
    public static let maximumTerms = 200
    /// ElevenLabs realtime accepts at most this many keyterms.
    public static let maximumKeyterms = 50

    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let term = rawLine.trimmingCharacters(in: .whitespaces)
            if term.isEmpty || term.hasPrefix("#") { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted {
                out.append(term)
                if out.count >= maximumTerms { break }
            }
        }
        return out
    }

    public static func serialise(_ terms: [String]) -> String {
        terms.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }

    public static func fileURL(in directory: URL = AppPaths.supportDirectory) -> URL {
        directory.appendingPathComponent("dictionary.txt")
    }

    public static func load(from url: URL = fileURL()) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return seedTerms }
        return parse(text)
    }

    public static func save(_ terms: [String], to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialise(terms).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Ensures the file exists so the user can find it; seeds it on first run.
    public static func ensureSeeded(at url: URL = fileURL()) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? save(seedTerms, to: url)
        }
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/Lavalier
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lavalier", isDirectory: true)
    }
}
