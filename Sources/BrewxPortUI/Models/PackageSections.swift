import BrewxPortCore

/// One engine's rows within a page, in the order they arrived.
public struct PackageSection<Row: Identifiable>: Identifiable {
    public let engine: EngineID
    public let rows: [Row]
    public var id: EngineID { engine }

    public init(engine: EngineID, rows: [Row]) {
        self.engine = engine
        self.rows = rows
    }
}

extension PackageSection: Sendable where Row: Sendable {}

/// Splits a page's ordered rows into one section per package manager.
public enum PackageSections {
    /// Sections follow `order`; engines missing from `order` come last, in the order
    /// their first row appears. Rows keep their relative order and empty sections are dropped.
    public static func make<Row>(
        _ rows: [Row], engine: (Row) -> EngineID, order: [EngineID]
    ) -> [PackageSection<Row>] {
        var grouped: [EngineID: [Row]] = [:]
        var firstSeen: [EngineID] = []
        for row in rows {
            let id = engine(row)
            if grouped[id] == nil { firstSeen.append(id) }
            grouped[id, default: []].append(row)
        }
        var seen = Set<EngineID>()
        let ranked = (order + firstSeen).filter { seen.insert($0).inserted }
        return ranked.compactMap { id in
            grouped[id].map { PackageSection(engine: id, rows: $0) }
        }
    }
}
