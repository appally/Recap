import SwiftUI

/// 路由：LIVE（录音中） 或 具体某场会议
enum MeetingRoute: Hashable {
    case live
    case meeting(Meeting)
}

/// 首页 · 会议列表（极简：一个列表 + 底部录音按钮 + 右上账户入口，无 Tab）
struct MeetingListView: View {
    @State private var meetings = Meeting.list
    @State private var path = NavigationPath()

    private var liveMeetings: [Meeting] { meetings.filter { $0.listStatus == .live } }
    private var todayMeetings: [Meeting] {
        meetings.filter { $0.dateText.hasPrefix("07/24") && $0.listStatus != .live }
    }
    private var weekMeetings: [Meeting] {
        meetings.filter { !$0.dateText.hasPrefix("07/24") }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Color.recapBg.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                        Text("会议")
                            .font(.recapLargeTitle)
                            .foregroundStyle(Color.recapInk)
                            .padding(.top, Spacing.sm)

                        if !liveMeetings.isEmpty {
                            sectionHeader("进行中", dotColor: Color.recapCinnabar)
                            ForEach(liveMeetings) { m in rowButton(m) }
                        }

                        sectionHeader("今天", dotColor: .clear)
                        ForEach(todayMeetings) { m in rowButton(m) }

                        if !weekMeetings.isEmpty {
                            sectionHeader("本周", dotColor: .clear)
                            ForEach(weekMeetings) { m in rowButton(m) }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, 120)
                }
                .scrollContentBackground(.hidden)

                RecordingButton { path.append(MeetingRoute.live) }
                    .padding(.bottom, Spacing.xxl)
            }
            .navigationDestination(for: MeetingRoute.self) { route in
                switch route {
                case .live:
                    MeetingNoteView(initialPhase: .live) {
                        path.removeLast()
                    }
                case .meeting(let m):
                    MeetingNoteView(meeting: m,
                                    initialPhase: m.listStatus == .live ? .live : .review) {
                        path.removeLast()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { accountButton }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 子视图

    private func sectionHeader(_ title: String, dotColor: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            if dotColor != .clear {
                breathingDot
            }
            Text(title).font(.recapSection).foregroundStyle(Color.recapTea)
            Spacer()
        }
        .padding(.top, Spacing.md)
    }

    private var breathingDot: some View {
        Circle()
            .fill(Color.recapCinnabar)
            .frame(width: 7, height: 7)
            .modifier(BreathingModifier())
    }

    private func rowButton(_ m: Meeting) -> some View {
        NavigationLink(value: m) { meetingRow(m) }
    }

    private func meetingRow(_ m: Meeting) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title)
                    .font(.recapMeta.weight(.semibold))
                    .foregroundStyle(Color.recapInk)
                HStack(spacing: Spacing.sm) {
                    Text("\(m.dateText) · \(m.durationText) · \(m.attendeeCount) 人")
                        .font(.recapTimestamp)
                        .foregroundStyle(Color.recapTea)
                    if m.todoCount > 0 {
                        Text("☐\(m.todoCount)")
                            .font(.recapTimestamp)
                            .foregroundStyle(Color.recapCinnabar)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.6))
        }
        .padding(Spacing.md)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
    }

    private var accountButton: some View {
        Button {} label: {
            ZStack {
                Circle().fill(Color.recapCeladon.opacity(0.18)).frame(width: 32, height: 32)
                Text("R")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapCeladon)
            }
        }
    }
}

// MARK: - 呼吸动画修饰符（首页「进行中」朱砂点）

struct BreathingModifier: ViewModifier {
    @State private var breathe = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(breathe ? 1.25 : 1.0)
            .opacity(breathe ? 1.0 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}
