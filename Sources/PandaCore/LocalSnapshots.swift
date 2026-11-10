import Foundation

/// Time Machine keeps local snapshots on the internal disk. After you delete files, the free space can stay the same,
/// because a snapshot still holds them. macOS removes the snapshots by itself when the disk needs the space.
///
/// We only list them (`tmutil listlocalsnapshots /`, read only) and tell the user in one sentence. We never delete or thin a snapshot.
/// A source test forbids the commands that would.
public enum LocalSnapshots {
    public static let tmutilPath = "/usr/bin/tmutil"
    /// Apple has no page that we could confirm for this, so the link is a search of Apple Support.
    public static let helpURL = URL(string: "https://support.apple.com/en-us/search?q=Time%20Machine%20local%20snapshots")!

    public struct Info: Equatable, Sendable {
        public let count: Int
        /// Days since the oldest snapshot, or nil when the dates could not be read.
        public let oldestDays: Int?
    }

    private static let line = try! NSRegularExpression(pattern: #"com\.apple\.TimeMachine\.(\d{4}-\d{2}-\d{2}-\d{6})(\.local)?"#)

    /// Reads the output of `tmutil listlocalsnapshots /`. A line that is not a snapshot is ignored.
    static func parse(_ output: String, now: Date) -> Info? {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        var dates: [Date?] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let text = String(raw).trimmingCharacters(in: .whitespaces)
            let range = NSRange(text.startIndex..., in: text)
            guard let m = line.firstMatch(in: text, range: range), m.range.location == 0, let r = Range(m.range(at: 1), in: text) else { continue }
            dates.append(stamp.date(from: String(text[r])))
        }
        guard !dates.isEmpty else { return nil }
        let oldest = dates.compactMap { $0 }.min()
        return Info(count: dates.count, oldestDays: oldest.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) })
    }

    /// The local snapshots of the startup volume, or nil when there are none or `tmutil` did not answer.
    public static func read(tool: String = tmutilPath, now: Date = Date()) -> Info? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let r = Shell.run(tool, ["listlocalsnapshots", "/"], timeout: 15, quiet: true)
        guard r.status == 0, !r.timedOut else { return nil }
        return parse(r.stdout, now: now)
    }
}
