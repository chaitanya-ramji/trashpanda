import Foundation

/// How the menu groups the items of the AI agents group. The app draws it. The rules are here, so that tests can check them.
/// An item belongs to the product that its title starts with ("Codex · downloaded runtime").
public enum AgentMenu {
    public struct Group: Sendable {
        public let product: String
        /// The icon plan of the product, or nil for a product that is not in the table.
        public let info: AgentProduct.Info?
        public let items: [Finding]
        /// What the product can free: the actionable items only. An information line has no size in a total.
        public let bytes: Int64
    }

    public static let otherProduct = "Other"

    /// A group of this size is split in one submenu for each product. A flat list is easier to read when it is short,
    /// or when it has one product only.
    public static let nestAbove = 6

    public static func shouldNest(_ items: [Finding]) -> Bool {
        items.count > nestAbove && Set(items.map { AgentProduct.name(ofTitle: $0.title) ?? otherProduct }).count > 1
    }

    /// The products with their items. The product with the most to free comes first. Equal sizes go by name.
    public static func groups(_ items: [Finding]) -> [Group] {
        let byProduct = Dictionary(grouping: items) { AgentProduct.name(ofTitle: $0.title) ?? otherProduct }
        return byProduct.map { product, list in
            Group(product: product, info: AgentProduct.all.first { $0.name == product },
                  items: list.sorted { ($0.bytes, $1.title) > ($1.bytes, $0.title) },
                  bytes: list.filter(\.isActionable).reduce(Int64(0)) { $0 + $1.countedBytes })
        }.sorted { ($0.bytes, $1.product) > ($1.bytes, $0.product) }
    }
}
