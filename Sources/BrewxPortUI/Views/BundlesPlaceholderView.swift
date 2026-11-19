import SwiftUI

struct BundlesPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Bundles", systemImage: "archivebox")
        } description: {
            Text("Bundles arrive in a later version.")
        }
    }
}
