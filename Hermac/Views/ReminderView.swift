import SwiftUI

struct ReminderView: View {
    @Bindable var store: ReminderStore
    let cancel: @MainActor () -> Void
    let retry: @MainActor () -> Void
    let requestAccessibility: @MainActor () -> Void
    let updatePresentation: @MainActor () -> Void

    private var isExpanded: Bool { store.phase == .review || store.phase == .error }

    var body: some View {
        Group {
            if isExpanded {
                editor
            } else {
                status
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: isExpanded ? 22 : 24, style: .continuous))
        .padding(8)
        .onChange(of: store.phase) { updatePresentation() }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if store.phase == .success {
                ReminderCompletionMark().frame(width: 23, height: 23)
                Text("已创建提醒事项")
                    .accessibilityIdentifier("reminderSuccess")
            } else {
                HermacMark(isAnimating: true).frame(width: 23, height: 23)
                Text(store.phase == .saving ? "正在创建提醒事项…" : "正在整理日程…")
                    .accessibilityIdentifier("reminderProgress")
            }
            Spacer(minLength: 0)
            if store.phase != .saving && store.phase != .success {
                Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel("取消创建提醒事项")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                HermacMark().frame(width: 22, height: 22)
                Text("创建提醒事项").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: cancel) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel("取消创建提醒事项")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("reminderError")
                    }
                    if store.phase == .error {
                        if store.needsAccessibilityPermission {
                            Button("打开辅助功能设置", action: requestAccessibility)
                                .accessibilityIdentifier("reminderAccessibilitySettings")
                        }
                    } else {
                        if !store.contextSummary.isEmpty {
                            Label(store.contextSummary, systemImage: "text.bubble")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("reminderContextSummary")
                        }
                        fields
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("取消", action: cancel)
                Spacer()
                if store.phase == .error {
                    Button("重新整理", action: retry)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("retryReminder")
                } else {
                    Button("确认创建") { store.confirm() }
                        .buttonStyle(.glassProminent)
                        .disabled(store.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirmReminder")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 15) {
            field("标题") {
                TextField("提醒事项名称", text: $store.draft.title, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("reminderTitle")
            }
            VStack(alignment: .leading, spacing: 9) {
                Toggle("提醒日期", isOn: Binding(
                    get: { store.draft.dueDate != nil },
                    set: { enabled in
                        store.draft.dueDate = enabled ? Calendar.current.startOfDay(for: Date()) : nil
                        if !enabled { store.draft.includesTime = false }
                    }
                ))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("reminderHasDate")
                if store.draft.dueDate != nil {
                    HStack {
                        DatePicker("日期", selection: dueDate, displayedComponents: .date)
                            .labelsHidden().accessibilityIdentifier("reminderDate")
                        Spacer()
                        Toggle("指定时间", isOn: $store.draft.includesTime)
                            .toggleStyle(.checkbox).accessibilityIdentifier("reminderHasTime")
                    }
                    if store.draft.includesTime {
                        DatePicker("时间", selection: dueDate, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("reminderTime")
                    }
                }
            }
            field("地点") {
                TextField("可选", text: $store.draft.location)
                    .accessibilityIdentifier("reminderLocation")
            }
            field("备注") {
                TextEditor(text: $store.draft.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 68, maxHeight: 100)
                    .padding(5)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("reminderNotes")
            }
            HStack {
                Picker("优先级", selection: $store.draft.priority) {
                    Text("无").tag(0)
                    Text("低").tag(9)
                    Text("中").tag(5)
                    Text("高").tag(1)
                }
                .accessibilityIdentifier("reminderPriority")
                Spacer()
            }
            HStack {
                Picker("清单", selection: $store.draft.calendarID) {
                    Text("系统默认清单").tag(String?.none)
                    ForEach(store.lists) { list in Text(list.title).tag(Optional(list.id)) }
                }
                .accessibilityIdentifier("reminderList")
                if store.lists.isEmpty {
                    Button("读取清单") { Task { await store.loadLists() } }
                        .font(.caption).buttonStyle(.borderless)
                        .accessibilityIdentifier("loadReminderLists")
                }
            }
        }
        .font(.system(size: 13))
        .textFieldStyle(.roundedBorder)
    }

    private var dueDate: Binding<Date> {
        Binding(get: { store.draft.dueDate ?? Date() }, set: { store.draft.dueDate = $0 })
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ReminderCompletionMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(.green.opacity(0.1))
            Circle().trim(from: 0, to: ring)
                .stroke(.green.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Path { path in
                path.move(to: CGPoint(x: 6, y: 12))
                path.addLine(to: CGPoint(x: 10, y: 16))
                path.addLine(to: CGPoint(x: 18, y: 7))
            }
            .trim(from: 0, to: check)
            .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .onAppear {
            if reduceMotion { ring = 1; check = 1 }
            else {
                withAnimation(.easeOut(duration: 0.28)) { ring = 1 }
                withAnimation(.spring(duration: 0.35).delay(0.12)) { check = 1 }
            }
        }
        .accessibilityLabel("创建完成")
    }
}
