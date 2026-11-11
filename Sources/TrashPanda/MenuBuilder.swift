import AppKit
import PandaCore

/// Makes the items of an `NSMenu` from a `MenuModel`. It makes no decision: every title, order and state comes from the model.
/// When the user chooses a row, the builder passes the row's action to `handler`.
final class MenuBuilder: NSObject {
    /// Holds the action of one row, so that a menu item can carry it.
    private final class ActionBox: NSObject {
        let action: MenuModel.Action
        init(_ action: MenuModel.Action) { self.action = action }
    }

    private let handler: (MenuModel.Action) -> Void
    /// The two rows that stay up to date while the menu is open: the main action and "Scan again".
    private var mainItem: NSMenuItem?
    private var rescanItem: NSMenuItem?
    private static let iconSize = NSSize(width: 16, height: 16)

    init(handler: @escaping (MenuModel.Action) -> Void) {
        self.handler = handler
    }

    /// Fills `menu` with the rows of `model`. `header` is the view of the storage header.
    func populate(_ menu: NSMenu, model: MenuModel, header: NSView) {
        menu.removeAllItems()
        for item in items(model.rows, tab: mainTab(for: model), header: header) { menu.addItem(item) }
        // The group rows have a color dot. The "Smaller groups" row has a blank one, so that the texts line up.
        if model.rows.contains(where: { if case .groupColor = $0.icon { return true } else { return false } }) {
            let blank = NSImage(size: Self.iconSize)
            for (item, row) in zip(menu.items, model.rows) where row.kind == .columns && row.icon == nil { item.image = blank }
        }
        mainItem = menu.items.indices.contains(Self.mainIndex) ? menu.items[Self.mainIndex] : nil
        rescanItem = Self.rescanIndex(in: model).flatMap { menu.items.indices.contains($0) ? menu.items[$0] : nil }
    }

