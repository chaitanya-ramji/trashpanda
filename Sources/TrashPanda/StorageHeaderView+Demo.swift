import AppKit

extension StorageHeaderView {
    /// For demo mode: act as if the mouse were over, or had clicked, a part.
    func simulateHover(_ index: Int?) { setHovered(index) }
    func simulateClick(_ index: Int) { choose(index) }
}
