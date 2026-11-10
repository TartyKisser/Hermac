import SwiftUI

struct PromptCard: View {
    let prompt: AgentPrompt
    let answer: (String) async -> Void
    @State private var reply = ""
    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(prompt.kind == "approval" ? "需要你的授权" : "Hermes 想确认", systemImage: prompt.kind == "approval" ? "hand.raised" : "questionmark.bubble")
                .font(.headline)
            Text(prompt.question).font(.callout).textSelection(.enabled)
            if !prompt.detail.isEmpty {
                ScrollView { Text(prompt.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if prompt.kind == "approval" {
                HStack {
                    Spacer()
                    Button("拒绝") { respond("deny") }
                    if prompt.choices.contains("once") {
                        Button("允许一次") { respond("once") }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                if !prompt.choices.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(prompt.choices, id: \.self) { choice in Button(choice) { reply = choice } } }
                    }
                }
                HStack {
                    TextField("输入回复", text: $reply).textFieldStyle(.roundedBorder).onSubmit { respond(reply) }
                    Button("回复") { respond(reply) }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .disabled(isAnswering)
    }

    private func respond(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAnswering = true
        Task { await answer(value); isAnswering = false }
    }
}
