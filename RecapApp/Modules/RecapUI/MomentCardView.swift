import SwiftUI
import UIKit
import RecapModels
import RecapASR

// MARK: - 时间轴卡片

/// 会议「时刻」卡片：在 REVIEW 逐字稿时间轴上按 `startSeconds` 插队显示。
/// 点击卡片打开图库；点击时间戳胶囊跳音频回听到该秒。
struct MomentCardView: View {
    let moment: Moment
    var onSeek: (() -> Void)?
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            // 左侧青瓷竖条：区别于 LIVE 朱砂「当前块」与回听青瓷高亮，独立标识「时刻照片」。
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.recapInk.opacity(0.55))
                .frame(width: 2)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: Spacing.md) {
                header
                photoPreview
                if let note = moment.noteText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !note.isEmpty {
                    Text(note)
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapInk.opacity(0.92))
                        .lineSpacing(Leading.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.trailing, Spacing.xl)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会议时刻，\(moment.sourceTime)，\(moment.photoCount) 张照片")
        .accessibilityHint("点按查看全屏照片")
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: RecapSymbol.camera)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            Text("现场照片")
                .font(.recapMeta.weight(.semibold))
                .foregroundStyle(Color.recapInk)

            if moment.photoCount > 1 {
                Text("\(moment.photoCount) 张")
                    .font(.recapCaption)
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.recapInk.opacity(0.12), in: Capsule())
            }

            timePill
            #if DEBUG
            ownershipDebugBadge
            #endif
            Spacer(minLength: 0)
        }
    }

    #if DEBUG
    /// 诊断角标：P=照片路径里的 meetingId 前 6 位，R=关系里的 meetingId 前 6 位。
    /// 二者本应同源；不一致（红底）= SwiftData 关系损坏。
    private var ownershipDebugBadge: some View {
        let p = MomentOwnershipDiagnostics.short6(MomentOwnershipDiagnostics.pathMeetingId(moment))
        let r = MomentOwnershipDiagnostics.short6(MomentOwnershipDiagnostics.relationMeetingId(moment))
        let bad = p != r
        return Text("P:\(p) R:\(r)")
            .font(.recapCaption)
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(bad ? Color.red.opacity(0.9) : Color.recapInk.opacity(0.30), in: Capsule())
    }
    #endif

    @ViewBuilder private var timePill: some View {
        if let onSeek {
            Button {
                onSeek()
            } label: {
                Text(moment.sourceTime)
                    .font(.recapMono)
                    .tracking(Tracking.caption)
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.recapInk.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从 \(moment.sourceTime) 回听")
        } else {
            Text(moment.sourceTime)
                .font(.recapMono)
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.recapTea.opacity(0.10), in: Capsule())
        }
    }

    @ViewBuilder private var photoPreview: some View {
        if let first = moment.photoRelativePaths.first,
           let img = MeetingMediaStore.loadUIImage(storedPath: first) {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.recapInk.opacity(0.08), lineWidth: 0.8)
                    )
                    .shadow(color: Color.recapShadow, radius: 8, x: 0, y: 3)

                if moment.photoCount > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 11, weight: .semibold))
                        Text("共 \(moment.photoCount) 张")
                            .font(.recapCaption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .padding(10)
                }
            }
        } else {
            // 占位：照片缺失
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.recapInk.opacity(0.08))
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: RecapSymbol.camera)
                            .font(.system(size: 18))
                        Text("照片文件缺失")
                            .font(.recapMeta.weight(.medium))
                    }
                    .foregroundStyle(Color.recapTea)
                )
        }
    }
}

// MARK: - 全屏图库

/// 全屏查看某 Moment 的所有照片，可左右滑动；底部可「从此刻回听」跳音频。
struct MomentGalleryView: View {
    let moment: Moment
    var onSeek: (() -> Void)?
    var onDismiss: () -> Void

    @State private var index = 0
    @State private var copiedFeedback = false
    /// 一次性解码缓存：避免 body 重算时反复读盘，并让 ZoomableImageView 的 image 引用稳定，
    /// 不致在 chromeHidden 变化触发重渲染时把缩放态误复位（见其 updateUIView 的 image 比较）。
    @State private var images: [UIImage]
    /// 放大态淡出顶/底栏，沉浸看图；回到 1× 淡回。
    @State private var chromeHidden = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(moment: Moment,
         onSeek: (() -> Void)? = nil,
         onDismiss: @escaping () -> Void) {
        self.moment = moment
        self.onSeek = onSeek
        self.onDismiss = onDismiss
        _images = State(initialValue: moment.photoRelativePaths.compactMap {
            MeetingMediaStore.loadUIImage(storedPath: $0)
        })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar.opacity(chromeHidden ? 0 : 1)

                TabView(selection: $index) {
                    ForEach(Array(images.enumerated()), id: \.offset) { offset, img in
                        ZoomableImageView(image: img) { isZoomed in
                            withAnimation(reduceMotion ? nil : .recapSoft) {
                                chromeHidden = isZoomed
                            }
                        }
                        .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                // 保底高度：OCR 文字再多也压不没图片；短 OCR 时 ideal 让图片尽量大。
                .frame(minHeight: 320, idealHeight: 460, maxHeight: .infinity)

                ocrSection.opacity(chromeHidden ? 0 : 1)
                footer.opacity(chromeHidden ? 0 : 1)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
    }

    private var topBar: some View {
        HStack {
            Text("\(index + 1) / \(images.count)")
                .font(.recapMono)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: RecapSymbol.close)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭")
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: RecapSymbol.listen)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.recapInk)
            Text("从此刻回听")
                .font(.recapBodyS.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Text(moment.sourceTime)
                .font(.recapMono)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(Color.white.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            onSeek?()
        }
        .accessibilityLabel("回听到 \(moment.sourceTime)")
    }

    /// 照片 OCR 文本（异步回填）；可一键复制。
    @ViewBuilder private var ocrSection: some View {
        if let ocr = moment.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("照片文字")
                        .font(.recapEyebrow)
                        .foregroundStyle(Color.recapInk)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = ocr
                        copiedFeedback = true
                        Haptics.notify(.success)
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedFeedback = false
                        }
                    } label: {
                        Label(copiedFeedback ? "已复制" : "复制",
                              systemImage: copiedFeedback ? RecapSymbol.check : "doc.on.doc")
                            .font(.recapMeta.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                // OCR 长文（白板 / PPT）自滚动，限高不再侵吞图片区。
                ScrollView {
                    Text(ocr)
                        .font(.recapBodyS)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            .padding(Spacing.md)
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.bottom, Spacing.md)
        }
    }
}
