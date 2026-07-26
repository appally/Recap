import SwiftUI

/// 会议智能体唤起面板（会中 / 会后同一入口，能力随态切换）
/// 「它一直在干活，但只在被叫到时才说话」
struct AgentInvokeSheet: View {
    let phase: MeetingPhase
    @Binding var isPresented: Bool

    @State private var input: String = ""
    @State private var state: AskState = .idle

    enum AskState: Equatable {
        case idle
        case thinking(query: String)
        case answered(query: String, answer: String, source: String)
    }

    private struct QandA { let q: String; let a: String; let src: String }
    private let knowledge: [QandA] = [
        .init(q: "总结", a: "已讨论方案复盘与预算。关键结论：移动端投入提至总预算 30%。",
              src: "截至 14:35"),
        .init(q: "报价", a: "单设备报价约 420 元，含一年服务。",
              src: "李华 · 14:32"),
        .init(q: "待办", a: "已捕捉 3 条：出评审方案(李华)、确认客户报价(张明·待确认)、整理报价对比表(张明)。",
              src: "实时捕捉"),
    ]

    private var chips: [String] {
        switch phase {
        case .live:       return ["总结到此刻", "报价多少", "待办有啥"]
        case .review:     return ["总结这场会议", "还有什么未决", "帮我分发待办"]
        case .processing: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(chips, id: \.self) { chip in
                            Button { ask(chip) } label: { chipLabel(chip) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            switch state {
            case .idle:
                EmptyView()
            case .thinking(let q):
                questionBubble(q)
                thinkingRow
            case .answered(let q, let a, let src):
                questionBubble(q)
                answerCard(answer: a, source: src)
                actionRow
            }

            inputBar
        }
        .padding(Spacing.xl)
    }

    // MARK: 子视图

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Color.recapCeladon)
            Text("问 Recap").font(.recapSection).foregroundStyle(Color.recapInk)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
            }
            .buttonStyle(.plain)
        }
    }

    private func chipLabel(_ t: String) -> some View {
        Text(t)
            .font(.recapMeta)
            .foregroundStyle(Color.recapInk)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .recapGlass(cornerRadius: 20)
    }

    private func questionBubble(_ q: String) -> some View {
        HStack {
            Spacer()
            Text(q)
                .font(.recapRaw)
                .foregroundStyle(Color.recapInk)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    Color.recapCeladon.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: Spacing.sm) {
            Text("🦦").font(.system(size: 16))
            Text("正在本机查找…").font(.recapRaw).foregroundStyle(Color.recapTea)
            Spacer()
        }
    }

    private func answerCard(answer: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.recapCeladon)
                    .padding(.top, 3)
                Text(answer)
                    .font(.recapRaw)
                    .foregroundStyle(Color.recapInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.up.right").font(.system(size: 9))
                Text("来源：\(source)").font(.recapTimestamp).foregroundStyle(Color.recapCinnabar)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.lg) {
            actionChip("追问")
            actionChip("转待办")
            actionChip("复制")
            Spacer()
        }
    }

    private func actionChip(_ t: String) -> some View {
        Button {} label: {
            Text(t)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 6)
                .background(Color.recapBg, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles").foregroundStyle(Color.recapCeladon)
            TextField("问任何关于本会议的问题", text: $input)
                .font(.recapRaw)
                .submitLabel(.send)
                .onSubmit { submit() }
            if !input.isEmpty {
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.recapCeladon)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .recapGlass(cornerRadius: Radius.card)
    }

    // MARK: 逻辑

    private func submit() {
        guard !input.isEmpty else { return }
        ask(input)
        input = ""
    }

    private func ask(_ q: String) {
        withAnimation(.recapSoft) { state = .thinking(query: q) }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            let hit = knowledge.first { q.contains($0.q) || $0.q.contains(q) }
            let answer = hit?.a ?? "（原型占位）这是基于本场录音的本机回答，不涉及任何数据上传。"
            let source = hit?.src ?? "本机处理"
            withAnimation(.recapSoft) {
                state = .answered(query: q, answer: answer, source: source)
            }
        }
    }
}
