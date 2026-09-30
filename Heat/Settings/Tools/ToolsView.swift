import SwiftUI
import GenKit
import HeatKit

/// Where the tools are configured, as against the services that answer with
/// models.
///
/// Built like the Services pane — a list on the left, the chosen thing on the
/// right — because it's the same kind of pane and a second layout for the
/// same job would be one more thing to learn. No Defaults row: there is one
/// tool here that needs configuring and nothing yet that applies across all
/// of them.
struct ToolsView: View {
    @Environment(AppState.self) var state

    @State private var selection: SearchService.Kind? = .duckDuckGo

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Web Search") {
                    ForEach(SearchService.Kind.allCases) { kind in
                        Text(kind.name).tag(kind)
                    }
                }
            }
            .frame(width: 200)
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.enabled)
            .environment(\.defaultMinListRowHeight, 32)
            .scenePadding(.bottom)

            // Sized from the pane and scrolled, for the reasons in
            // ServiceView: a columns-style Form offered all the width it
            // likes comes out about 40% wider than its container and has no
            // scroller of its own.
            GeometryReader { pane in
                ScrollView {
                    Group {
                        if let selection {
                            SearchProviderForm(selection)
                                .id(selection)
                        } else {
                            ContentUnavailableView(
                                "Nothing selected",
                                systemImage: "magnifyingglass",
                                description: Text("Choose a search provider on the left.")
                            )
                        }
                    }
                    .frame(width: max(0, pane.size.width - 64), alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .scenePadding(.bottom)
                }
            }
        }
        #else
        List {
            Section("Web Search") {
                ForEach(SearchService.Kind.allCases) { kind in
                    NavigationLink(kind.name) {
                        SearchProviderForm(kind)
                            .id(kind)
                    }
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One search provider: what it is, where it is, and its key if it needs one.
private struct SearchProviderForm: View {
    @Environment(AppState.self) var state

    let kind: SearchService.Kind

    @State private var host = ""
    @State private var token = ""
    @State private var isLoaded = false

    init(_ kind: SearchService.Kind) {
        self.kind = kind
    }

    var body: some View {
        Form {
            Section {
                Text(kind.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(kind.name)
            }

            if kind.needsToken {
                Section {
                    // Not a SecureField. A key that can't be read back can't
                    // be checked against the one in the dashboard, which is
                    // the only thing anybody ever wants to do with it — and
                    // it's already stored in the clear in the config file, so
                    // hiding it on screen would suggest a protection that
                    // isn't there.
                    TextField("API key", text: $token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status)
                            .foregroundStyle(isReady ? Color.secondary : Color.orange)
                        if let signUp = kind.signUp {
                            // Opposite the status rather than under it: the
                            // two say different kinds of thing, one about
                            // what is here and one about what to do, and a
                            // link sitting flush under a label reads as a
                            // continuation of it.
                            Link("Get a key", destination: signUp)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .font(.footnote)
                }
            }

            Section {
                TextField("Address", text: $host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Text("Address")
            } footer: {
                Text("Where requests go. Leave as is, unless you're pointing Heat at a proxy or a compatible service of your own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: host) { _, _ in save() }
        .onChange(of: token) { _, _ in save() }
    }

    private var isReady: Bool {
        SearchService(kind: kind, host: host, token: token).isReady
    }

    /// Whether there is a key, and nothing else.
    ///
    /// It used to explain what the key was for in the same breath — "Set.
    /// Heat will use this when DuckDuckGo refuses a search." — which is what
    /// the summary at the top of the pane already says, two inches above.
    /// Only shown where a key is wanted at all, so the DuckDuckGo case that
    /// used to sit here was unreachable.
    private var status: String {
        isReady ? "Set" : "Not set"
    }

    private func load() {
        let provider = state.config.searchProvider(kind)
        host = provider.host
        token = provider.token
        isLoaded = true
    }

    /// Saved as it's typed, as the instruction editor and the service forms
    /// are. A key pasted in and a window closed straight after shouldn't lose
    /// the key.
    private func save() {
        guard isLoaded else { return }
        var config = state.config
        config.setSearchProvider(SearchService(kind: kind, host: host, token: token))
        Task { try? await API.shared.configUpdate(config) }
    }
}
