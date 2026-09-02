import SwiftUI
import PencilKit

/// 会中/会后手写全屏容器：drawing 真相源下沉到本视图（每笔画只重算本小子树，
/// 不再打穿 MeetingNoteView 巨 body——修 `glassEffect() tried to update multiple times
/// per frame` 每帧风暴，见 2026-08-17 真机日志）。
///
/// 保存语义（防丢升级）：提交后**落盘成功才关闭**；失败保持画布打开 + 状态栏提示重试
/// （旧序「先关闭靠残留 @State 恢复」存在关了才发现没存的窗口）。
struct LiveHandwritingCover: View {
    @State private var drawing: PKDrawing
    @StateObject private var controller = HandwritingCanvasController()
    @State private var showNearlyFullHint = false
    @Environment(\.dismiss) private var dismiss

    let onCommit: (PKDrawing, _ completion: @escaping (Bool) -> Void) -> Void

    init(initialDrawing: PKDrawing,
         onCommit: @escaping (PKDrawing, _ completion: @escaping (Bool) -> Void) -> Void) {
        _drawing = State(initialValue: initialDrawing)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏：左 返回（存盘+关闭），右 撤销——对齐会后编辑器的 xmark + 撤销 视觉语言。
            HStack(spacing: Spacing.sm) {
                Button {
                    Haptics.impact(.light)
                    onCommit(drawing) { success in
                        if success { dismiss() }   // 失败不关：笔迹在画布，重试可存
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.recapInk)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.impact(.light)
                    controller.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.recapInk)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            if showNearlyFullHint {
                HandwritingNearlyFullHint()
                    .padding(.bottom, Spacing.sm)
                    .transition(.opacity)
            }

            HandwritingCanvasView(drawing: $drawing,
                                  controller: controller,
                                  onInkNearFull: { showNearlyFullHint = true })
                .background(Color.recapPaper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.recapPaper)
    }
}

/// 会后手写编辑器容器：全屏画布 + 关闭（放弃修改）/撤销/保存。保存成功才关闭。
struct ReviewHandwritingEditorContainer: View {
    @State private var drawing: PKDrawing
    @StateObject private var controller = HandwritingCanvasController()
    @State private var showNearlyFullHint = false
    @Environment(\.dismiss) private var dismiss

    let onCommit: (PKDrawing, _ completion: @escaping (Bool) -> Void) -> Void

    init(initialDrawing: PKDrawing,
         onCommit: @escaping (PKDrawing, _ completion: @escaping (Bool) -> Void) -> Void) {
        _drawing = State(initialValue: initialDrawing)
        self.onCommit = onCommit
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showNearlyFullHint {
                    HandwritingNearlyFullHint()
                        .padding(.bottom, Spacing.sm)
                        .transition(.opacity)
                }
                HandwritingCanvasView(drawing: $drawing,
                                      controller: controller,
                                      onInkNearFull: { showNearlyFullHint = true })
                    .background(Color.recapPaper)
            }
            .navigationTitle("手写笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左：关闭（放弃修改退出）用 xmark，语义明确，不与撤销混淆。
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                // 右：撤销 + 保存同属操作区，撤销不再独居左上被误认为「返回」。
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onCommit(drawing) { success in
                            if success { dismiss() }   // 失败不关：笔迹在画布，重试可存
                        }
                    }
                    .disabled(drawing.strokes.isEmpty)
                }
            }
        }
    }
}

/// 画布将满轻提示（不强制、不调 contentSize——实时调整会打断 PencilKit live
/// interaction lock，见 HandwritingCanvasView 注释）。样式语言对齐 DialectHintBar。
private struct HandwritingNearlyFullHint: View {
    var body: some View {
        Text("画布将满，建议保存此段后开新段")
            .font(.recapMeta)
            .foregroundStyle(Color.recapInk)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Color.recapOchre.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, Spacing.xl)
    }
}
