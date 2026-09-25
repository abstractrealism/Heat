import SwiftUI
import SharedKit
import GenKit
import HeatKit

struct PreferencesView: View {
    @Environment(AppState.self) var state

    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            // Padded per tab rather than around the lot, because the Services
            // pane scrolls and wants to run to the bottom edge: a scroll view
            // stopping a margin short of the window cuts its content mid-row
            // above a blank strip, which reads as clipping rather than as a
            // margin. The other tabs keep the margin on every side.
            TabView(selection: $selectedTab) {
                Tab("General", systemImage: "person.text.rectangle", value: 0) {
                    GeneralView()
                        .frame(maxWidth: 600, alignment: .center)
                        .scenePadding()
                }

                Tab("Permissions", systemImage: "key.2.on.ring", value: 1) {
                    PermissionsView()
                        .scenePadding()
                }

                Tab("Services", systemImage: "hand.palm.facing", value: 2) {
                    ServicesView()
                        .scenePadding([.horizontal, .top])
                }

                Tab("Instructions", systemImage: "helm", value: 3) {
                    InstructionsView()
                        .scenePadding()
                }

                Tab("Tools", systemImage: "ellipsis.curlybraces", value: 4) {
                    ToolsView()
                        .scenePadding([.horizontal, .top])
                }
            }
        }
        // Grows into whatever the window is given. The floor and the starting
        // size are set on the Settings scene, so nothing here fixes a height
        // that would stop the window being dragged taller.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
    }
}
