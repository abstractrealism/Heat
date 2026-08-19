import Foundation

/// What a fenced code block says it is: a language, and the name of the file
/// when the model gave one.
///
/// MarkdownUI hands the theme the whole fence info string unsplit, so a fence
/// written ```` ```python:parse_logs.py ```` arrives intact. That's the
/// convention the Assistant prompt asks for when a block is a complete file
/// rather than a fragment, and this is where it comes apart: everything before
/// the colon is the language, everything after is the name.
///
/// It has to come apart rather than be used as written, because the same string
/// is also handed to the syntax highlighter as a language name, and Highlightr
/// returns nothing for a language it doesn't know — an unsplit fence would
/// leave the block silently unhighlighted.
///
/// Nothing here depends on the model following the convention. A bare
/// ```` ```python ```` gives a language and no name, and the name is made up
/// from the language at the point of saving.
struct CodeFence {

    /// The language to highlight as, lowercased. Nil for a bare fence.
    let language: String?

    /// The name the model chose, already made safe to write. Nil when the fence
    /// named only a language, which is the ordinary case.
    let filename: String?

    init(fenceInfo: String?) {
        let info = (fenceInfo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !info.isEmpty else {
            self.language = nil
            self.filename = nil
            return
        }

        if let colon = info.firstIndex(of: ":") {
            let language = info[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let name = info[info.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            self.language = language.isEmpty ? nil : language
            self.filename = Self.safeName(name)
        } else if info.contains(".") {
            // A fence naming only a file. The prompt asks for both, but a name
            // is worth keeping when it arrives alone, and no language Highlightr
            // knows has a dot in it. The extension stands in for the language:
            // Highlight.js takes `py`, `js`, `rb`, `yml` and friends as aliases,
            // and an extension it doesn't know simply goes unhighlighted.
            let name = Self.safeName(info)
            let ext = (name.map { $0 as NSString } ?? info as NSString).pathExtension.lowercased()
            self.filename = name
            self.language = ext.isEmpty ? nil : ext
        } else {
            self.language = info.lowercased()
            self.filename = nil
        }
    }

    /// What the block's header reads.
    var displayLabel: String {
        switch (language, filename) {
        case let (language?, name?):
            "\(language.capitalized) · \(name)"
        case let (language?, nil):
            language.capitalized
        case let (nil, name?):
            name
        case (nil, nil):
            ""
        }
    }

    /// The name to save under: the model's, or one built from the language.
    var suggestedFilename: String {
        if let filename {
            return filename
        }
        guard let language else {
            return "snippet.txt"
        }
        if let canonical = Self.canonicalNames[language] {
            return canonical
        }
        if let ext = Self.extensions[language] {
            return "snippet.\(ext)"
        }
        // An unknown language still makes a better extension than `txt` as long
        // as it's shaped like one — `mermaid`, `nix`, `zig`. Anything longer or
        // with punctuation in it would make a worse name than no name.
        if language.count <= 12, language.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "snippet.\(language)"
        }
        return "snippet.txt"
    }

    /// A model-supplied name reduced to something safe to write into a folder
    /// nobody asked us to reorganise.
    ///
    /// This text comes from the model, so it is arbitrary: it may carry a path
    /// (`../../.zshrc`), separators, or a leading dot that would write a hidden
    /// file. Only the last component survives, and a name left as nothing is
    /// discarded rather than guessed at — the caller has a fallback.
    private static func safeName(_ raw: String) -> String? {
        var name = (raw as NSString).lastPathComponent
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        // A separator survives `lastPathComponent` when it's all there is —
        // `/` answers with itself — and can never belong in a name anyway.
        name = name.replacingOccurrences(of: "/", with: "")
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty, name.count <= 200 else { return nil }
        return name
    }

    /// Languages whose file conventionally has a name rather than an extension.
    private static let canonicalNames = [
        "dockerfile": "Dockerfile",
        "makefile": "Makefile",
    ]

    private static let extensions = [
        "applescript": "applescript",
        "bash": "sh",
        "c": "c",
        "c++": "cpp",
        "clojure": "clj",
        "cpp": "cpp",
        "csharp": "cs",
        "css": "css",
        "dart": "dart",
        "diff": "diff",
        "elixir": "ex",
        "erlang": "erl",
        "fish": "fish",
        "go": "go",
        "graphql": "graphql",
        "haskell": "hs",
        "html": "html",
        "ini": "ini",
        "java": "java",
        "javascript": "js",
        "json": "json",
        "jsx": "jsx",
        "kotlin": "kt",
        "latex": "tex",
        "lua": "lua",
        "markdown": "md",
        "objective-c": "m",
        "objectivec": "m",
        "patch": "diff",
        "perl": "pl",
        "php": "php",
        "plaintext": "txt",
        "powershell": "ps1",
        "proto": "proto",
        "python": "py",
        "r": "r",
        "ruby": "rb",
        "rust": "rs",
        "scala": "scala",
        "scss": "scss",
        "shell": "sh",
        "sql": "sql",
        "swift": "swift",
        "text": "txt",
        "toml": "toml",
        "typescript": "ts",
        "tsx": "tsx",
        "vim": "vim",
        "xml": "xml",
        "yaml": "yml",
        "zsh": "sh",
    ]
}

/// Writing a code block out as a file.
enum CodeDownload {

    enum Failure: LocalizedError {
        case noDownloadsFolder
        case tooManyOfTheSameName(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadsFolder:
                "Couldn't find a Downloads folder to save into."
            case .tooManyOfTheSameName(let name):
                "There are already too many files named \(name) in Downloads."
            }
        }
    }

    /// The user's Downloads folder, or nil if there isn't one.
    ///
    /// Deliberately not `FileManager.url(for: .downloadsDirectory, …)`. Inside
    /// the sandbox the standard search paths are rewritten to the app's own
    /// container, so that call answers with a Downloads folder buried in Heat's
    /// container rather than the one in the Dock. The sandbox doesn't rewrite
    /// the password database, so the real home comes from there — which is also
    /// the right answer in an unsandboxed build, where the two agree.
    ///
    /// Reaching it at all depends on `com.apple.security.files.downloads.read-write`
    /// in the entitlements; without that the path resolves and every write is
    /// refused.
    static var downloadsDirectory: URL? {
        guard let passwd = getpwuid(getuid()) else { return nil }
        let home = String(cString: passwd.pointee.pw_dir)
        guard !home.isEmpty else { return nil }

        let downloads = URL(fileURLWithPath: home, isDirectory: true)
            .appending(path: "Downloads", directoryHint: .isDirectory)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: downloads.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? downloads : nil
    }

    /// Writes `text` into Downloads and answers with where it landed.
    ///
    /// `directory` is the folder to write into, defaulting to Downloads. It's a
    /// parameter so the naming and collision behaviour can be exercised
    /// somewhere disposable — and so a chosen folder, should Settings ever offer
    /// one, has somewhere to go.
    @discardableResult
    static func save(_ text: String, as filename: String, in directory: URL? = nil) throws -> URL {
        guard let directory = directory ?? downloadsDirectory else {
            throw Failure.noDownloadsFolder
        }
        let destination = try availableURL(for: filename, in: directory)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// `parse_logs.py`, then `parse_logs 2.py`, and so on — the way a browser
    /// numbers them, so downloading the same block twice never quietly replaces
    /// the first copy.
    private static func availableURL(for filename: String, in directory: URL) throws -> URL {
        let name = filename as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension

        for attempt in 1...999 {
            let candidate = attempt == 1
                ? filename
                : (ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
            let url = directory.appending(path: candidate)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        throw Failure.tooManyOfTheSameName(filename)
    }
}
