import Foundation
import SpeechEngineToB

// ─────────────────────────────────────────────────────────────────────────────
// 火山官方 SpeechEngineToB SDK 的 Swift 封装（大模型流式 ASR）。
// RECORDER 模式：SDK 自带录音（含 AEC）+ 流式识别。鉴权用新版 API Key。
// 注：SDK 用 C 风格 typedef enum，Swift 导入为全局常量（SEProtocolTypeSeed / SEDirectiveStartEngine
//     / SEAsrPartialResult 等，直接用，非 enum member）。
// ─────────────────────────────────────────────────────────────────────────────

final class VolcSpeechEngine: NSObject {
    fileprivate var engine: SpeechEngine?
    var onResult: (@Sendable (String, Bool) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onState: (@Sendable (String) -> Void)?

    func setup(appId: String, token: String, resource: String, address: String, uri: String) {
        let e = SpeechEngine()
        _ = e.createEngine(with: self)
        e.setStringParam(SE_ASR_ENGINE, forKey: SE_PARAMS_KEY_ENGINE_NAME_STRING)
        e.setStringParam(appId, forKey: SE_PARAMS_KEY_APP_ID_STRING)
        e.setStringParam(token, forKey: SE_PARAMS_KEY_APP_TOKEN_STRING)
        e.setStringParam(address, forKey: SE_PARAMS_KEY_ASR_ADDRESS_STRING)
        e.setStringParam(uri, forKey: SE_PARAMS_KEY_ASR_URI_STRING)
        e.setStringParam(resource, forKey: SE_PARAMS_KEY_RESOURCE_ID_STRING)
        e.setIntParam(Int(SEProtocolTypeSeed.rawValue), forKey: SE_PARAMS_KEY_PROTOCOL_TYPE_INT)
        e.setStringParam(SE_RECORDER_TYPE_RECORDER, forKey: SE_PARAMS_KEY_RECORDER_TYPE_STRING)
        e.setStringParam("zh-CN", forKey: SE_PARAMS_KEY_ASR_LANGUAGE_STRING)
        e.setIntParam(-1, forKey: SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT)
        e.setBoolParam(false, forKey: SE_PARAMS_KEY_ENABLE_AEC_BOOL)   // 关 AEC：实时转写不播放声音，VPIO AEC 输出空转会 render err -1 刷屏
        let ret = e.initEngine()
        engine = e
        onState?("init=\(ret)")
    }

    func start() {
        _ = engine?.send(SEDirectiveSyncStopEngine)
        _ = engine?.send(SEDirectiveStartEngine)
    }
    func stop() {
        engine?.send(SEDirectiveFinishTalking)
        engine?.send(SEDirectiveStopEngine)
    }
    func destroy() { engine?.destroy(); engine = nil }
}

extension VolcSpeechEngine: SpeechEngineDelegate {
    func onMessage(with type: SEMessageType, andData data: Data) {
        if type == SEAsrPartialResult {
            onResult?(parse(data), false)
        } else if type == SEFinalResult {
            onResult?(parse(data), true)
        } else if type == SEEngineError {
            onError?(String(data: data, encoding: .utf8) ?? "error")
        } else if type == SEEngineStart {
            onState?("引擎启动")
        } else if type == SEConnectionConnected {
            onState?("已连接")
        } else if type == SEEngineStop {
            onState?("已停止")
        } else {
            // 输出未识别 type 的数据（错误 type 等），便于排错
            let body = String(data: data, encoding: .utf8) ?? ""
            if !body.isEmpty { onError?("\(String(describing: type)): \(body)") }
        }
    }

    private func parse(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = o["result"] as? [String: Any] else { return "" }
        return r["text"] as? String ?? ""
    }
}
