import Foundation

/// Foundation parses the syntax; this tree gives SwiftUI the block structure
/// that Text does not lay out from presentation intents by itself.
struct MarkdownDocument {
    struct Block: Identifiable {
        let id: Int
        let kind: PresentationIntent.Kind
        var text: AttributedString
        var children: [Block]
    }

    let blocks: [Block]

    init(_ source: String) {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(source)
        var blocks: [Block] = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var text = AttributedString(parsed[range])
            text.presentationIntent = nil
            if let intent {
                let path = Array(intent.components.reversed())
                Self.append(text, path: path[...], to: &blocks)
            } else {
                blocks.append(Block(id: -blocks.count - 1, kind: .paragraph, text: text, children: []))
            }
        }
        self.blocks = blocks
    }

    private static func append(_ text: AttributedString,
                               path: ArraySlice<PresentationIntent.IntentType>,
                               to blocks: inout [Block]) {
        guard let component = path.first else { return }
        if blocks.last?.id != component.identity {
            blocks.append(Block(id: component.identity, kind: component.kind,
                                text: AttributedString(), children: []))
        }
        let index = blocks.count - 1
        if path.count == 1 {
            blocks[index].text.append(text)
        } else {
            append(text, path: path.dropFirst(), to: &blocks[index].children)
        }
    }
}
