#!/usr/bin/env python3
"""Fill missing JSONL transcripts with a Roman-Hinglish Whisper teacher."""

import argparse
import json
from pathlib import Path

import torch
from transformers import pipeline


def rows(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not row.get("audio"):
                raise ValueError(f"{path}:{line_number}: missing audio")
            yield row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--teacher", default="Oriserve/Whisper-Hindi2Hinglish-Apex")
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--overwrite-human", action="store_true")
    args = parser.parse_args()

    dtype = torch.float16 if torch.cuda.is_available() else torch.float32
    teacher = pipeline(
        "automatic-speech-recognition",
        model=args.teacher,
        torch_dtype=dtype,
        device_map="auto",
        chunk_length_s=30,
    )
    source = list(rows(args.input))
    pending = [r for r in source if args.overwrite_human or not r.get("text", "").strip()]
    audio = [r["audio"] for r in pending]
    predictions = teacher(
        audio,
        batch_size=args.batch_size,
        generate_kwargs={"task": "transcribe", "language": "hi"},
    ) if audio else []
    for row, prediction in zip(pending, predictions):
        row["text"] = prediction["text"].strip()
        row["source"] = "teacher"
        row["teacher"] = args.teacher

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in source:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"wrote {len(source)} rows ({len(pending)} teacher labels) to {args.output}")


if __name__ == "__main__":
    main()

