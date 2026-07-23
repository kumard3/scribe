# Hinglish on-device distillation

This pipeline produces a small multilingual Whisper student for Scribe. Training
runs on a GPU workstation, but the exported Q5 model runs entirely on-device
through Scribe's private `whisper.cpp` helper. No recording is sent to a server.

The current `Apex Q5 · Hinglish` download is a 574 MB turbo model and is the
quality baseline. It measured about 907 MB peak physical footprint by itself on
an M3 Pro, so it has too little margin to be the permanent all-device answer.
The production target is a Q5 Whisper-small student with these release gates:

- Scribe plus worker peak physical footprint: **under 900 MB** (hard ceiling 1 GB)
- 60 seconds of audio: **under 60 seconds** on the oldest supported Apple device
- Roman-script rate: **at least 99%** for Hindi/Hinglish output
- Hinglish WER no more than 10% relative worse than the Apex teacher
- No accent group more than 20% relative worse than the overall WER

## Data contract

Create UTF-8 JSONL manifests. Each line must contain an audio path and should
include accent/source metadata so evaluation cannot hide a weak accent group:

```json
{"audio":"/data/clip.wav","text":"main kal office aaunga","split":"train","accent":"Delhi","source":"human"}
```

Use only data whose license permits training and redistribution of the resulting
weights. Keep speakers disjoint across train, validation, and test. Put clean,
noisy, far-field, male/female, and code-switch-heavy clips in every accent group.
Human transcripts always win; teacher output only fills a missing `text` field.

## Run

```bash
cd training/hinglish-distillation
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 1. Generate Roman-Hinglish sequence targets with the strong teacher.
python pseudo_label.py data/train.jsonl data/train.distilled.jsonl \
  --teacher Oriserve/Whisper-Hindi2Hinglish-Apex

# 2. Fine-tune the much smaller multilingual Whisper student.
accelerate launch train_student.py \
  --train data/train.distilled.jsonl --validation data/validation.jsonl \
  --output artifacts/hinglish-whisper-small

# 3. Evaluate the HF checkpoint by accent and script consistency.
python evaluate_student.py data/test.jsonl artifacts/hinglish-whisper-small \
  --output artifacts/evaluation.json

# 4. Convert and quantize for Scribe.
WHISPER_CPP=/path/to/whisper.cpp OPENAI_WHISPER=/path/to/openai-whisper \
  ./export-q5.sh artifacts/hinglish-whisper-small artifacts/export
```

This is sequence-level knowledge distillation: the 0.8B Apex teacher supplies
targets, then the 242M Whisper-small student learns those targets together with
human labels. Before release, review the teacher/student disagreement set and
the worst 100 samples for every accent. A filter cannot learn an accent; this
balanced training and evaluation loop is the part that does.

