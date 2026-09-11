import SwiftUI
import GenKit
import HeatKit

struct ServicesView: View {
    @Environment(AppState.self) var state

    @State var selection: String?
    @State var manager: ServicesManager = .init()

    var body: some View {
        #if os(macOS)
        HSplitView {
            List(selection: $selection) {
                ForEach(manager.services) { service in
                    Text(service.name).tag(service.id)
                }
            }
            .frame(minWidth: 200, idealWidth: 200, maxWidth: 400)
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.enabled)
            .environment(\.defaultMinListRowHeight, 32)
            .overlay(alignment: .bottom) {
                Button {
                    selection = nil
                } label: {
                    HStack {
                        Text("Defaults")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(.linearGradient(colors: [Color(hex: "#FAFAFA"), Color(hex: "#F5F5F5")], startPoint: .top, endPoint: .bottom))
                    .padding(1)
                }
                .buttonStyle(.plain)
                .overlay {
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
            }

            // The pane scrolls, because the form inside it doesn't. macOS
            // gives a Form the columns style by default, which lays its rows
            // out at full height and has no scroller of its own — so a pane
            // taller than the window was simply cut off, with nothing to drag
            // and nothing to scroll. Wrapping it here rather than switching to
            // the grouped style keeps these panes looking as they do.
            ScrollView {
                Group {
                    if let service = manager.get(selection) {
                        ServiceForm(service: service)
                            .id(service.id)
                    } else {
                        Form {
                            ServiceDefaults()
                        }
                    }
                }
                // Sized from the pane, not left to the form. Offered "as wide
                // as you like", a columns-style Form comes out about 40% wider
                // than the pane — measured: 834 points of form in a 660 pane,
                // 561 in 458 — and a scroll view that only scrolls vertically
                // won't be narrower than its content, so the pane's hosting
                // view centred the lot and clipped both ends: labels lost
                // their first letters on the left and every field ran off
                // the right. Told the pane's width outright, the rows lay out
                // to exactly that, and anything the form genuinely can't fit
                // overflows to the right alone, where the labels stay whole.
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                    max(0, width - 64)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .onAppear {
            manager.update(config: state.config)
        }
        .onDisappear {
            manager.save()
        }
        .environment(manager)
        #else
        List {
            ServiceDefaults()

            Section("Services") {
                ForEach(manager.services) { service in
                    NavigationLink(service.name) {
                        ServiceForm(service: service)
                            .id(service.id)
                            .environment(manager)
                    }
                }
            }
        }
        .navigationTitle("Service")
        .navigationBarTitleDisplayMode(.inline)
        .environment(manager)
        .onAppear {
            manager.update(config: state.config)
        }
        .onDisappear {
            manager.save()
        }
        #endif
    }
}
