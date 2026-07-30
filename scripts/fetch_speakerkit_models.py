#!/usr/bin/env python3
"""
拉取 SpeakerKit 说话人分离模型（pyannote CoreML）并预置进 App Bundle。

背景：SpeakerKit/ArgmaxCore 的运行期下载链对「镜像偶发返回截断体」不校验内容，
导致 coremldata.bin 损坏被当缓存复用。预置进 bundle 后首次冷启动零网络、零损坏。

仅取 PyannoteConfig 在 iOS 17+ 选定的变体（4 个 .mlmodelc，合计 ~11MB）。每个文件
下载后按 HF tree API 的 size 做完整性校验，杜绝截断文件入库。

用法：python3 scripts/fetch_speakerkit_models.py
      MIRROR=https://hf-mirror.com python3 scripts/fetch_speakerkit_models.py
"""
import json
import os
import shutil
import sys
import urllib.request

MIRROR = os.environ.get("MIRROR", "https://hf-mirror.com")
REPO = "argmaxinc/speakerkit-coreml"
API = f"{MIRROR}/api/models/{REPO}/tree/main"
RESOLVE = f"{MIRROR}/{REPO}/resolve/main"

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(os.path.dirname(_SCRIPT_DIR), "RecapApp", "App", "speakerkit-coreml")

DIRS = [
    "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc",
    "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
    "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
    "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc",
]


def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def download(url, path, expected_size):
    urllib.request.urlretrieve(url, path)
    got = os.path.getsize(path)
    if got != expected_size:
        raise RuntimeError(f"size 校验失败 {path}: 期望 {expected_size} 实际 {got}")


def main():
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST, exist_ok=True)

    for d in DIRS:
        print(f"==> 列文件 {d}")
        items = get_json(f"{API}/{d}?recursive=true")
        files = [it for it in items if it.get("type") == "file"]
        if not files:
            print(f"!! 无文件：{d}（上游仓库结构变更？请核对变体路径）", file=sys.stderr)
            sys.exit(1)
        for it in files:
            fpath = it["path"]
            size = it.get("size", 0)
            rel = fpath[len(d) + 1:]
            out = os.path.join(DEST, d, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            print(f"   ↓ {fpath} ({size}B)")
            download(f"{RESOLVE}/{fpath}", out, size)

    total = sum(os.path.getsize(os.path.join(r, f))
                for r, _, fs in os.walk(DEST) for f in fs)
    print(f"==> 完成：{DEST}（{total / 1024 / 1024:.1f}MB）")
    print("   下一步：跑 xcodegen generate 纳入工程（folder reference）")


if __name__ == "__main__":
    main()
