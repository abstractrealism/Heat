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

    /// Which picture the sheet is showing, kept apart from whether the sheet is
    /// up. Presenting on the item itself would tie the sheet's identity to the
    /// picture, so stepping to the next one would dismiss and re-present rather
    /// than simply change what's inside.
    @State private var previewIndex = 0
    @State private var isPreviewing = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(images) { found in
                    RenderImageView(found: found) {
                        previewIndex = images.firstIndex(of: found) ?? 0
                        isPreviewing = true
                    }
                    .id(found.id)
                }
            }
            .frame(height: 200)
        }
        .scrollIndicators(.hidden)
        .clipShape(.rect(cornerRadius: 5))
        .sheet(isPresented: $isPreviewing) {
            ImagePreviewSheet(images: images, index: $previewIndex)
        }
    }
}

/// One picture at a time, as large as the sheet allows, with the rest of the
/// results a keypress away.
private struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let images: [FoundImage]
    @Binding var index: Int

    private var found: FoundImage? {
        images.indices.contains(index) ? images[index] : images.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let found {
                // Fitted rather than filled: this is the view for looking at
                // the whole picture, unlike the thumbnail, which crops to a
                // square on purpose.
                AsyncImage(url: found.image) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                        .controlSize(.small)
                }
                // Keyed to the picture so moving on doesn't briefly show the
                // previous one at the new one's size while it loads.
                .id(found.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)

                Divider()
                controls(for: found)
            }
        }
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 560)
    }

    @ViewBuilder
    private func controls(for found: FoundImage) -> some View {
        HStack(spacing: 8) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index <= 0)
            // No modifier, so the arrow keys work on their own. Attached to the
            // buttons rather than watched separately, which keeps the shortcut
            // and the control that performs it in one place and greys the key
            // out at the ends along with the button.
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous image")

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= images.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next image")

            Text("\(index + 1) of \(images.count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let host = found.source?.host() {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if let source = found.source {
                Button("Open Source Page") { openURL(source) }
            }
            Button("Open Image") { openURL(found.image) }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), images.count - 1)
    }
}

/// A thumbnail that opens the picture.
///
/// No context menu. One was here offering the source page and the image, and
/// it acted on the first result whichever thumbnail it was raised from —
/// through two attempts at fixing it, including giving each thumbnail an
/// explicit identity. `contextMenu` on items inside a horizontal `ScrollView`
/// builds its menu against the wrong item, and passing the picture into the
/// menu explicitly doesn't change that.
///
/// Both actions live in the sheet the thumbnail opens, where they work. A menu
/// that quietly acts on something other than what was clicked is worse than no
/// menu, and this one was redundant the moment the sheet gained the buttons.
struct RenderImageView: View {
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
        .help(found.source?.host().map { "From \($0) — click to open" } ?? found.image.absoluteString)
    }
}
