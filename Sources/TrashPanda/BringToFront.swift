import AppKit

extension NSApplication {
    /// Brings the app to the front, so that a dialog can be seen. `activate(ignoringOtherApps:)` is deprecated in macOS 14.
    func bringToFront() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
