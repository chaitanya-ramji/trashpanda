import Foundation

/// The words of the dialog that asks the user to confirm one delete.
/// It lives in the core, so that tests can check the wording and the default button of each kind.
public struct Confirmation: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Text under the body. When nil, the dialog uses `defaultFooter`.
    public let footer: String?
    /// Text of the confirm button. When nil, it says "Free up <size>".
    public let confirmTitle: String?
    /// When true, the first (default) button keeps the item, so the Return key cannot delete it.
    public let cancelIsDefault: Bool

    public static let defaultFooter =
        "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."

    /// What kind of thing the item is decides how careful the dialog is.
    public enum Kind: Equatable, Sendable {
        case ordinary, container, volume, simulatorRuntime, simulatorDevice, archive, deviceSupport, serviceWorker
    }

    public static func kind(of f: Finding) -> Kind {
        switch f.action {
        case .docker(.removeContainer): return .container
        case .docker(.removeVolume): return .volume
        case .simulator(.deleteRuntime): return .simulatorRuntime
        case .simulator(.deleteDevice): return .simulatorDevice
        case .removeArchive: return .archive
        case .removeDeviceSupport: return .deviceSupport
        case .removeServiceWorkerStorage: return .serviceWorker
        default: return .ordinary
        }
    }

    public static func forOne(_ f: Finding, staleDays: Int, now: Date = Date()) -> Confirmation {
        let detail = "\(f.title)\n\(f.location)"
        switch kind(of: f) {
        case .volume:
            return Confirmation(
                title: "Delete this volume?", body: detail,
                footer: "Databases and files inside a volume are lost for good. If it holds a database, export it first. This can't be undone.",
                confirmTitle: "Delete volume", cancelIsDefault: true)
        case .container:
            return Confirmation(
                title: "Remove this container?", body: "\(detail)\n\(f.rebuild.label).",
                footer: "A container can hold data that is stored nowhere else. This can't be undone.",
                confirmTitle: "Remove", cancelIsDefault: false)
        case .simulatorDevice:
            return Confirmation(
                title: "Delete this simulator?", body: detail,
                footer: "Apps and data inside it are deleted. You can create a new simulator in Xcode. This can't be undone.",
                confirmTitle: "Delete simulator", cancelIsDefault: true)
        case .simulatorRuntime:
            return Confirmation(
                title: "Remove this simulator runtime?", body: detail,
                footer: "Simulators that use it stop working. You can download it again in Xcode Settings. This can't be undone.",
                confirmTitle: "Remove runtime", cancelIsDefault: false)
        case .archive:
            return Confirmation(
                title: "Delete this archive?", body: detail,
                footer: "An archive holds the symbol files (dSYMs) that you need to read crash reports of a build that you shipped. This can't be undone.",
                confirmTitle: "Delete archive", cancelIsDefault: true)
        case .serviceWorker:
            return Confirmation(
                title: "Remove saved website data?", body: detail,
                footer: "Websites that work offline keep their files here. After this, such a site may not open without a network until you visit it online again. This can't be undone.",
                confirmTitle: "Remove data", cancelIsDefault: true)
        case .deviceSupport:
            return Confirmation(
                title: "Remove these device support files?", body: detail,
                footer: "Xcode copies them from the device again the next time you connect it. This can't be undone.",
                confirmTitle: "Remove files", cancelIsDefault: false)
        case .ordinary:
            var text = "\(f.title)\n\(f.rebuild.label)."
            if case .removeArtifact = f.action, f.tier == .review, let d = f.lastActivity {
                let days = max(0, Int(now.timeIntervalSince(d) / 86_400))
                if days < staleDays { text += " You worked on this project \(days == 0 ? "today" : "\(days) days ago")." }
            }
            return Confirmation(title: "Free up \(ByteText.string(f.bytes))?", body: text, footer: nil,
                                confirmTitle: nil, cancelIsDefault: false)
        }
    }
}
