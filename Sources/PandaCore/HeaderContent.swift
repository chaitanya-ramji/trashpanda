import Foundation

/// What the header shows in each state. The view only draws it. The header has the same height in every state:
/// the title, the detail line, the bar area and the legend row are always there, so the menu never jumps.
public struct HeaderContent: Equatable, Sendable {
    public enum Bar: Equatable, Sendable {
        /// The real parts of the bar, and the legend under them.
        case parts
        /// No result yet: a grey track with a slow shimmer, and three grey pills for the legend. No numbers.
        case skeleton
        /// A result without any data to clean: a quiet empty track, and no legend.
        case emptyTrack
    }

    public let bar: Bar
    /// The text of the line under the title. nil means the summary of the totals ("You can free 1.5 GB now ...").
    public let detail: String?
    /// How strong the fills of the bar are drawn (the legend dots stay as they are). It is lower while the data is old and is being
    /// checked again. Dark mode uses `HeaderStyle.refreshingAlpha` instead, because 0.6 is muddy on a dark menu.
    public let barAlpha: CGFloat
    /// True while the app scans or cleans. The header shows its spinner then.
    public let busy: Bool
    /// False while the app cleans: the parts of the bar cannot be chosen then, because their clean actions would be refused.
    public let isInteractive: Bool

    /// The alpha of the old bar while it is being refreshed.
    public static let refreshingAlpha: CGFloat = 0.6
    /// The widths of the three grey pills of the legend row, in points.
    public static let pillWidths: [CGFloat] = [58, 74, 46]

    public var showsSkeleton: Bool { bar == .skeleton }

    /// The old data is on screen while the app checks it again or cleans.
    public var isRefreshing: Bool { barAlpha < 1 }

    /// A finished scan with nothing to clean: the header shows a calm "done" look.
    public var isDone: Bool { bar == .emptyTrack && !busy }

    /// What the header does when the state changes while the menu is open.
    public enum LiveUpdate: Equatable, Sendable {
        /// Only the detail line, the spinner and the strength of the bar change. The parts, the numbers and the colors stay,
        /// like the group rows below them.
        case detailOnly(HeaderContent)
        /// The menu still shows the skeleton and "Scanning…" rows, and the first result is here: build the whole menu.
        case rebuildMenu
    }

    /// `built` is what the open menu shows. `now` is what the model says now.
    public static func liveUpdate(built: HeaderContent, now: HeaderContent) -> LiveUpdate {
        if built.showsSkeleton && !now.showsSkeleton { return .rebuildMenu }
        return .detailOnly(now.keepingBar(of: built))
    }

    /// The same content with the kind of bar of `other`.
    public func keepingBar(of other: HeaderContent) -> HeaderContent {
        showsSkeleton || other.showsSkeleton ? self : HeaderContent(bar: other.bar, detail: detail, barAlpha: barAlpha, busy: busy, isInteractive: isInteractive)
    }

    /// - Parameters:
    ///   - activity: what the app does now.
    ///   - hasResult: a scan has finished since the launch. Then the old numbers can stay on screen.
    ///   - hasParts: the bar has at least one part.
    ///   - progress: the text of the clean job, when there is one.
    public static func make(activity: MenuModel.Activity, hasResult: Bool, hasParts: Bool, progress: String? = nil) -> HeaderContent {
        let real: Bar = hasParts ? .parts : .emptyTrack
        switch activity {
        case .idle:
            return HeaderContent(bar: real, detail: nil, barAlpha: 1, busy: false, isInteractive: true)
        case .scanning:
            if !hasResult {
                return HeaderContent(bar: .skeleton, detail: "Looking for things to clean…", barAlpha: 1, busy: true, isInteractive: true)
            }
            return HeaderContent(bar: real, detail: "Checking again…", barAlpha: refreshingAlpha, busy: true, isInteractive: true)
        case .cleaning:
            let text = progress.flatMap { $0.isEmpty ? nil : $0 } ?? "Cleaning up…"
            return HeaderContent(bar: real, detail: text, barAlpha: refreshingAlpha, busy: true, isInteractive: false)
        }
    }

    /// Where the shimmer is, from 0 (before the left end) to 1 (past the right end). It repeats every `period` seconds.
    public static func shimmerPhase(at time: TimeInterval, period: TimeInterval = 1.8) -> Double {
        guard period > 0 else { return 0 }
        let t = time.truncatingRemainder(dividingBy: period)
        return (t < 0 ? t + period : t) / period
    }
}
