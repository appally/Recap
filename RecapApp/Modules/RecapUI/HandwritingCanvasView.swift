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

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    // MARK: - 容器（纯 constraint 定位，避免 PKCanvasView 因 frame 反复重设而重渲染抖动）

    final class Container: UIView {
        let canvas = PKCanvasView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            // .anyInput：手指 + Apple Pencil 都能画（会议中可能用手指速记，Pencil 缺电也能写）。
            // 注：牺牲 .default 的 palm rejection（手掌排斥）—— 能写优先于手掌排斥。
            // 若确认全程用 Pencil 且要手掌排斥，可改 .default，但要确保用户不会用手指。
            canvas.drawingPolicy = .anyInput
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
            #if DEBUG
            print("[HW] drawingDidChange: strokes=\(view.drawing.strokes.count) bounds=\(view.drawing.bounds)")
            #endif
            // 注：无限滚动的 contentSize 扩展已移除--在 drawingDidChange 实时设 contentSize
            // 会打断 PKCanvasView 的 live interaction lock（"Did not have live interaction lock
            // at end of stroke"），导致第二笔起写不出 + mach_vm_allocate 失败。
            // 无限滚动需改用非实时方式（外部监听 strokes 变化、延后设 contentSize）重做。
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
