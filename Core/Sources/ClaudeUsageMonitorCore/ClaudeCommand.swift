import Foundation

/// CLI のパスと CLAUDE_CONFIG_DIR の入力欄に共通の絶対パス化。
enum PathInput {
    /// 前後の空白は呼ぶ側で除いてから渡す。
    static func absolutePath(_ input: String, home: URL) -> String? {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if input.hasPrefix("~/") { return ClaudeLocator.expand(input, home: home).path(percentEncoded: false) }
        return input.hasPrefix("/") ? input : nil
    }
}

/// claude の実行ファイルを決める。GUI アプリはシェルの PATH を引き継がないので、よくあるインストール先を順に見る。
public enum ClaudeLocator {
    /// `~/` はホームからの相対。
    public static let candidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "~/.npm-global/bin/claude",
        "~/.volta/bin/claude",
        "~/.bun/bin/claude"
    ]

    public enum Resolution: Equatable, Sendable {
        case found(URL)
        /// 入力が空で、よくあるインストール先に無い。
        case notFound
        /// 入力があるが使えないパス。
        case invalid

        public var url: URL? {
            if case let .found(url) = self { return url }
            return nil
        }
    }

    /// 入力欄の値が有効ならそれを、実行できるかを確かめずに使う。空なら実行できる最初の候補。
    public static func resolve(configured: String, home: URL, isExecutable: (URL) -> Bool) -> Resolution {
        let configured = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else {
            return candidates.lazy.map { expand($0, home: home) }.first(where: isExecutable).map(Resolution.found) ?? .notFound
        }
        return PathInput.absolutePath(configured, home: home).map { .found(URL(filePath: $0)) } ?? .invalid
    }

    static func expand(_ path: String, home: URL) -> URL {
        guard path.hasPrefix("~/") else { return URL(filePath: path) }
        return home.appending(path: String(path.dropFirst(2)))
    }
}

/// CLAUDE_CONFIG_DIR の入力欄の値と、そこから決まる `.claude.json` の場所。
public enum ClaudeConfigFolder {
    static let cacheFileName = ".claude.json"

    public enum Input: Equatable, Sendable {
        /// 空。claude には渡さない。
        case none
        /// 入力 (空白を除いた文字列) が使えないパス。
        case invalid(String)
        case folder(String)

        public var folderPath: String? {
            if case let .folder(path) = self { return path }
            return nil
        }
    }

    /// 入力欄の値を claude に渡すパスにする。
    public static func resolve(_ input: String, home: URL) -> Input {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        // 末尾の / だけ除く。claude のログイン情報はパスの文字列ごと (実測)。
        guard var path = PathInput.absolutePath(trimmed, home: home) else { return .invalid(trimmed) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return .folder(path)
    }

    public static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func cacheFile(for input: Input, home: URL) -> URL? {
        let base: URL
        switch input {
        case .none: base = home
        case .invalid: return nil
        case let .folder(path): base = URL(filePath: path, directoryHint: .isDirectory)
        }
        return base.appending(path: cacheFileName, directoryHint: .notDirectory)
    }
}

public struct ClaudeInvocation: Sendable, Hashable {
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG"]
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// 利用統計の送信を止める。`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` は使用量の取得まで止まるので使わない (実測)。
    static let fixedVariables = ["DISABLE_TELEMETRY": "1"]
    /// 作業フォルダの要らない呼び出し用。必ず存在する。
    static let neutralDirectory = URL(filePath: "/", directoryHint: .isDirectory)
    /// 取得 1 回の費用の保険 (設計値)。
    static let usageBudgetUSD = "0.01"

    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: URL

    /// 使用量の取得。`/usage` は CLI 内のコマンドでモデルを呼ばない (実測)。
    public static func usage(executable: URL, customFolder: String?, inheriting: [String: String]) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: [
                "-p", "/usage",
                "--no-session-persistence",
                "--safe-mode",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--no-chrome",
                "--tools", "",
                "--max-budget-usd", usageBudgetUSD
            ],
            environment: environment(executable: executable, customFolder: customFolder, inheriting: inheriting),
            directory: neutralDirectory
        )
    }

    /// 接続テスト。`auth status` はログイン切れを見分けられないので、最も安いモデルを 1 回呼ぶ。
    public static func probe(executable: URL, customFolder: String?, inheriting: [String: String]) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: [
                "-p", "Hi!",
                "--safe-mode",
                "--setting-sources", "",
                "--tools", "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--model", "haiku",
                "--effort", "low",
                "--output-format", "json"
            ],
            environment: environment(executable: executable, customFolder: customFolder, inheriting: inheriting),
            directory: neutralDirectory
        )
    }

    /// 設定フォルダは渡さない。
    public static func version(executable: URL, inheriting: [String: String]) -> ClaudeInvocation {
        ClaudeInvocation(
            executable: executable,
            arguments: ["--version"],
            environment: environment(executable: executable, customFolder: nil, inheriting: inheriting),
            directory: neutralDirectory
        )
    }

    // アプリの環境をまるごと渡すと、起動元の CLAUDE* の変数や API キーが混ざる。
    private static func environment(executable: URL, customFolder: String?, inheriting: [String: String]) -> [String: String] {
        var environment = inheriting.filter { inheritedVariables.contains($0.key) }.merging(fixedVariables) { _, fixed in fixed }
        let folder = executable.deletingLastPathComponent().path(percentEncoded: false)
        environment["PATH"] = (folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder) + ":" + systemPath
        if let customFolder { environment["CLAUDE_CONFIG_DIR"] = customFolder }
        return environment
    }
}
