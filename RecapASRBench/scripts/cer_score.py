#!/usr/bin/env python3
"""
RecapASRBench —— 批量字错率(CER)计算脚本（可选，App 内置 CERScorer 已能算；此脚本供在 Mac 上对导出的文本批量评测）。

用法：
  pip install jiwer
  python cer_score.py --hyp 引擎输出.txt --ref 人工标注.txt

输出：CER 及 S/D/I 分项（便于诊断是漏字 del 多 还是 多插 ins 多）。
"""
import argparse
from jiwer import cer, process_words


def read_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        return [l.strip() for l in f if l.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hyp", required=True, help="识别结果文件，每行一句")
    ap.add_argument("--ref", required=True, help="人工标注文件，每行一句，与 hyp 行对齐")
    args = ap.parse_args()

    hyp = read_lines(args.hyp)
    ref = read_lines(args.ref)
    assert len(hyp) == len(ref), f"行数不一致 hyp={len(hyp)} ref={len(ref)}"

    # 中文按字（不做分词），jiwer 默认按字处理中文是逐字符的
    measures = process_words(reference=ref, hypothesis=hyp)
    print(f"样本数   : {len(ref)}")
    print(f"CER      : {measures.cer * 100:.2f}%")
    print(f"替换 sub : {measures.substitutions}")
    print(f"删除 del : {measures.deletions}  (识别漏字，长音频 seam 丢字看这里)")
    print(f"插入 ins : {measures.insertions}  (识别多插，粘词看这里)")


if __name__ == "__main__":
    main()
