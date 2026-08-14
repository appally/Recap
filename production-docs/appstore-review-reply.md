# App Review 回信草稿（回复 Resolution Center 消息）

> 使用方式：App Store Connect → 该版本的「回复」框粘贴下方英文内容，并按提示附件上传屏幕录制。
> 三个部分分别对应 4.3(a)、2.1(b)、3.1.2(c)。发送前删除方括号占位符。

---

## 英文回信全文

Hello,

Thank you for the detailed feedback. We have addressed all three items and resubmitted. Please find our response to each guideline below.

**Guideline 2.1(b) — In-App Purchases not submitted**

The three In-App Purchase products (Jiyao Pro Monthly, Jiyao Pro Yearly, and the BYOK non-consumable unlock) are now fully configured with localized metadata and review screenshots, and have been attached to the new binary submission (version 1.0, build 2). They now appear in the version's "In-App Purchases and Subscriptions" section and will be submitted together with this build.

**Guideline 3.1.2(c) — Subscription information**

- App metadata: the custom EULA (full text, also hosted at https://recap.manymind.chat/terms) is now provided via the custom license agreement field in App Store Connect, and the Privacy Policy URL (https://recap.manymind.chat/privacy) is set. Both pages are live. Links to both are also included at the end of the App Description.
- In the app: the membership screen (Settings → Membership) displays the subscription title (纪要 Pro), the duration and full price of each plan (¥25/month, ¥198/year with per-month equivalent), the auto-renewal terms (automatic renewal, charged within 24 hours before the period ends unless cancelled at least 24 hours in advance, manage or cancel in system Settings → Apple ID → Subscriptions), functional links to the Privacy Policy and Terms of Use, Restore Purchases, and Manage Subscriptions.

As requested, a screen recording is attached to this message showing: opening Settings → Membership, the subscription plans with prices and durations, the auto-renewal disclosure, and tapping the Privacy Policy and Terms of Use links which open in the browser. We have also noted this in the App Review Information notes for future submissions.

**Guideline 4.3(a) — Design / Spam**

We respectfully believe this app is not a repackaged or similar submission, and would like to clarify:

1. Entirely original codebase. This app was developed from scratch by a single developer over [X months]. The repository (private) contains [170+] Swift source files with a continuous commit history from this account. No app template was purchased or used; the only third-party components are mainstream, officially licensed SDKs declared as Swift Package dependencies (Argmax SpeakerKit for on-device speaker diarization, FluidAudio for on-device speech recognition, OpenAI Swift SDK).
2. Distinctive functionality not found in combination elsewhere:
   - Cross-meeting voiceprint speaker identity: on-device speaker embeddings let the app recognize the same voice across different meetings, so names in minutes stay consistent — all local, opt-in biometric consent.
   - In-meeting photo capture with OCR time-anchored into the minutes (whiteboards, slides).
   - Apple Pencil handwriting recognized on-device (Vision OCR) and merged into the minutes.
   - Dialect confidence detection that automatically re-transcribes via a cloud engine when on-device confidence indicates a regional dialect.
   - Fully offline on-device transcription (Apple SpeechAnalyzer / SenseVoice) on supported devices.
   - A 23-template minutes system plus an agent with human-in-the-loop approvals.
3. Metadata cleanup: in this resubmission we have also removed any keyword or promotional wording that could create similarity confusion (including a competitor brand name previously present in keywords and an inaccurate mention of a third-party calendar service), and revised the description to lead with the app's unique capabilities.

We would be glad to provide further evidence of original development (commit history, design documents) if helpful. If anything remains unclear, we would appreciate the opportunity to discuss with the review team by phone.

Thank you for your time and consideration.

Best regards,
[开发者姓名]
[支持邮箱: support@manymind.chat]

---

## 需随信附上的录屏（3.1.2(c) 硬要求）

1. 打开 App → 设置 → 会员。
2. 停留展示两个订阅方案（名称/周期/价格/每月折算）约 2 秒。
3. 滚动展示自动续订说明文字与「用户协议 · 隐私政策 · 支持」链接。
4. 点击「隐私政策」→ Safari 打开 recap.manymind.chat/privacy。
5. 返回 App，点击「用户协议」→ 打开 /terms。
6. 录屏时长 20–40 秒即可，直接作为附件添加到 Resolution Center 回复。

## 占位符待填

- [X months]：实际开发时长（如 "the past 10 months"）。
- [170+]：Swift 文件数（可写 "over 170 Swift files"）。
- [开发者姓名] / 联系方式。

## 若复审仍以 4.3(a) 拒绝的升级路径

1. 预约审核团队电话：[Contact Us](https://developer.apple.com/contact/topic/) → App Review → Request a call（4.3 争议电话沟通成功率显著高于纯文字）。
2. 电话要点：原创开发证据（git 历史/设计文档）、独有功能演示（声纹/手写/拍照/方言）、愿意按建议调整元数据。
3. 最后手段才考虑调整应用名或提申诉（appeal to the App Review Board）。
