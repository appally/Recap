import Foundation

/// iCloud 备份排除（只排除可再生的重资产，保留用户不可再生数据）。
///
/// 背景：录音 PCM（16k mono Float32 ≈ 230MB/小时）与端侧模型（SenseVoice 447MB /
/// SpeakerKit 说话人模型）若随 iCloud 备份上传，会迅速撑爆用户 5GB 免费配额并拖垮整机备份。
/// 三者均可再生/可在 App 内导出，故一律排除；照片/手写/SwiftData 库保留备份。
///
/// 注意：`isExcludedFromBackup` 是逐条目属性，**不会遗传**给之后新建的子文件/子目录——
/// 因此排除必须在「文件/目录已创建后」调用（幂等）。
public enum BackupExclusion {
    /// 排除单个文件/目录的 iCloud 备份。失败静默（不影响主流程）。
    public static func exclude(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// 会议录音母带：Application Support / Meetings / <id> / audio.pcm。
    public static func excludeMeetingAudio(meetingId: UUID) {
        guard let url = try? MeetingAudioStore.audioURL(meetingId: meetingId) else { return }
        exclude(url)
    }

    /// SpeakerKit 说话人模型缓存（<Documents>/huggingface/models/argmaxinc/speakerkit-coreml，可重下）。
    public static func excludeHuggingFaceCache() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        exclude(documents.appendingPathComponent("huggingface", isDirectory: true))
    }

    /// FluidAudio 端侧模型目录（Application Support/FluidAudio/Models，SenseVoice 447MB，可重下）。
    public static func excludeFluidAudioModels() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        exclude(appSupport.appendingPathComponent("FluidAudio", isDirectory: true))
    }
}
