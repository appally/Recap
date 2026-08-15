import Foundation
import Combine
import RecapASR

/// 回听高亮总线：把播放器 4Hz 的 `currentTime` 流收敛成「当前在听的转写块 id」，
/// 只在**跨块边界**时发布（会议场景分钟级一次）。
///
/// 此前 MeetingNoteView body 直接读 `audioPlayer.currentTime` 算 listeningBlockId——
/// 播放中整个 3700 行 View 随进度逐帧重算（连带全量行重建 + 时间轴排序）。
/// 现在行级高亮只观察本总线，播放进度推进不再打穿详情页 body。
@MainActor
final class ListeningBlockHighlight: ObservableObject {

    /// 当前回听位置所在的转写块 id（未播放 / 未就绪为 nil）。
    @Published private(set) var listeningBlockId: String?

    private var cancellables = Set<AnyCancellable>()
    /// 转写块起点表（id, startSeconds），由视图在转写内容变化时刷新。
    private var boundaries: [(id: String, start: Double)] = []

    func bind(player: MeetingAudioPlayer) {
        guard cancellables.isEmpty else { return }
        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                // sink 闭包非隔离；receive(on: main) 保证实际在主线程，assumeIsolated 回演员。
                MainActor.assumeIsolated {
                    self?.refresh(t: t, isReady: player.isReady)
                }
            }
            .store(in: &cancellables)
    }

    /// 转写块集合变化时刷新起点表（.task / 重转完成后调用）。
    func updateBlocks(_ blocks: [(id: String, start: Double)]) {
        boundaries = blocks
    }

    private func refresh(t: Double, isReady: Bool) {
        guard isReady, !boundaries.isEmpty else {
            if listeningBlockId != nil { listeningBlockId = nil }
            return
        }
        let id = boundaries.last(where: { $0.start <= t })?.id
        if id != listeningBlockId {
            listeningBlockId = id
        }
    }
}

/// 滚动几何中转存储（LIVE 贴底距离 / REVIEW 上一帧 offset）：
/// 仅事件回调读写、不参与渲染。用 @State 存这些逐帧值会让滚动打穿整页 body。
final class ScrollStateBox {
    var liveDistanceFromBottom: CGFloat = 0
    var lastReviewScrollY: CGFloat = 0
}
