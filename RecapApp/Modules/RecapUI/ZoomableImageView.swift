import SwiftUI
import UIKit

// MARK: - ZoomableImageView

/// 全屏照片缩放视图：`UIScrollView` 承载 `UIImageView`，提供「双击切换 / 双指捏合 / 单指平移」。
///
/// 设计参照 `MermaidDiagramView`（`UIViewRepresentable` + scrollView）与 iOS Photos 风格浏览器。
///
/// 与外层 `TabView(.page)` 共存的关键在子类 `gestureRecognizerShouldBegin`：1× 时让单指 pan
/// 快速失败 → 手势干净交给 TabView 翻页；放大时 pan 归本视图做平移。这是 Apple PhotoScroller
/// 示例 / Photos 风格库的通用配方，不依赖 SwiftUI 手势仲裁，确定性高。
///
/// - 放大锚点：双击用 `zoom(to:animated:)` 指向指尖落点；捏合由 UIScrollView 内建以双指中心缩放。
/// - chrome 联动：`onZoomChanged` 在跨 1× 阈值时回调，父视图据此淡出顶/底栏（沉浸看图）。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var maxZoomScale: CGFloat = 4
    var doubleTapZoom: CGFloat = 2.5
    var onZoomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(doubleTapZoom: doubleTapZoom, onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> ZoomableScrollView {
        let zsv = ZoomableScrollView()
        zsv.delegate = context.coordinator
        zsv.minimumZoomScale = 1
        zsv.maximumZoomScale = maxZoomScale
        zsv.bouncesZoom = true
        zsv.showsHorizontalScrollIndicator = false
        zsv.showsVerticalScrollIndicator = false

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        zsv.addGestureRecognizer(doubleTap)

        zsv.configure(image: image)
        return zsv
    }

    func updateUIView(_ zsv: ZoomableScrollView, context: Context) {
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.doubleTapZoom = doubleTapZoom
        // image 引用未变则跳过：父视图用 @State 缓存图片保证引用稳定，避免重渲染时误把缩放复位。
        guard zsv.imageView.image !== image else { return }
        zsv.configure(image: image)
        zsv.setZoomScale(zsv.minimumZoomScale, animated: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var doubleTapZoom: CGFloat
        var onZoomChanged: (Bool) -> Void
        private var wasZoomed = false

        init(doubleTapZoom: CGFloat, onZoomChanged: @escaping (Bool) -> Void) {
            self.doubleTapZoom = doubleTapZoom
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomableScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomableScrollView)?.centerImageViewIfNeeded()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            // 仅跨阈值触发一次，避免缩放过程中每帧震动。
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                Haptics.impact(zoomed ? .light : .soft)
            }
            onZoomChanged(zoomed)
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let zsv = gr.view as? ZoomableScrollView,
                  let img = zsv.imageView.image, img.size.width > 0 else { return }
            if zsv.zoomScale > zsv.minimumZoomScale + 0.01 {
                zsv.setZoomScale(zsv.minimumZoomScale, animated: true)
            } else {
                // 以指尖落点为中心放大：构造该点为中心、视口缩放后的矩形交给 zoom(to:)。
                let point = gr.location(in: zsv.imageView)
                let target = zsv.minimumZoomScale * doubleTapZoom
                let width = zsv.bounds.width / target
                let height = zsv.bounds.height / target
                let rect = CGRect(x: point.x - width / 2,
                                  y: point.y - height / 2,
                                  width: width,
                                  height: height)
                zsv.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - ZoomableScrollView

/// 子类化 UIScrollView：1× aspectFit 布局 + 居中 + 让出 pan。
final class ZoomableScrollView: UIScrollView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage) {
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let img = imageView.image, img.size.width > 0 else { return }
        // 仅 1× 时重算 frame/contentSize，避免放大过程中被 layout 重置导致跳变。
        guard abs(zoomScale - minimumZoomScale) < 0.01 else { return }
        let scale = min(bounds.width / img.size.width, bounds.height / img.size.height)
        let width = img.size.width * scale
        let height = img.size.height * scale
        imageView.frame = CGRect(x: (bounds.width - width) / 2,
                                 y: (bounds.height - height) / 2,
                                 width: width,
                                 height: height)
        contentSize = imageView.frame.size
        centerImageViewIfNeeded()
    }

    /// 放大后图片小于视口某轴时用 contentInset 居中，避免贴在角落。
    func centerImageViewIfNeeded() {
        let boundsSize = bounds.size
        let content = contentSize
        let horizontalInset = max(0, (boundsSize.width - content.width) / 2)
        let verticalInset = max(0, (boundsSize.height - content.height) / 2)
        contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset,
                                    bottom: verticalInset, right: horizontalInset)
    }

    /// 关键：1× 时单指 pan 快速失败 → 手势交给外层 `TabView(.page)` 翻页；
    /// 放大时 pan 归本视图做平移。pinch / 双击是独立 recognizer，不进此分支。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if zoomScale <= minimumZoomScale + 0.01,
           gestureRecognizer is UIPanGestureRecognizer {
            return false
        }
        return true
    }
}
