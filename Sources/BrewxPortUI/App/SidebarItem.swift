import BrewxPortCore

/// One row in the sidebar.
public enum SidebarItem: Hashable, Sendable {
    case discover, updates, installed, bundles, engine(EngineID), helper
}

/// One section of engine rows in the sidebar: the system package managers ("Engines"), then the language ones
/// ("Languages").
public struct SidebarEngineGroup: Hashable, Sendable, Identifiable {
    public let group: EngineGroup
    public let engines: [EngineID]

    public var id: EngineGroup { group }
    public var title: String { group.title }

    /// `order` split by group, each keeping `order`'s sequence, in `EngineGroup` order. Empty groups are left out.
    public static func make(order: [EngineID]) -> [SidebarEngineGroup] {
        EngineGroup.allCases.compactMap { group in
            let engines = order.filter { $0.group == group }
            return engines.isEmpty ? nil : SidebarEngineGroup(group: group, engines: engines)
        }
    }
}
