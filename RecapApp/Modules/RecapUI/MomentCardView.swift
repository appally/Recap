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
            // 青瓷竖条：区别于 LIVE 朱砂「当前块」与回听青瓷高亮，独立标识「用户钉下的时刻」。
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.recapCeladon.opacity(0.55))
                .frame(width: 2)
                .padding(.top, 2)

            content
        }
        .padding(.vertical, Spacing.sm)
        .padding(.trailing, Spacing.xl)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                header
                Text(moment.photoCount > 1 ? "拍了 \(moment.photoCount) 张照片" : "拍下一张照片")
                    .font(.recapRaw)
                    .foregroundStyle(Color.recapTea)
                if let note = moment.noteText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !note.isEmpty {
                    Text(note)
                        .font(.recapRaw)
                        .foregroundStyle(Color.recapInk.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会议时刻，\(moment.sourceTime)，\(moment.photoCount) 张照片")
        .accessibilityHint("查看照片")
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: RecapSymbol.camera)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.recapCeladon)
            Text("此刻")
                .font(.recapSection)
                .foregroundStyle(Color.recapCeladon)
            timePill
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var timePill: some View {
        if let onSeek {
            Button {
                onSeek()
            } label: {
                Text(moment.sourceTime)
                    .font(.recapTimestamp)
                    .tracking(0.2)
                    .foregroundStyle(Color.recapCeladon)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.recapCeladon.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从 \(moment.sourceTime) 回听")
        } else {
            Text(moment.sourceTime)
                .font(.recapTimestamp)
                .foregroundStyle(Color.recapTea.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.recapTea.opacity(0.10), in: Capsule())
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let first = moment.photoRelativePaths.first,
           let img = MeetingMediaStore.loadUIImage(storedPath: first) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.recapInk.opacity(0.08), lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if moment.photoCount > 1 {
                        Text("\(moment.photoCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.recapInk.opacity(0.7), in: Capsule())
                            .padding(3)
                    }
                }
        } else {
            // 占位：照片缺失（seed 占位未生成 / 文件被清）。降级为青瓷图标块，不破坏布局。
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.recapCeladon.opacity(0.12))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: RecapSymbol.camera)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.recapCeladon.opacity(0.6))
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

    private var images: [UIImage] {
        moment.photoRelativePaths.compactMap { MeetingMediaStore.loadUIImage(storedPath: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 0)

                TabView(selection: $index) {
                    ForEach(Array(images.enumerated()), id: \.offset) { offset, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
                .frame(maxHeight: .infinity)

                Spacer(minLength: 0)

                ocrSection
                footer
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
    }

    private var topBar: some View {
        HStack {
            Text("\(index + 1) / \(images.count)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
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
                .foregroundStyle(Color.recapCeladon)
            Text("从此刻回听")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Text(moment.sourceTime)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
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
                        .font(.recapSection)
                        .foregroundStyle(Color.recapCeladon)
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                Text(ocr)
                    .font(.recapRaw)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.md)
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.bottom, Spacing.md)
        }
    }
}
