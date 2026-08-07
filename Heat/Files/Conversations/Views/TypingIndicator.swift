import SwiftUI

/// Shown while a response is being generated but nothing has arrived to
/// display yet. A blinking cursor alone is easy to miss, and a local model on
/// modest hardware can take a long time to produce its first token, so this
/// says plainly that work is happening.
struct GeneratingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            Text("Generating")
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: dotSize, height: dotSize)
                        .opacity(animating ? 1 : 0.2)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }

    #if os(macOS)
    private let dotSize: CGFloat = 4
    #else
    private let dotSize: CGFloat = 5
    #endif
}

struct TypingIndicator: View {
    let foregroundColor: Color

    @State private var isVisible = true

    init(foregroundColor: Color = .primary) {
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Rectangle()
                .fill(foregroundColor)
                .frame(width: cursorWidth, height: cursorHeight)
                .clipShape(.rect(cornerRadius: 2))
                .opacity(isVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            handleBlink()
        }
    }

    func handleBlink() {
        withAnimation(.snappy(duration: 0.4).repeatForever(autoreverses: true)) {
            isVisible.toggle()
        }
    }

    #if os(macOS)
    private let cursorWidth: CGFloat = 2
    private let cursorHeight: CGFloat = 16
    #else
    private let cursorWidth: CGFloat = 2
    private let cursorHeight: CGFloat = 20
    #endif
}