    /// The tab of the main menu: the widest group row (title, the minimum gap, size) decides, within the limits of the model.
    func mainTab(for model: MenuModel) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> Double { Double((text as NSString).size(withAttributes: [.font: font]).width) }
        let widest = model.sharedColumnRows.map { width($0.title) + MenuModel.minTitleGap + width($0.size ?? "") }.max() ?? 0
        return CGFloat(MenuModel.mainTab(widestRow: widest))
    }

    /// The main action is the row after the header and the first separator.
    private static let mainIndex = 2

    private static func rescanIndex(in model: MenuModel) -> Int? {
        model.rows.firstIndex { $0.action == .rescan }
    }

    /// Changes only the title, the second line, the state and the action of the main row and of "Scan again".
    /// The menu is open, so no row is added or removed, and a submenu that the user reads stays open.
    func updateLiveRows(model: MenuModel) {
        if let item = mainItem, model.rows.indices.contains(Self.mainIndex) { applyLive(model.rows[Self.mainIndex], to: item) }
        if let item = rescanItem, let index = Self.rescanIndex(in: model) { applyLive(model.rows[index], to: item) }
    }

    private func applyLive(_ row: MenuModel.Row, to item: NSMenuItem) {
        item.title = row.title
        item.isEnabled = row.enabled
        if #available(macOS 14.4, *) { item.subtitle = row.subtitle }
        if let action = row.action, action != .quit {
            item.action = #selector(fire(_:))
            item.target = self
            item.representedObject = ActionBox(action)
        } else {
            item.action = nil
            item.representedObject = nil
        }
    }

    /// Fills `menu` with the rows of a submenu.
    func populate(_ menu: NSMenu, submenu: MenuModel.Submenu, tab: CGFloat = CGFloat(MenuModel.defaultTab)) {
        let tab = tabLocation(for: submenu, enclosing: tab)
        for item in items(submenu.rows, tab: tab, header: nil) { menu.addItem(item) }
        guard submenu.alignIcons else { return }
        // One column for the text: if any row has an app icon, the other rows get a blank one.
        if menu.items.contains(where: { $0.image != nil }) {
            let blank = NSImage(size: Self.iconSize)
            for item in menu.items where item.image == nil && !item.isSeparatorItem && !Self.isSectionHeader(item) { item.image = blank }
        }
    }

    private static func isSectionHeader(_ item: NSMenuItem) -> Bool {
        if #available(macOS 14, *) { return item.isSectionHeader }
        return false
    }

    /// Where the sizes end. A submenu with a long title widens it, so that the sizes stay in one column.
    private func tabLocation(for submenu: MenuModel.Submenu, enclosing: CGFloat) -> CGFloat {
        guard let titles = submenu.widthTitles else { return enclosing }
        let font = NSFont.menuFont(ofSize: 0)
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return CGFloat(MenuModel.tab(forWidestTitle: Double(widest)))
    }

    private func items(_ rows: [MenuModel.Row], tab: CGFloat, header: NSView?) -> [NSMenuItem] {
        rows.map { item(for: $0, tab: tab, header: header) }
    }

    private func item(for row: MenuModel.Row, tab: CGFloat, header: NSView?) -> NSMenuItem {
        switch row.kind {
        case .separator:
            return .separator()
        case .header:
            let item = NSMenuItem()
            item.view = header
            return item
        case .sectionHeader:
            if #available(macOS 14, *) { return NSMenuItem.sectionHeader(title: row.title) }
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .text, .columns:
            break
        }
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        if row.kind == .columns { item.attributedTitle = line(row.title, row.size ?? "", tab: tab) }
        if let action = row.action {
            if action == .quit {
                // The system handles Quit. It has no target.
                item.action = #selector(NSApplication.terminate(_:))
            } else {
                item.action = #selector(fire(_:))
                item.target = self
                item.representedObject = ActionBox(action)
            }
        }
        if row.isOptionAlternate {
            item.keyEquivalentModifierMask = [.option]
            item.isAlternate = true
        }
        if let checked = row.checked { item.state = checked ? .on : .off }
        if !row.enabled { item.isEnabled = false }
        if let tip = row.tooltip { item.toolTip = tip }
        if let subtitle = row.subtitle {
            if #available(macOS 14.4, *) { item.subtitle = subtitle } else if item.toolTip == nil { item.toolTip = subtitle }
        }
        if let icon = row.icon { item.image = image(for: icon) }
        if let sub = row.submenu {
            let menu = NSMenu()
            populate(menu, submenu: sub, tab: tab)
            item.submenu = menu
        }
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        handler(box.action)
    }

    /// The title, then the size at the tab. A long title loses its middle, so that it never reaches the size.
    private func line(_ left: String, _ right: String, tab: CGFloat) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> Double { Double((text as NSString).size(withAttributes: [.font: font]).width) }
        let room = MenuModel.titleRoom(tab: Double(tab), sizeWidth: width(right))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: "\(MenuText.middleTruncated(left, toFit: room, measure: width))\t\(right)", attributes: [
            .font: font,
            .paragraphStyle: style,
        ])
    }

    // MARK: Icons

    private func image(for icon: MenuModel.Icon) -> NSImage? {
        switch icon {
        case .item(let owner, let agentTitle):
            if let owner, let image = appIcon(owner) { return image }
            guard let agentTitle, let info = AgentProduct.info(forTitle: agentTitle) else { return nil }
            return productImage(info)
        case .groupColor(let slot):
            return GroupColors.dot(slot: slot, side: Self.iconSize.width)
        case .product(let name):
            let info = AgentProduct.all.first { $0.name == name }
            let image = info.flatMap(productImage) ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: name)
            image?.size = Self.iconSize
            return image
        }
    }

    /// The icon of a product: its app when it is installed, and its symbol when it is not.
    private func productImage(_ info: AgentProduct.Info) -> NSImage? {
        let workspace = NSWorkspace.shared
        for id in info.iconBundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                let icon = workspace.icon(forFile: url.path)
                icon.size = Self.iconSize
                return icon
            }
        }
        let symbol = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.name)
        symbol?.size = Self.iconSize
        return symbol
    }

    /// The small icon of the app that owns an item: the running app, or the installed one.
    private func appIcon(_ owner: AppOwner) -> NSImage? {
        let workspace = NSWorkspace.shared
        var icon = workspace.runningApplications.first { app in app.bundleIdentifier.map(owner.matches(bundleID:)) ?? false
            && app.activationPolicy == .regular }?.icon
        if icon == nil {
            for id in owner.bundleIDs where !id.hasSuffix("*") && !id.contains(".helper") {
                if let url = workspace.urlForApplication(withBundleIdentifier: id) { icon = workspace.icon(forFile: url.path); break }
            }
        }
        guard let small = icon?.copy() as? NSImage else { return nil }
        small.size = Self.iconSize
        return small
    }
}
