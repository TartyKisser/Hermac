import SwiftUI

struct MessageBody: View {
    private let document: MarkdownDocument

    init(text: String) {
        document = MarkdownDocument(text)
    }

    var body: some View {
        MarkdownBlocksView(blocks: document.blocks)
            .font(.system(size: 14))
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownDocument.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .codeBlock(let language):
            MarkdownCodeBlock(code: String(block.text.characters), language: language)
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(block.children) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(for: item))
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                            .accessibilityHidden(true)
                        MarkdownBlockView(block: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .blockQuote:
            content
                .padding(.leading, 15)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.secondary.opacity(0.35)).frame(width: 3)
                }
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        case .table(let columns):
            MarkdownTableView(rows: block.children, columns: columns)
        default:
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !block.text.characters.isEmpty {
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !block.children.isEmpty {
                MarkdownBlocksView(blocks: block.children)
            }
        }
    }

    private func marker(for item: MarkdownDocument.Block) -> String {
        if case .orderedList = block.kind, case .listItem(let ordinal) = item.kind {
            return "\(ordinal)."
        }
        return "•"
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 24
        case 2: 21
        case 3: 18
        default: 15
        }
    }
}

private struct MarkdownCodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language ?? "代码").foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, title: "复制代码")
            }
            .font(.caption)
            ScrollView(.horizontal) {
                Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MarkdownTableView: View {
    let rows: [MarkdownDocument.Block]
    let columns: [PresentationIntent.TableColumn]
    @State private var availableWidth: CGFloat = 0

    private var columnWidth: CGFloat { max(170, availableWidth / CGFloat(max(columns.count, 1))) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows) { row in
                    GridRow(alignment: .top) {
                        ForEach(columns.indices, id: \.self) { index in
                            Text(cell(in: row, column: index))
                                .fontWeight(row.kind == .tableHeaderRow ? .semibold : nil)
                                .multilineTextAlignment(textAlignment(index))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(width: columnWidth, alignment: alignment(index))
                        }
                    }
                    if row.id != rows.last?.id {
                        Divider().gridCellColumns(columns.count).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary, lineWidth: 1)
        }
    }

    private func cell(in row: MarkdownDocument.Block, column: Int) -> AttributedString {
        row.children.first(where: { $0.kind == .tableCell(columnIndex: column) })?.text ?? AttributedString("")
    }

    private func alignment(_ index: Int) -> Alignment {
        switch columns[index].alignment {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        @unknown default: .topLeading
        }
    }

    private func textAlignment(_ index: Int) -> TextAlignment {
        switch columns[index].alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}
