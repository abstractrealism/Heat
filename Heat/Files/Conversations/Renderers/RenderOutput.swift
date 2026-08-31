import SwiftUI
import GenKit
import HeatKit

struct RenderOutput: View {
    let tag: ContentParser.Result.Tag

    init(_ tag: ContentParser.Result.Tag) {
        self.tag = tag
    }

    var body: some View {
        RenderText(tag.content, tags: ["reflection", "image_search_query"])
            // Tool output is deliberately outside find's reach; keep the
            // in-text marks out of it too.
            .environment(\.findHighlightQuery, nil)
    }
}
