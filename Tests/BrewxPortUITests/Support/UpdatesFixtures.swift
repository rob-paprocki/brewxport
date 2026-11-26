import Foundation
import BrewxPortCore
@testable import BrewxPortUI

extension AppFixtures {
    /// A model whose Updates page holds `packages` (each outdated), loaded and settled. The packages are scripted on
    /// `catalog`; `services` must be built on that same catalog (default: demo-mode services with `executor`).
    static func updatesModel(_ packages: [Package], executor: FakeRunExecutor = FakeRunExecutor(),
                             catalog: FakeCatalog = FakeCatalog(), services: Services? = nil)
        async -> BrewxPortAppModel {
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.outdated, engine, packages: found)
        }
        let m = BrewxPortAppModel(services: services ?? Self.services(catalog: catalog, executor: executor, isDemo: true))
        m.refreshLists()
        _ = await waitUntil {
            !m.updates.list.loading && !m.updates.pruning && m.updates.list.all.count == packages.count
        }
        return m
    }
}
