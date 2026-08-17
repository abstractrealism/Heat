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

/// A row of pictures, with one preview panel between them.
///
/// Not one per thumbnail. QuickLook's panel is a single shared object, so ten
/// thumbnails each binding their own preview all reach for the same panel and
/// whichever gets there first answers for the rest — which is why every
/// thumbnail opened the same picture.
struct ImageStripView: View {
    let images: [FoundImage]

    @State private var previewURL: URL?
    @State private var loadingID: URL?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(images) { found in
                    RenderImageView(found: found, isLoading: loadingID == found.id) {
                        Task { await preview(found.image) }
                    }
                }
            }
            .frame(height: 200)
        }
        .scrollIndicators(.hidden)
        .clipShape(.rect(cornerRadius: 5))
        .quickLookPreview($previewURL)
    }

    /// Fetches the picture to a file before previewing it.
    ///
    /// QuickLook previews files, not addresses: handed an https URL it tries to
    /// stat it as a path, fails to find it, and reports that the document
    /// couldn't be previewed — which reads as a broken image rather than as the
    /// wrong kind of URL.
    private func preview(_ url: URL) async {
        loadingID = url
        defer { loadingID = nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                return
            }
            // Named for what it is: QuickLook picks its renderer from the
            // extension, and a file without one previews as nothing.
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let file = URL.temporaryDirectory.appending(path: "heat-preview-\(UUID().uuidString).\(ext)")
            try data.write(to: file)
            previewURL = file
        } catch {
            // Nothing to say that the thumbnail doesn't already show. A
            // picture that won't fetch is the source's business, and a search
            // returns plenty of them.
        }
    }
}

struct RenderImageView: View {
    @Environment(\.openURL) private var openURL

    let found: FoundImage
    var isLoading = false
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
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(6)
                            .background(.thinMaterial, in: .rect(cornerRadius: 6))
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let source = found.source {
                Button("Open Source Page") { openURL(source) }
            }
            Button("Open Image") { openURL(found.image) }
        }
        .help(found.source?.host().map { "From \($0)" } ?? found.image.absoluteString)
    }
}
