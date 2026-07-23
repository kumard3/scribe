#!/usr/bin/env python3
"""Report overall and per-accent WER plus Roman-script consistency."""

import argparse
import json
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer
import torch
from transformers import pipeline


def roman_rate(text: str) -> float:
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 1.0
    latin = sum("LATIN" in unicodedata.name(c, "") for c in letters)
    return latin / len(letters)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("model")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--batch-size", type=int, default=8)
    args = parser.parse_args()

    with args.manifest.open(encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    dtype = torch.float16 if torch.cuda.is_available() else torch.float32
    recognizer = pipeline(
        "automatic-speech-recognition", model=args.model, torch_dtype=dtype,
        device_map="auto", chunk_length_s=30,
    )
    outputs = recognizer(
        [row["audio"] for row in rows], batch_size=args.batch_size,
        generate_kwargs={"task": "transcribe", "language": "hi"},
    )
    groups = defaultdict(lambda: {"references": [], "predictions": []})
    details = []
    for row, output in zip(rows, outputs):
        prediction = output["text"].strip()
        accent = row.get("accent", "unknown")
        groups[accent]["references"].append(row["text"])
        groups[accent]["predictions"].append(prediction)
        details.append({"audio": row["audio"], "accent": accent,
                        "reference": row["text"], "prediction": prediction,
                        "roman_rate": roman_rate(prediction)})
    references = [item["reference"] for item in details]
    predictions = [item["prediction"] for item in details]
    report = {
        "wer": jiwer.wer(references, predictions),
        "cer": jiwer.cer(references, predictions),
        "roman_rate": sum(item["roman_rate"] for item in details) / max(1, len(details)),
        "by_accent": {
            name: {"count": len(value["references"]),
                   "wer": jiwer.wer(value["references"], value["predictions"])}
            for name, value in sorted(groups.items())
        },
        "samples": details,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "samples"}, indent=2))


if __name__ == "__main__":
    main()

