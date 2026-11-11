import AppKit
import PandaCore

/// Carries findings from a menu row to the dialog that asks about them.
final class FindingBox: NSObject {
    let findings: [Finding]
    let title: String
    let body: String
    /// Text under the body. When nil, the dialog says that tools rebuild what they need.
    let footer: String?
    /// Text of the confirm button. When nil, it says "Free up <size>".
    let confirmTitle: String?
    /// When true, the first (default) button keeps the item. The Return key then cannot delete it.
    let cancelIsDefault: Bool
    /// Text of the button that keeps things as they are, when it is first. When nil, it says "Keep it".
    let cancelTitle: String?
    init(_ findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil,
         cancelIsDefault: Bool = false, cancelTitle: String? = nil) {
        self.cancelTitle = cancelTitle
        self.findings = findings
        self.title = title
        self.body = body
        self.footer = footer
        self.confirmTitle = confirmTitle
        self.cancelIsDefault = cancelIsDefault
    }

    /// The box for the dialog that a menu row describes.
    convenience init(_ prompt: MenuModel.Prompt) {
        self.init(prompt.findings, title: prompt.title, body: prompt.body, footer: prompt.footer,
                  confirmTitle: prompt.confirmTitle, cancelIsDefault: prompt.cancelIsDefault, cancelTitle: prompt.cancelTitle)
    }
}

/// The dialogs of the app. Each one blocks until the user answers.
enum Dialogs {
    /// One short dialog. It says what happens and that it cannot be undone. Nothing more.
    /// `confirmed` is the button response that means "yes, delete". It is not always the first button.
    static func makeAlert(for box: FindingBox) -> (alert: NSAlert, confirmed: NSApplication.ModalResponse) {
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }
        let alert = NSAlert()
        // A dialog where Cancel is the default is for a delete that loses data. It gets the critical style.
        alert.alertStyle = box.cancelIsDefault ? .critical : .informational
        alert.messageText = box.title
        let footer = box.footer
            ?? "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."
        alert.informativeText = box.body + "\n\n" + footer
        let confirmTitle = box.confirmTitle ?? "Free up \(Format.bytes(total))"
        if box.cancelIsDefault {
            // "Keep it" is first, so it is the default button. The Return key keeps the item.
            alert.addButton(withTitle: box.cancelTitle ?? "Keep it")
            alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
            return (alert, .alertSecondButtonReturn)
        }
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Not now")
        return (alert, .alertFirstButtonReturn)
    }

    /// Asks the user. Returns true when the user chose the button that means "yes, delete".
    static func confirm(_ box: FindingBox) -> Bool {
        let (alert, confirmed) = makeAlert(for: box)
        NSApp.bringToFront()
        return alert.runModal() == confirmed
    }

    /// The owner app did not quit. Nothing was removed.
    static func showStillOpen(_ names: [String]) {
        let alert = NSAlert()
        let list = names.joined(separator: " and ")
        alert.messageText = "\(list) is still open"
        alert.informativeText = "It may be asking you to save. Finish that, or quit it yourself, then clean again. Nothing was removed."
        NSApp.bringToFront()
        alert.runModal()
    }

    /// The one dialog after a clean. It is not shown when nothing was left alone and nothing failed.
    /// The words come from `CleanSummary`, where tests check them.
    static func showReport(_ report: CleanReport) {
        let dockerNote = report.dockerNote != nil
        guard CleanSummary.needsDialog(report, dockerDiskNote: dockerNote) else { return }
        let summary = CleanSummary.make(report, dockerDiskNote: dockerNote)
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.lines.joined(separator: "\n\n")
        for button in summary.buttons { alert.addButton(withTitle: button.title) }
        NSApp.bringToFront()
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard summary.buttons.indices.contains(index) else { return }
        switch summary.buttons[index] {
        case .ok: break
        case .showLog: NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        case .dockerDiskFile: NSWorkspace.shared.open(DockerDesktopDisk.helpURL)
        }
    }
}
