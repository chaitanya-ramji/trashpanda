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

    /// What the user needs to know after a clean: open apps, the Docker note, and failures.
    static func showReport(_ report: CleanReport) {
        if !report.blockedApps.isEmpty {
            let alert = NSAlert()
            let names = report.blockedApps.joined(separator: " and ")
            alert.messageText = "Quit \(names) first"
            alert.informativeText = "Some items belong to \(names), and it is open. Trash Panda left them alone. Quit it and clean again."
            NSApp.bringToFront()
            alert.runModal()
        }
        if let note = report.dockerNote {
            let alert = NSAlert()
            alert.messageText = note
            alert.informativeText = "Docker keeps its data in one disk file, and the file can give the space back slowly."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Read the steps")
            NSApp.bringToFront()
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(DockerDesktopDisk.helpURL) }
        }
        if !report.failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "A few things couldn't be cleaned"
            alert.informativeText = "They may be in use. Close your editor or Docker and try again. Details are in the log."
            NSApp.bringToFront()
            alert.runModal()
        }
    }
}
