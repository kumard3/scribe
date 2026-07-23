#!/usr/bin/env python3
"""Sequence-level distillation into multilingual Whisper-small."""

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Union

import evaluate
import torch
from datasets import Audio, Dataset
from transformers import (
    Seq2SeqTrainer,
    Seq2SeqTrainingArguments,
    WhisperForConditionalGeneration,
    WhisperProcessor,
)


def load_manifest(path: Path) -> Dataset:
    with path.open(encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    invalid = [i for i, row in enumerate(rows) if not row.get("audio") or not row.get("text")]
    if invalid:
        raise ValueError(f"{path}: rows without audio/text: {invalid[:10]}")
    return Dataset.from_list(rows).cast_column("audio", Audio(sampling_rate=16_000))


@dataclass
class SpeechCollator:
    processor: Any
    decoder_start_token_id: int

    def __call__(self, features: List[Dict[str, Union[List[int], torch.Tensor]]]):
        inputs = [{"input_features": item["input_features"]} for item in features]
        batch = self.processor.feature_extractor.pad(inputs, return_tensors="pt")
        labels = self.processor.tokenizer.pad(
            [{"input_ids": item["labels"]} for item in features], return_tensors="pt"
        )
        label_ids = labels["input_ids"].masked_fill(labels.attention_mask.ne(1), -100)
        if (label_ids[:, 0] == self.decoder_start_token_id).all().cpu().item():
            label_ids = label_ids[:, 1:]
        batch["labels"] = label_ids
        return batch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--train", required=True, type=Path)
    parser.add_argument("--validation", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--student", default="openai/whisper-small")
    parser.add_argument("--epochs", type=float, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--gradient-accumulation", type=int, default=2)
    parser.add_argument("--learning-rate", type=float, default=1e-5)
    args = parser.parse_args()

    processor = WhisperProcessor.from_pretrained(args.student, language="hi", task="transcribe")
    model = WhisperForConditionalGeneration.from_pretrained(args.student)
    model.generation_config.language = "hi"
    model.generation_config.task = "transcribe"
    model.generation_config.forced_decoder_ids = None

    def prepare(row):
        audio = row["audio"]
        row["input_features"] = processor.feature_extractor(
            audio["array"], sampling_rate=audio["sampling_rate"]
        ).input_features[0]
        row["labels"] = processor.tokenizer(row["text"]).input_ids
        return row

    train_source = load_manifest(args.train)
    train = train_source.map(prepare, remove_columns=train_source.column_names)
    validation_source = load_manifest(args.validation)
    validation = validation_source.map(prepare, remove_columns=validation_source.column_names)
    metric = evaluate.load("wer")

    def metrics(prediction):
        predicted = prediction.predictions
        labels = prediction.label_ids
        labels[labels == -100] = processor.tokenizer.pad_token_id
        return {"wer": 100 * metric.compute(
            predictions=processor.tokenizer.batch_decode(predicted, skip_special_tokens=True),
            references=processor.tokenizer.batch_decode(labels, skip_special_tokens=True),
        )}

    training = Seq2SeqTrainingArguments(
        output_dir=str(args.output),
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size,
        gradient_accumulation_steps=args.gradient_accumulation,
        learning_rate=args.learning_rate,
        num_train_epochs=args.epochs,
        warmup_ratio=0.05,
        gradient_checkpointing=True,
        fp16=torch.cuda.is_available(),
        eval_strategy="steps",
        save_strategy="steps",
        eval_steps=500,
        save_steps=500,
        logging_steps=25,
        predict_with_generate=True,
        generation_max_length=225,
        load_best_model_at_end=True,
        metric_for_best_model="wer",
        greater_is_better=False,
        report_to="none",
    )
    trainer = Seq2SeqTrainer(
        model=model,
        args=training,
        train_dataset=train,
        eval_dataset=validation,
        data_collator=SpeechCollator(processor, model.config.decoder_start_token_id),
        compute_metrics=metrics,
        processing_class=processor,
    )
    trainer.train()
    trainer.save_model(args.output)
    processor.save_pretrained(args.output)


if __name__ == "__main__":
    main()
