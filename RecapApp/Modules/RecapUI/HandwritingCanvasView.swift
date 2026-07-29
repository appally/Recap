import SwiftUI
import PencilKit

/// Apple Pencil 手写画布：`UIViewRepresentable` 包装 `PKCanvasView`。
///
/// 关键设计：
/// - `drawing` 真相源在父 View 的 `@State`（经 `@Binding` 传入）。tab 切换时父 View 不销毁，
///   笔画结构性保留；切回时 `makeUIView` 重灌 `canvas.drawing = drawing`。**绝不把 drawing 存进 canvas 局部 state。**
/// - `drawingPolicy = .anyInput`：iOS 26 默认 `.pencilOnly`，手指 / 模拟器触控写不出，显式放开。
/// - `PKToolPicker` 三件套（addObserver + setVisible + becomeFirstResponder），引用存 Coordinator 防释放
///   （放局部变量会闪退消失）。
/// - 独立 tab 不与转写同屏，故**无需 hitTest 穿透**（避开 PencilKit 头号大坑）。
struct HandwritingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    // MARK: - 容器（仿 `CameraPreviewView` 的 Container + layoutSubviews 同步 frame）

    final class Container: UIView {
        let canvas = PKCanvasView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            canvas.drawingPolicy = .anyInput
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
        override func layoutSubviews() {
            super.layoutSubviews()
            canvas.frame = bounds
        }
    }

    // MARK: - Coordinator（delegate + toolPicker 强引用 + drawing 回写）

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        /// 用户每画一笔：把 canvas 的最新 drawing 写回父 @State（防 tab 切换丢笔画）。
        func canvasViewDrawingDidChange(_ view: PKCanvasView) {
            if view.drawing != drawing.wrappedValue {
                drawing.wrappedValue = view.drawing
            }
        }
    }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> Container {
        let container = Container()
        let canvas = container.canvas
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        // PKToolPicker 三件套（漏任一项工具栏不出现）。
        context.coordinator.toolPicker.addObserver(canvas)
        context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        let canvas = container.canvas
        // SwiftUI 重建 representable 时同步最新 binding（父 @State 不变，binding 实例可能换）。
        context.coordinator.drawing = $drawing
        // 仅外部值变化时灌入 canvas，避免与 delegate 回写形成回环。
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    static func dismantleUIView(_ container: Container, coordinator: Coordinator) {
        coordinator.toolPicker.removeObserver(container.canvas)
        coordinator.toolPicker.setVisible(false, forFirstResponder: container.canvas)
    }
}
