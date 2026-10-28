#!/usr/bin/env python3
"""Synthesize Burrow "Night Light" sounds: soft wooden marimba taps.

    python3 scripts/gen_burrow_sounds.py

Writes Sources/CodeIsland/Resources/burrow_*.wav (44.1 kHz, 16-bit mono).
Pure standard library, so the sounds can be re-tuned and regenerated
anywhere. Design notes:
- A marimba bar: fundamental plus its strong 4th-ish partial (×3.93) and a
  faint ×9.8 overtone, each decaying faster the higher it is.
- A 3 ms filtered click on the attack is the mallet touching wood.
- Everything is quiet (peak −9 dBFS) and short (≈1 s, mostly decay): the island is a
  night light, not an alarm.
"""
import math
import pathlib
import random
import struct
import wave

RATE = 44100
OUT = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "CodeIsland" / "Resources"
random.seed(7)


# Each agent has its own voice: the same phrases, transposed so that several
# agents sounding together still form a chord (root, major third, fifth,
# sixth). Claude keeps the base files (burrow_<sound>.wav); the others get
# burrow_<sound>_<voice>.wav, picked by SoundManager from the session source.
VOICES = {"": 0, "codex": 4, "opencode": 7, "antigravity": 9}
TRANSPOSE = 0


def note_hz(name: str) -> float:
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    pitch, octave = name[:-1], int(name[-1])
    semis = names[pitch] + (octave - 4) * 12 - 9 + TRANSPOSE
    return 440.0 * 2 ** (semis / 12)


def bar(buf, start: float, hz: float, gain: float, decay: float = 0.28, detune: float = 0.0):
    """Add one struck bar to buf (list of floats) at `start` seconds."""
    partials = [(1.0, 1.0, decay), (3.93, 0.22, decay * 0.35), (9.8, 0.05, decay * 0.12)]
    s0 = int(start * RATE)
    length = int(decay * 3 * RATE)
    for i in range(length):
        t = i / RATE
        v = 0.0
        for ratio, amp, d in partials:
            f = hz * ratio
            v += amp * math.exp(-t / d) * math.sin(2 * math.pi * f * t)
            if detune:
                v += amp * 0.5 * math.exp(-t / d) * math.sin(2 * math.pi * f * (1 + detune) * t)
        # Soft attack (1.5 ms) so it doesn't click hard.
        v *= min(1.0, t / 0.0015)
        # Mallet: a few ms of high-passed noise.
        if t < 0.004:
            v += 0.18 * (random.random() * 2 - 1) * (1 - t / 0.004)
        j = s0 + i
        while j >= len(buf):
            buf.append(0.0)
        buf[j] += gain * v


VOICE = ""


def write(name: str, buf):
    peak = max(1e-9, max(abs(x) for x in buf))
    target = 10 ** (-9 / 20)  # −9 dBFS
    scale = target / peak
    # 20 ms fade at the very end.
    fade = int(0.02 * RATE)
    frames = bytearray()
    for i, x in enumerate(buf):
        if i > len(buf) - fade:
            x *= (len(buf) - i) / fade
        frames += struct.pack("<h", int(max(-1, min(1, x * scale)) * 32767))
    path = OUT / (f"burrow_{name}_{VOICE}.wav" if VOICE else f"burrow_{name}.wav")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    print(f"wrote {path.name} ({len(buf) / RATE:.2f}s)")


def main():
    # Boot: the burrow wakes — three rising bars, unhurried.
    b = []
    for k, n in enumerate(["C5", "E5", "G5"]):
        bar(b, k * 0.11, note_hz(n), 0.8 - k * 0.1)
    write("boot", b)

    # Start: a pet stirs — one low, soft tap.
    b = []
    bar(b, 0, note_hz("G4"), 0.7, decay=0.22)
    write("start", b)

    # Submit: you sent something — a short, light tick.
    b = []
    bar(b, 0, note_hz("C6"), 0.5, decay=0.09)
    write("submit", b)

    # Approval: knock-knock, rising — someone at the door, not an alarm.
    b = []
    bar(b, 0.00, note_hz("E5"), 0.8, decay=0.18)
    bar(b, 0.13, note_hz("A5"), 0.9, decay=0.24)
    write("approval", b)

    # Complete: a little arpeggio that lands on the octave.
    b = []
    for k, n in enumerate(["C5", "E5", "G5", "C6"]):
        bar(b, k * 0.075, note_hz(n), 0.75 if k < 3 else 0.9, decay=0.2 if k < 3 else 0.42)
    write("complete", b)

    # Error: a falling fourth, a little out of tune — "oops", not a siren.
    b = []
    bar(b, 0.00, note_hz("A4"), 0.8, decay=0.16, detune=0.012)
    bar(b, 0.15, note_hz("E4"), 0.8, decay=0.26, detune=0.012)
    write("error", b)


if __name__ == "__main__":
    for VOICE, TRANSPOSE in VOICES.items():
        random.seed(7)
        main()
