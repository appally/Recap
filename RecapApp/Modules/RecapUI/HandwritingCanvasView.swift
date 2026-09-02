import SwiftUI
import PencilKit

/// 暴露 PKCanvasView 的撤销/重做给 SwiftUI 层（canvas 的 undoManager 藏在 UIView 内）。
/// 工具切换交给原生 `PKToolPicker`（精简：钢笔+橡皮，剔除 Scribble/尺子/套索）。
@MainActor
final class HandwritingCanvasController: ObservableObject {
    weak var canvas: PKCanvasView?
    func attach(_ canvas: PKCanvasView) { self.canvas = canvas }
    func undo() { canvas?.undoManager?.undo() }
    func redo() { canvas?.undoManager?.redo() }
}

/// Apple Pencil 手写画布：`UIViewRepresentable` 包装 `PKCanvasView`。
///
/// 关键设计：
/// - `drawing` 真相源在父 View 的 `@State`（经 `@Binding` 传入）。modal/编辑器关闭重开父 View 不销毁，
///   笔画结构性保留；`makeUIView` 重灌 `canvas.drawing = drawing`。
/// - `drawingPolicy = .default`（真机）：Pencil 写、手指滚/缩放、手掌排斥（对齐 Notes）；模拟器退回 .anyInput。
/// - **原生 `PKToolPicker(toolItems:)`（iOS 18+）精简**：只放钢笔 fountainPen + 橡皮，
///   剔除 Scribble（会吞笔画进不了 OCR）/ 尺子 / 套索；原生视觉效果 + 关 Scribble 两全。
/// - firstResponder 延后到 fullScreenCover 转场后，避免「首次落笔要等两秒」。
struct HandwritingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var controller: HandwritingCanvasController? = nil
    /// 笔迹触及画布约满位置（ink bounds.maxY / contentSize.height ≥ 0.85）时回调。
    /// 仅提示——不实时调 contentSize（会打断 PencilKit live interaction lock，见下）。
    /// 带滞回：降到 0.8 以下重置，允许擦除后再提示。
    var onInkNearFull: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    // MARK: - 容器（纯 constraint 定位，避免 PKCanvasView 因 frame 反复重设而重渲染抖动）

    final class Container: UIView {
        let canvas = PKCanvasView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            // 真机 .default：仅 Apple Pencil 落墨，手指只滚/缩放，手掌排斥生效（对齐 Notes）——
            // 避免手指/手掌误写。模拟器无 Pencil，退回 .anyInput 以便鼠标/触摸测试。
            #if targetEnvironment(simulator)
            canvas.drawingPolicy = .anyInput
            #else
            canvas.drawingPolicy = .default
            #endif
            canvas.alwaysBounceVertical = false
            canvas.alwaysBounceHorizontal = false
            canvas.translatesAutoresizingMaskIntoConstraints = false
            addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.topAnchor.constraint(equalTo: topAnchor),
                canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    }

    // MARK: - Coordinator（delegate + 精简 toolPicker 强引用 + drawing 回写）

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker: PKToolPicker
        var drawing: Binding<PKDrawing>
        var onInkNearFull: (() -> Void)?
        /// 将满提示滞回状态（≥0.85 触发一次，<0.8 重置）。
        private var nearFullFired = false

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
            // iOS 18+ 精简工具盘：钢笔(fountainPen) + 橡皮；剔除 Scribble/尺子/套索。
            if #available(iOS 18.0, *) {
                let inking = PKToolPickerInkingItem(__inkType: .fountainPen, color: .label, width: 1.5)
                let eraser = PKToolPickerEraserItem(type: .bitmap)
                self.toolPicker = PKToolPicker(toolItems: [inking, eraser])
            } else {
                self.toolPicker = PKToolPicker()
            }
        }

        /// 用户每画一笔：把 canvas 的最新 drawing 写回父 @State（防 modal 关闭丢笔画）。
        func canvasViewDrawingDidChange(_ view: PKCanvasView) {
            if view.drawing != drawing.wrappedValue {
                drawing.wrappedValue = view.drawing
            }
            evaluateNearFull(view)
            #if DEBUG
            print("[HW] drawingDidChange: strokes=\(view.drawing.strokes.count) bounds=\(view.drawing.bounds)")
            #endif
            // 注：无限滚动的 contentSize 扩展已移除--在 drawingDidChange 实时设 contentSize
            // 会打断 PKCanvasView 的 live interaction lock（"Did not have live interaction lock
            // at end of stroke"），导致第二笔起写不出 + mach_vm_allocate 失败。
            // 无限滚动需改用非实时方式（外部监听 strokes 变化、延后设 contentSize）重做。
        }

        /// 将满判定（滞回）：ink bounds 底缘占 contentSize 高度比例。
        private func evaluateNearFull(_ view: PKCanvasView) {
            let contentHeight = max(view.contentSize.height, 1)
            let maxY = view.drawing.bounds.maxY
            if maxY.isFinite {
                let fraction = maxY / contentHeight
                if fraction >= 0.85, !nearFullFired {
                    nearFullFired = true
                    onInkNearFull?()
                } else if fraction < 0.8 {
                    nearFullFired = false
                }
            }
        }
    }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> Container {
        let container = Container()
        let canvas = container.canvas
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        // 显式设初始工具（兜底：不依赖 toolPicker.addObserver 的时序，避免 tool 未设导致写不出）。
        if #available(iOS 17.0, *) {
            canvas.tool = PKInkingTool(.fountainPen, color: .label, width: 1.5)
        }
        context.coordinator.toolPicker.addObserver(canvas)
        controller?.attach(canvas)
        // firstResponder 延后到下一 runloop（fullScreenCover 转场后）。
        let picker = context.coordinator.toolPicker
        DispatchQueue.main.async { [weak canvas] in
            guard let canvas else { return }
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
            // 无限滚动：一次性设较大 contentSize 允许垂直滚动（在 async 里设，不在 delegate
            // 实时回调里，避免打断 live interaction lock）。6 屏足够一段速记；写满可保存新段。
            if canvas.bounds.height > 0 {
                canvas.contentSize = CGSize(width: canvas.bounds.width, height: canvas.bounds.height * 6)
            }
            #if DEBUG
            print("[HW] makeUIView: frame=\(canvas.frame) tool=\(canvas.tool) drawingPolicy=\(canvas.drawingPolicy) isFirstResponder=\(canvas.isFirstResponder) contentSize=\(canvas.contentSize)")
            #endif
        }
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        let canvas = container.canvas
        context.coordinator.drawing = $drawing
        context.coordinator.onInkNearFull = onInkNearFull
        // 仅外部值变化时灌入 canvas，避免与 delegate 回写形成回环、污染 undo 栈。
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    static func dismantleUIView(_ container: Container, coordinator: Coordinator) {
        coordinator.toolPicker.removeObserver(container.canvas)
        coordinator.toolPicker.setVisible(false, forFirstResponder: container.canvas)
    }
}
