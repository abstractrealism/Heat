import SwiftUI
import GenKit
import HeatKit

struct RenderThinking: View {
    let tag: ContentParser.Result.Tag

    @State var disclosed = false
    
    init(_ tag: ContentParser.Result.Tag) {
        self.tag = tag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                disclosed.toggle()
            } label: {
                // Collapsed by default: reasoning is usually long and isn't
                // the answer, but it's there when you want to see the working.
                Label(
                    disclosed ? "Hide Thinking" : "Show Thinking",
                    systemImage: disclosed ? "chevron.down" : "chevron.right"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if disclosed {
                RenderText(tag.content, tags: ["reflection"])
                    .padding(.leading)
                    .overlay(
                        Rectangle()
                            .fill(.primary.opacity(0.5))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity),
                        alignment: .leading
                    )
                    .opacity(0.5)
            }
        }
    }
}
