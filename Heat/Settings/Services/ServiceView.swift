import SwiftUI
import GenKit
import HeatKit

struct ServicesView: View {
    @Environment(AppState.self) var state

    @State var selection: String?
    @State var manager: ServicesManager = .init()

    var body: some View {
        #if os(macOS)
        // A plain stack rather than an HSplitView. The split's divider showed
        // a resize cursor but never moved — the pane on the right is sized
        // from its container, so the split had nothing to give — and a
        // control that promises what it can't do is worse than none.
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(manager.services) { service in
                    Text(service.name).tag(service.id)
                }
            }
            .frame(width: 200)
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
            // The list keeps its margin below; only the pane runs to the
            // edge. After the overlay, or the Defaults button would sit in
            // the margin rather than at the foot of the list.
            .scenePadding(.bottom)

            // The pane scrolls, because the form inside it doesn't. macOS
            // gives a Form the columns style by default, which lays its rows
            // out at full height and has no scroller of its own — so a pane
            // taller than the window was simply cut off, with nothing to drag
            // and nothing to scroll. Wrapping it here rather than switching to
            // the grouped style keeps these panes looking as they do.
            //
            // Sized from the pane, not left to the form. Offered "as wide as
            // you like", a columns-style Form comes out about 40% wider than
            // the pane — measured: 834 points of form in a 660 pane, 561 in
            // 458 — and a scroll view that only scrolls vertically won't be
            // narrower than its content, so the whole thing was centred and
            // clipped at both ends: labels lost their first letters on the
            // left and every field ran off the right. A GeometryReader takes
            // whatever width is left after the list and passes it down as a
            // fixed one; the rows then lay out to exactly that, and anything
            // the form genuinely can't fit overflows to the right alone, where
            // the labels stay whole. (containerRelativeFrame was tried first
            // and resolved against the window here, not the pane.)
            GeometryReader { pane in
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
                    .frame(width: max(0, pane.size.width - 64), alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    // The margin the pane gave up goes inside the scroll
                    // instead, so the last row still ends a margin above the
                    // edge once scrolled to the bottom.
                    .scenePadding(.bottom)
                }
            }
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
