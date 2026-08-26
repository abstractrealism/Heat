import SwiftUI
import GenKit
import HeatKit

/// Search across every conversation, shown in place of one.
///
/// A full pane rather than a popover: the results are the thing being read,
/// and each one needs a title, enough surrounding text to recognise, and when
/// it was — which is more than a floating strip can hold.
struct SearchView: View {
    @Environment(AppState.self) private var state

    @State private var results: [Hit] = []
    @State private var isSearching = false
    @FocusState private var isFocused: Bool

    /// A conversation the query appears in.
    struct Hit: Identifiable {
        let fileID: String
        let title: String
        let snippet: String
        let modified: Date
        let count: Int

        var id: String { fileID }
    }

    /// One letter matches nearly everything, so the scan is skipped until
    /// there's enough to mean something.
    private static let minimumQuery = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { isFocused = true }
        .onExitCommand { state.isSearching = false }
        // Debounced rather than run per keystroke: every search reads and
        // decodes every conversation, and typing a word would otherwise do
        // that once per letter.
        .task(id: state.searchQuery) {
            let query = state.searchQuery
            guard query.count >= Self.minimumQuery else {
                results = []
                isSearching = false
                return
            }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await search(query)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search all conversations", text: Binding(
                get: { state.searchQuery },
                set: { state.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($isFocused)

            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if state.searchQuery.count < Self.minimumQuery {
            hint("Type to search across every conversation.")
        } else if isSearching {
            hint("Searching…")
        } else if results.isEmpty {
            hint("Nothing found for “\(state.searchQuery)”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(results.count == 1 ? "1 conversation" : "\(results.count) conversations")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 6)

                    ForEach(results) { hit in
                        SearchResultRow(hit: hit) { open(hit) }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens the conversation and hands it the query, so the find bar is
    /// already pointing at the first match rather than leaving the reader to
    /// look for it a second time.
    private func open(_ hit: Hit) {
        guard let file = try? API.shared.file(hit.fileID) else { return }
        let query = state.searchQuery

        state.selectedFileID = hit.fileID
        state.isSearching = false

        let model = ConversationViewModelStore.shared.model(for: file)
        model.beginFind()
        model.setFindQuery(query)
    }

    /// Reads every conversation and returns those the query appears in.
    ///
    /// No index. This machine's forty conversations come to about 1.3MB, and a
    /// pass over all of them — decode, strip reasoning, scan — measures 87ms.
    /// An index would be a second copy of the truth to keep in step with every
    /// streamed token, to save something a debounce already hides.
    ///
    /// But 87ms is five dropped frames, so only the *reading* happens here.
    /// Decoding and scanning are the expensive parts and need nothing from the
    /// main actor, so they run off it.
    private func search(_ query: String) async -> [Hit] {
        var payloads: [(file: File, data: Data)] = []
        for file in state.files where file.isConversation {
            guard let data = try? await API.shared.fileData(file.id) else { continue }
            payloads.append((file, data))
        }

        let found = payloads
        return await Task.detached(priority: .userInitiated) {
            var hits: [Hit] = []

            for (file, data) in found {
                guard !Task.isCancelled else { return [] }
                guard let conversation = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }

                let text = ConversationSearch.searchableText(of: conversation.messages)
                let count = ConversationSearch.matchCount(of: query, in: text)

                // A conversation named for what it's about is a hit even when
                // the words never appear inside it.
                let title = file.name ?? "Untitled"
                let titleMatches = ConversationSearch.contains(query, in: title)
                guard count > 0 || titleMatches else { continue }

                hits.append(
                    Hit(
                        fileID: file.id,
                        title: title,
                        snippet: ConversationSearch.snippet(for: query, in: text) ?? "",
                        modified: file.modified,
                        count: count
                    )
                )
            }

            // Most recent first, matching the sidebar's own default: what
            // you're looking for is usually something worked on lately.
            return hits.sorted { $0.modified > $1.modified }
        }.value
    }
}

private struct SearchResultRow: View {
    let hit: SearchView.Hit
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(hit.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if hit.count > 1 {
                            Text("\(hit.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(hit.modified.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
