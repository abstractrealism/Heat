import SwiftUI
import QuickLook
import GenKit
import HeatKit

struct RenderImageSearch: View {
    @Environment(\.openURL) var openURL

    let tag: ContentParser.Result.Tag

    @State private var results: [WebSearchResult] = []

    init(_ tag: ContentParser.Result.Tag) {
        self.tag = tag
    }

    var body: some View {
        VStack(alignment: .leading) {
            ImageStripView(images: FoundImage.from(results.prefix(10)))

            if let content = tag.content {
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            Task { try await performQuery() }
        }
    }

    func performQuery() async throws {
        guard tag.hasClosingTag else {
            return
        }
        guard let content = tag.content else {
            throw RenderTagError.missingContent
        }
        let resp = try await WebSearchSession.shared.searchImages(query: content)
        results = resp.results
    }
}

/// A picture a search found, and the page it came from.
struct FoundImage: Identifiable, Hashable {
    let image: URL
    let source: URL?

    var id: URL { image }

    /// Deduplicated, since identity here is the image's own address and the
    /// same picture can be indexed from more than one page.
    static func from(_ results: some Sequence<WebSearchResult>) -> [FoundImage] {
        var seen = Set<URL>()
        return results.compactMap { result in
            guard let image = result.image, seen.insert(image).inserted else { return nil }
            return FoundImage(image: image, source: result.url)
        }
    }
}

/// A row of pictures, each opening in a sheet.
///
/// Deliberately not QuickLook. Its panel is a single shared object that a view
/// has to win control of, and two attempts at driving it from here produced
/// the same two failures: `QLPreviewPanel ... has no controller` in the log,
/// and every thumbnail opening whichever picture got to the panel first. It
/// also previews files rather than addresses, so each picture had to be
/// downloaded to a temporary file before it would show at all.
///
/// A sheet has none of that. The state is one optional, held here, and the
/// picture it shows is the one that was clicked because nothing else can be.
struct ImageStripView: View {
    let images: [FoundImage]

    @State private var preview: FoundImage?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(images) { found in
                    RenderImageView(found: found) { preview = found }
                        .id(found.id)
                }
            }
            .frame(height: 200)
        }
        .scrollIndicators(.hidden)
        .clipShape(.rect(cornerRadius: 5))
        .sheet(item: $preview) { found in
            ImagePreviewSheet(found: found)
        }
    }
}

/// One picture, as large as the sheet allows.
private struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let found: FoundImage

    var body: some View {
        VStack(spacing: 0) {
            // Fitted rather than filled: this is the view for looking at the
            // whole picture, unlike the thumbnail, which crops to a square on
            // purpose.
            AsyncImage(url: found.image) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)

            Divider()

            HStack {
                if let host = found.source?.host() {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let source = found.source {
                    Button("Open Source Page") { openURL(source) }
                }
                Button("Open Image") { openURL(found.image) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 560)
    }
}

struct RenderImageView: View {
    @Environment(\.openURL) private var openURL

    let found: FoundImage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PictureView(url: found.image)
                .scaleEffect(1.1)
                .frame(width: 200, height: 200)
                .clipShape(.rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        // Bound to this picture explicitly rather than read from whatever the
        // view happens to hold when the menu is built, which is how every
        // thumbnail ended up offering the first result's links.
        .contextMenu { menu(for: found) }
        .help(found.source?.host().map { "From \($0)" } ?? found.image.absoluteString)
    }

    @ViewBuilder
    private func menu(for found: FoundImage) -> some View {
        if let source = found.source {
            Button("Open Source Page") { openURL(source) }
        }
        Button("Open Image") { openURL(found.image) }
    }
}
