import Foundation

/// Small texts of the menu and of the menu bar item, built here so that tests can check each case.
public enum MenuText {
    // MARK: The menu bar item

    /// The button shows the panda and a short number such as "54 GB".
    /// VoiceOver and the tooltip need the full sentence, so that a new user knows what the number means.
    public struct StatusLabel: Equatable, Sendable {
        /// For VoiceOver, for example "Trash Panda, 54 GB free".
        public let accessibility: String
        /// For the mouse pointer, for example "Trash Panda · 54 GB free of 245 GB".
        public let tooltip: String
    }

    public static func statusLabel(free: Int64, total: Int64, activity: MenuModel.Activity) -> StatusLabel {
        let freeText = ByteText.string(free)
        let totalText = ByteText.string(total)
        switch activity {
        case .cleaning:
            return StatusLabel(accessibility: "Trash Panda, cleaning", tooltip: "Trash Panda · cleaning")
        case .scanning:
            return StatusLabel(accessibility: "Trash Panda, scanning, \(freeText) free",
                               tooltip: "Trash Panda · scanning · \(freeText) free of \(totalText)")
        case .idle:
            return StatusLabel(accessibility: "Trash Panda, \(freeText) free",
                               tooltip: "Trash Panda · \(freeText) free of \(totalText)")
        }
    }

    // MARK: The main row

    /// The main row: what it does, and what it leaves alone.
    public struct Primary: Equatable, Sendable {
        public let title: String
        /// Text under the title (or the tooltip on an older system). nil: none.
        public let subtitle: String?
        /// False when there is nothing to choose.
        public let enabled: Bool
    }

    /// `safeCount` and `safeBytes` are the items that "Free up" removes. `reviewBytes` is what stays for the user to review.
    public static func primary(safeCount: Int, safeBytes: Int64, reviewBytes: Int64) -> Primary {
        guard safeCount > 0 else {
            let title = reviewBytes > 0 ? "Nothing to clean now · \(ByteText.string(reviewBytes)) to review" : "Nothing to clean now"
            return Primary(title: title, subtitle: nil, enabled: false)
        }
        let items = safeCount == 1 ? "1 safe item." : "\(safeCount) safe items."
        return Primary(title: "Free up \(ByteText.string(safeBytes))…",
                       subtitle: reviewBytes > 0 ? items + " Review items stay." : items, enabled: true)
    }
}
