# P0：重转/润色接入免费档计量

## 架构事实（探查结论）
- 网关是**纯凭证签发器**，唯一计量点 = `/v1/issue` 签发（LLM 桶固定 120s/次、ASR 桶实耗）；客户端拿 token 后**直连阿里**，音频流/LLM 调用网关不可见。
- `FreeTrialQuota` 是**本地 UX 镜像**（对齐 LLM 桶），权威在网关 QuotaDO；`incrementUsed` 仅 UX，下次签发被服务端 `remaining_seconds` 纠偏。
- 纪要管线计量范式（基线）：`MinutesPipelineSmoke.ensureCanRun()` 闸门（缓存空则 `ensureFresh(force:true)` 强刷=触发签发/403）-> 成功后 `FreeTrialQuota.incrementUsed()`。
- ASR 与 LLM 是网关侧**独立桶**；`FreeTrialQuota` 只有一个 LLM 桶计数器。

## 漏洞定位
| 路径 | 现状 | 问题 |
|---|---|---|
| 手动润色 `performPolish`（MeetingSession.swift:1108） | 无闸门、不调 ensureFresh、纯读缓存、无 incrementUsed | 缓存有效白嫖 LLM、缓存过期静默失败、**从不触发签发 = 最大漏洞** |
| 手动重转 `performRetranscribe`（:556） | 每 chunk `ensureFresh(usage:.asr, force:false)`（缓存过期才扣 ASR 桶），无入口闸门 | 缓存空时 resolve/prepare 抛 notReady 当普通"重转失败"；403 当普通"重转失败" |
| 方言自动重转 `maybeDialectRetranscribe`（:641） | Pro-only `try? ensureFresh()`（usage 误用 .llm），免费档无预热 | 免费档基本静默降级；403 当"方言重转失败" |

## 设计（客户端 P0，对齐纪要基线）

### 1. 共享助手（MeetingSession）
```swift
/// 托管档重转前确保 ASR token 就绪：缓存空则强刷（触发网关 ASR 桶扣减/403）；BYOK 跳过。
/// 返回 nil=就绪；非 nil=面向用户的失败文案。
private func ensureASRTokenForRetranscribe() async -> String? {
    guard RecapCredentialProvider.shared.isActiveCloud else { return nil }      // BYOK 跳过
    if (try? RecapCredentialProvider.shared.current()) != nil { return nil }   // 缓存有效->复用（同今）
    do {
        try await RecapCredentialProvider.shared.ensureFresh(usage: .asr, force: true)
        return nil
    } catch {
        return Self.quotaFailureMessage(error)
    }
}

private static func quotaFailureMessage(_ error: Error) -> String {
    if case let RecapCredentialError.issueFailed(status, _) = error, status == 403 {
        return "免费额度已用完，升级 Pro 或解锁自备密钥后再试"
    }
    return "凭证准备失败，请检查网络后重试"
}
```

### 2. 润色闸门 + 计量（performPolish，:1108）
- source guard 后、`do` 前：
  ```swift
  let gate = await MinutesPipelineSmoke.ensureCanRun()
  guard gate.available else { statusMessage = gate.message ?? "原稿优化不可用"; return }
  ```
- 成功落盘后（`checkpointSaver?()` 之后）：`if AIServiceMode.current == .freeTrial { FreeTrialQuota.incrementUsed() }`（与 commitAISummary:986 一致）。
- 闸门安全：`ensureCanRun` 用 `makeCurrent()`，与 `makeDefaultDeepSeek()` 跨档同源（非 BYOK 完全相同；BYOK 各分支一致）。Pro 缓存过期进 recapCloud 分支给文案（同纪要基线，非回归）。

### 3. 手动重转入口闸门 + 403 文案（performRetranscribe，:556）
- audio guard 后、`statusMessage="重转中…"` 前：
  ```swift
  if let msg = await ensureASRTokenForRetranscribe() { statusMessage = msg; return }
  ```
- catch 加 403 分支（generic catch 之前）：
  ```swift
  } catch RecapCredentialError.issueFailed(let status, _) where status == 403 {
      statusMessage = "免费额度已用完，升级 Pro 或解锁自备密钥后再试"
  }
  ```
- **不**调 `incrementUsed`：ASR 走网关独立桶，`FreeTrialQuota` 是 LLM 桶，语义不符。

### 4. 方言自动重转 403 静默降级（maybeDialectRetranscribe，:641）
- catch 加 403 分支（自动路径，静默保留原转写，不打扰）：
  ```swift
  } catch RecapCredentialError.issueFailed(let status, _) where status == 403 {
      RecapLog.session.info("dialect-retranscribe: 免费额度耗尽，保留原转写")
  }
  ```
- 不改 Pro-only 预热（避免扩大范围；其 usage 误用 .llm 是既有 bug，列入后续）。

## 不在本次范围（架构性残留，需网关侧改动）
- **跨桶 token 复用**：asr 签发的 token 可被 LLM 复用（`current()` 无差别读缓存），LLM 调用不扣 LLM 桶。纪要管线同样有此问题（即基线）。彻底封死需客户端按 usage 分桶缓存，或网关签发用途隔离 token。
- **首次 ASR 签发扣 0**（`cloud/src/adapter/quota-do.ts:48-49`）：登录免费用户每月白嫖 1 个 30min ASR token。服务端修。
- **流量不可见**：网关只数签发不数真实音频秒/LLM token，单 token 1800s 寿命内调用量无上限。需网关代理层。
- **方言预热 usage 误用 .llm**：既有 bug，后续修。

## 验证
- 模拟器构建通过（仅改 MeetingSession.swift，无新文件）。
- 手动回归（免费档）：
  - 额度充足：手动润色 -> 触发 LLM 签发、本地计数 +1；手动重转 -> 缓存空时触发 ASR 签发。
  - 额度耗尽（mock 403）：手动润色 -> "免费额度已用完…"；手动重转 -> "免费额度已用完…"；方言自动重转 -> 静默保留原转写。
  - BYOK：润色/重转不受配额闸门影响（`isActiveCloud=false` 跳过 ASR 闸门；`ensureCanRun` BYOK 走 key 检查）。
