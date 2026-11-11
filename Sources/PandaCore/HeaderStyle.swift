import Foundation

/// The system settings that change how the header is drawn. The app reads them from the system. The core only decides.
public struct HeaderSettings: Equatable, Sendable {
    public var reduceMotion = false
    public var increaseContrast = false
    public var reduceTransparency = false
    public var differentiateWithoutColor = false
    public var darkMode = false

    public init(reduceMotion: Bool = false, increaseContrast: Bool = false, reduceTransparency: Bool = false,
                differentiateWithoutColor: Bool = false, darkMode: Bool = false) {
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.differentiateWithoutColor = differentiateWithoutColor
        self.darkMode = darkMode
    }
}

/// How the header is drawn for some settings. The drawing code only reads these values.
public struct HeaderStyle: Equatable, Sendable {
    /// Alpha of the light fill under the stripes of a blocked part.
    public let stripeFillAlpha: CGFloat
    /// Alpha of the stripe lines.
    public let stripeLineAlpha: CGFloat
    /// Alpha of the review share of a part. In light mode it is lower than 1, so the review share is paler than the safe share.
    public let reviewFillAlpha: CGFloat
    /// How much white is mixed into the color of the review share (0 to 1). In dark mode a lower alpha only makes a darker color,
    /// so the review share is lighter by mixing in white.
    public let reviewWhiteMix: CGFloat
    /// A 1 point line between two parts.
    public let separatorsBetweenParts: Bool
    /// The review share of a part has a line pattern, not only a lighter color.
    public let patternForReview: Bool
    /// The parts that are not under the mouse get lighter.
    public let dimOtherParts: Bool
    /// The part under the mouse gets a line around it. It replaces the dimming when transparency is reduced.
    public let outlineHoveredPart: Bool
    /// With "Reduce motion" the spinner does not show. The text still says that the app is busy.
    public let showSpinner: Bool

    /// The skeleton: the alpha of the grey track and pills (of the label color), and of the white shimmer band.
    public let skeletonAlpha: CGFloat
    public let shimmerAlpha: CGFloat
    /// The shimmer moves only when motion is allowed. With "Reduce motion" the skeleton is still.
    public let animateSkeleton: Bool

    public init(_ settings: HeaderSettings) {
        skeletonAlpha = settings.increaseContrast ? 0.20 : (settings.darkMode ? 0.14 : 0.09)
        shimmerAlpha = settings.darkMode ? 0.10 : 0.65
        animateSkeleton = !settings.reduceMotion
        // "Increase contrast" gives 0.6. In dark mode the light fill needs a little more to be seen.
        stripeFillAlpha = settings.increaseContrast ? 0.6 : (settings.darkMode ? 0.40 : 0.30)
        stripeLineAlpha = settings.increaseContrast ? 1 : 0.85
        reviewFillAlpha = settings.darkMode ? 1 : 0.50
        reviewWhiteMix = settings.darkMode ? 0.45 : 0
        separatorsBetweenParts = settings.increaseContrast
        // "Increase contrast" asks for a clearer difference, so the review share gets the line pattern too.
        patternForReview = settings.differentiateWithoutColor || settings.increaseContrast
        dimOtherParts = !settings.reduceTransparency
        outlineHoveredPart = settings.reduceTransparency
        showSpinner = !settings.reduceMotion
    }
}

/// The rows of the header, from the bottom of the view. The numbers are points. The view is not flipped.
public struct HeaderLayout: Equatable, Sendable {
    public let height: CGFloat
    public let titleY: CGFloat
    public let detailY: CGFloat
    /// The bottom of the bar. nil when there is no bar.
    public let barY: CGFloat?
    /// The bottom of the legend. nil when there is no bar.
    public let legendY: CGFloat?
}

/// The widths of the three kinds of data in one part of the bar, from the left: safe, review, blocked.
public struct PartWidths: Equatable, Sendable {
    public let safe: CGFloat
    public let review: CGFloat
    public let blocked: CGFloat
}

extension SplitBar {
    /// Places the rows of the header from the heights of the three fonts (title, detail line, legend).
    /// With a bar, the legend is at the bottom, then the bar, then the detail line, then the title.
    public static func headerLayout(titleHeight: CGFloat, detailHeight: CGFloat, legendHeight: CGFloat, barHeight: CGFloat,
                                    hasBar: Bool, topPadding: CGFloat = 10, bottomPadding: CGFloat = 10,
                                    rowGap: CGFloat = 2, barGap: CGFloat = 8, legendGap: CGFloat = 6) -> HeaderLayout {
        var y = hasBar ? bottomPadding : 8
        var legendY: CGFloat?, barY: CGFloat?
        if hasBar {
            legendY = y
            y += legendHeight + legendGap
            barY = y
            y += barHeight + barGap
        }
        let detailY = y
        let titleY = detailY + detailHeight + rowGap
        return HeaderLayout(height: titleY + titleHeight + topPadding, titleY: titleY, detailY: detailY, barY: barY, legendY: legendY)
    }

    /// Splits the width of one part into safe, review and blocked. The blocked width is at the end. The three add up to `width`,
    /// and none is below zero. The widths are not rounded: a part has a fractional width, and a rounded share could be wider than the part.
    public static func partWidths(_ segment: SplitSegment, width: CGFloat) -> PartWidths {
        guard segment.bytes > 0, width > 0 else { return PartWidths(safe: max(0, width), review: 0, blocked: 0) }
        let total = CGFloat(segment.bytes)
        let blocked = min(width, width * CGFloat(min(segment.blockedBytes, segment.bytes)) / total)
        let reviewBytes = max(0, segment.bytes - segment.blockedBytes - segment.safeBytes)
        let review = max(0, min(width - blocked, width * CGFloat(reviewBytes) / total))
        return PartWidths(safe: max(0, width - blocked - review), review: review, blocked: blocked)
    }

    /// How many legend entries fit. `entryWidths` are the widths of the entries in order, each with the `separator` that follows it
    /// (the last entry needs no separator). `moreWidth(k)` is the width of the text "+k more". The entries that are shown, and the
    /// text "+k more" for the others, must fit in `room`. The text "+k more" is never left out when some entries are not shown.
    /// The result can be 0 when the first entry does not fit together with the text "+k more".
    public static func legendCount(entryWidths: [CGFloat], separator: CGFloat = 0, moreWidth: (Int) -> CGFloat, room: CGFloat) -> Int {
        var best = 0
        var used: CGFloat = 0
        for (i, w) in entryWidths.enumerated() {
            used += w
            let left = entryWidths.count - (i + 1)
            let needed = left > 0 ? used + moreWidth(left) : used - separator
            if needed <= room { best = i + 1 }
        }
        return best
    }

    /// How much of its alpha a part keeps while the mouse is on another part.
    public static let hoverDimFactor: CGFloat = 0.30

    /// The final alpha of a fill of a part that is not under the mouse. It never goes below a floor, so a pale part stays visible.
    /// Give the alpha that the fill would have after the hover factor, not before.
    public static func dimmedAlpha(_ final: CGFloat) -> CGFloat { max(0.22, final) }
}
