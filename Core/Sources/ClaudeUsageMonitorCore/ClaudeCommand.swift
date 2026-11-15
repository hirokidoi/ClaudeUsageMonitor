import Foundation

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

    /// 入力欄の値があれば、実行できるかを確かめずにそれを使う。空なら実行できる最初の候補。
    public static func resolve(configured: String, home: URL, isExecutable: (URL) -> Bool) -> URL? {
        let configured = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configured.isEmpty else { return expand(configured, home: home) }
        return candidates.lazy.map { expand($0, home: home) }.first(where: isExecutable)
    }

    static func expand(_ path: String, home: URL) -> URL {
        guard path.hasPrefix("~/") else { return URL(filePath: path) }
        return home.appending(path: String(path.dropFirst(2)))
    }
}

/// CLAUDE_CONFIG_DIR の入力欄の値と、そこから決まる `.claude.json` の場所。
public enum ClaudeConfigFolder {
    static let cacheFileName = ".claude.json"

    /// 入力欄の値を claude に渡すパスにする。空なら nil。
    public static func customFolderPath(_ input: String, home: URL) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 相対パスは基準にできるフォルダが無いので、解決せずに返して存在しない扱いにする。
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return trimmed }
        // claude のログイン情報はパスの文字列ごとなので、綴りを変えない (末尾の / の有無でも別物になる。実測)。
        var path = ClaudeLocator.expand(trimmed, home: home).path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func cacheFile(customFolder: String?, home: URL) -> URL {
        let base = customFolder.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? home
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
        let folder = executable.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        environment["PATH"] = (folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder) + ":" + systemPath
        if let customFolder { environment["CLAUDE_CONFIG_DIR"] = customFolder }
        return environment
    }
}
