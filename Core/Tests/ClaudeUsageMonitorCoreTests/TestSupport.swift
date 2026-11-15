import Foundation
@testable import ClaudeUsageMonitorCore

/// 一意の名前の一時フォルダ。`remove()` で消す。
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeUsageMonitorCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }

    func write(_ text: String, as name: String) throws {
        try text.write(to: path(name), atomically: true, encoding: .utf8)
    }

    /// 実行権を付けたシェルスクリプトを置く (偽の claude)。
    @discardableResult
    func script(_ body: String, as name: String = "claude") throws -> URL {
        try write("#!/bin/sh\n" + body + "\n", as: name)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path(name).path(percentEncoded: false))
        return path(name)
    }
}

/// 実物に近い形の `.claude.json`。使わないキーは null で並べる。
func cacheJSON(
    fetchedAtMs: String? = "1790000000000",
    organizationType: String? = "\"claude_max\"",
    fiveHour: String = "null",
    sevenDay: String = "null",
    extraUsage: String = "null",
    includeAccount: Bool = true,
    includeCache: Bool = true
) -> String {
    let account = organizationType.map { "\"organizationType\": \($0)" } ?? "\"displayName\": \"x\""
    let fetched = fetchedAtMs.map { "\"fetchedAtMs\": \($0)," } ?? ""
    return """
    {
      "numStartups": 12,
      \(includeAccount ? "\"oauthAccount\": { \(account) }," : "")
      \(includeCache ? """
      "cachedUsageUtilization": {
        \(fetched)
        "utilization": {
          "five_hour": \(fiveHour),
          "seven_day": \(sevenDay),
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "iguana_necktie": null,
          "extra_usage": \(extraUsage)
        }
      },
      """ : "")
      "theme": "dark"
    }
    """
}

func window(_ utilization: String, resetsAt: String) -> String {
    "{ \"utilization\": \(utilization), \"resets_at\": \(resetsAt) }"
}

func extra(enabled: Bool, utilization: String) -> String {
    "{ \"is_enabled\": \(enabled), \"monthly_limit\": 5000, \"used_credits\": 1234, \"utilization\": \(utilization), \"currency\": \"USD\" }"
}

func jst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    JST.calendar.date(from: DateComponents(
        timeZone: JST.timeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

func milliseconds(_ date: Date, extra: Int64 = 0) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded()) + extra
}

func parsedCache(_ json: String) -> UsageCache {
    guard case let .ok(cache) = UsageCache.parse(Data(json.utf8)) else { fatalError("fixture did not parse") }
    return cache
}
