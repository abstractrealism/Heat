import SwiftUI
import OSLog
import SharedKit
import GenKit
import HeatKit

struct GeneralForm: View {
    @Environment(AppState.self) var state

    @State private var selectedTab: Tab = .profile
    @State private var newToolName: String = ""
    @State private var isShowingAlert = false

    enum Tab: String, CaseIterable {
        case profile = "Profile"
    }

    var body: some View {
        #if os(macOS)
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .padding()
                    .tag(tab)
                    .tabItem {
                        Text(tab.rawValue)
                    }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .navigationTitle("Account")
        #else
        VStack {
            Picker("Select item", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            tabContent(for: selectedTab)
        }
        #endif
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .profile: ConfigUserForm()
        }
    }
}

struct ConfigUserForm: View {
    @Environment(AppState.self) var state

    @State var name = ""
    @State var bio = ""
    @State var location = ""

    @AppStorage(AppAppearance.preferenceKey) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .help("Follow the system setting, or keep Heat light or dark whatever the system does.")
                    .padding(.bottom, 8)
            } header: {
                Text("Appearance")
            }

            Section {
                TextField("Name", text: $name)
                    .help("What the assistant should call you. Example: Alex")
                TextField("Location", text: $location)
                    .autocorrectionDisabled(false)
                    .help("Where you are, for answers that depend on it — time zones, weather, local recommendations. Example: Portland, Oregon")
                TextField("Bio", text: $bio, axis: .vertical)
                    .help("Anything the assistant should keep in mind about you. Example: Software developer, learning Swift, prefers concise answers.")
            } header: {
                Text("About You")
            } footer: {
                Text("Sent with every message, so the assistant knows who it's talking to. Leave blank to send nothing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            handleLoad()
        }
        .onDisappear {
            handleDisappear()
        }
    }

    func handleLoad() {
        let config = state.config
        name = config.userName ?? ""
        location = config.userLocation ?? ""
        bio = config.userBiography ?? ""
    }

    func handleDisappear() {
        Task {
            var config = state.config
            config.userName = name.isEmpty ? nil : name
            config.userLocation = location.isEmpty ? nil : location
            config.userBiography = bio.isEmpty ? nil : bio

            do {
                try await API.shared.configUpdate(config)
            } catch {
                state.log(error: error)
            }
        }
    }
}
