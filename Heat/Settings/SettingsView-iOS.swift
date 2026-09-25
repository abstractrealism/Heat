import SwiftUI
import SharedKit
import GenKit
import HeatKit

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            NavigationLink("General") {
                GeneralView()
            }
            NavigationLink("Permissions") {
                PermissionsView()
            }
            NavigationLink("Services") {
                ServicesView()
            }
            NavigationLink("Instructions") {
                InstructionsView()
            }
            NavigationLink("Tools") {
                ToolsView()
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
