"""Mac App Store screenshots (2880x1800) from real UI renders: python3 compose.py <render-dir>."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 2880, 1800
BG, TEXT, DIM, BORDER = (0, 0, 0), (255, 255, 255), (154, 154, 163), (42, 42, 46)
SHOTS = [
    ("home.png", "Hold a key. Talk. It types.", "Dictation that runs on your Mac, into any app.", None),
    ("meeting-Transcript.png", "Every speaker, named.", "Record a call and get who said what.", 1320),
    ("meeting-Summary.png", "A summary when the call ends.", "Key points, decisions and action items, made on your Mac.", 980),
    ("models.png", "Pick your model.", "Apple's built-in recognizer, Whisper, Parakeet, Nemotron and more.", None),
    ("dictation.png", "Your words, spelled right.", "Add names and jargon, and set the keys you like.", None),
]


def font(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_axes([100, 28 if size > 80 else 17, 400, weight])
    return f


def compose(ui_path, title, sub, crop, out):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    for text, f, color, y in ((title, font(118, 700), TEXT, 150), (sub, font(52, 400), DIM, 300)):
        d.text(((W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=color)
    ui = Image.open(ui_path).convert("RGB")
    if crop:
        ui = ui.crop((0, 0, ui.width, crop))
    scale = min((W - 400) / ui.width, (H - 460) / ui.height)
    ui = ui.resize((round(ui.width * scale), round(ui.height * scale)), Image.LANCZOS)
    x, y = (W - ui.width) // 2, 420
    mask = Image.new("L", ui.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *ui.size), 28, fill=255)
    img.paste(ui, (x, y), mask)
    d.rounded_rectangle((x - 2, y - 2, x + ui.width + 1, y + ui.height + 1), 30, outline=BORDER, width=3)
    img.save(out)


if __name__ == "__main__":
    src, here = Path(sys.argv[1]), Path(__file__).parent
    for i, (name, title, sub, crop) in enumerate(SHOTS, 1):
        compose(src / name, title, sub, crop, here / f"{i}-{Path(name).stem.lower()}.png")
