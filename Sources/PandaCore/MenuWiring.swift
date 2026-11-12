import Foundation

/// The decisions of the open-menu wiring, without AppKit. The app delegate sends an event and runs the actions that come back.
/// It knows when the menu builds, when it only updates a few rows, when a change waits for the close, and when the spinner turns.
public struct MenuWiring: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Build the menu with a new header view. `headerIsOpen` is what `isMenuOpen` of that header must be at that moment.
        case buildMenu(MenuModel, headerIsOpen: Bool)
        /// The menu shows this model already: build nothing.
        case skipEqualModel
        /// The menu is open: update the header, and the live rows of the model. The full build waits for the close.
        case updateLiveRows(MenuModel, HeaderContent)
        /// Tell the header of the menu whether the menu is open. Its animation timer runs only while it is.
        case setHeaderOpen(Bool)
        /// The status item starts to turn.
        case startSpinner
        /// The status item stops turning.
        case stopSpinner
    }

    private var gate = MenuRefreshGate()
    /// True between `openingBegan` and `openingFinished`: the open builds the menu once, so a change in it builds nothing.
    public private(set) var isOpening = false
    /// What the header of the last build shows.
    public private(set) var builtContent = HeaderContent.make(activity: .scanning, hasResult: false, hasParts: false)
    /// The model that the menu shows. nil when it may no longer show one.
    public private(set) var builtModel: MenuModel?
    public private(set) var spinnerRuns = false

    public var isOpen: Bool { gate.isOpen }
    /// A change came while the menu is open: it is built at the close.
    public var rebuildWaits: Bool { gate.needsRebuild }

    public init() {}

    // MARK: Events

    /// `menuWillOpen` starts. A scan that it starts must not build the menu.
    public mutating func openingBegan() { isOpening = true }

    /// `menuWillOpen` has done its work. `model` is the model now.
    public mutating func openingFinished(model: MenuModel) -> [Action] {
        isOpening = false
        let build = rebuild(model)
        gate.opened()
        return [build, .setHeaderOpen(true)]
    }

    /// `menuDidClose`. The header stops its timer, and a change that waited builds now.
    public mutating func menuClosed(model: @autoclosure () -> MenuModel) -> [Action] {
        var actions: [Action] = [.setHeaderOpen(false)]
        if gate.closed() { actions.append(rebuild(model())) }
        return actions
    }

    /// The state changed (a scan or a clean moved, a result came, an app opened or quit, an update was found).
    public mutating func modelChanged(_ model: @autoclosure () -> MenuModel) -> [Action] {
        if isOpening { return [] }
        switch gate.changed() {
        case .rebuild:
            return [rebuild(model())]
        case .updateLiveRows:
            let model = model()
            switch HeaderContent.liveUpdate(built: builtContent, now: model.header.content) {
            case .rebuildMenu:
                return [rebuild(model)]
            case .detailOnly(let content):
                builtModel = nil   // the open menu no longer shows the last build
                return [.updateLiveRows(model, content)]
            }
        }
    }

    /// A scan or a clean started or ended: `activity` is what runs now. Run the actions, then send `modelChanged`.
    public mutating func activityChanged(_ activity: MenuModel.Activity) -> [Action] {
        if activity == .idle {
            spinnerRuns = false
            return [.stopSpinner]
        }
        if !spinnerRuns {
            spinnerRuns = true
            return [.startSpinner]
        }
        return []
    }

    private mutating func rebuild(_ model: MenuModel) -> Action {
        if model == builtModel { return .skipEqualModel }
        builtModel = model
        builtContent = model.header.content
        return .buildMenu(model, headerIsOpen: gate.isOpen)
    }
}
