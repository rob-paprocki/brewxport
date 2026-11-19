import BrewxPortCore

/// One row in the sidebar.
public enum SidebarItem: Hashable, Sendable {
    case discover, updates, installed, bundles, engine(EngineID)
}
