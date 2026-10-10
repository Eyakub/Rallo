#!/usr/bin/env python3
"""Synthesizes Rallo's three alert chimes (0021 §6) with the standard
library, then converts them to CAF with macOS's afconvert. No third-party
audio. Re-run after changing a chime; commit the .caf files it writes.

    scripts/make-chimes.py      # writes apps/macos/Rallo/Resources/Sounds/*.caf
"""
import math
import os
import struct
import subprocess
import tempfile
import wave

RATE = 44_100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "macos", "Rallo", "Resources", "Sounds")
# Inharmonic partials (ratio, amplitude) of a small struck bell.
BELL = ((1.0, 1.0), (2.0, 0.35), (2.76, 0.25), (5.4, 0.1))
KNOCK = ((1.0, 1.0), (2.3, 0.4), (3.9, 0.15))


def tone(freq, start, length, gain, decay, partials):
    """(first sample, samples) of one decaying additive tone; 5 ms attack, so no click."""
    samples = []
    for i in range(int(length * RATE)):
        t = i / RATE
        envelope = math.exp(-decay * t) * min(1.0, t / 0.005)
        samples.append(gain * envelope * sum(a * math.sin(2 * math.pi * freq * r * t) for r, a in partials))
    return int(start * RATE), samples


def mix(length, tones):
    buffer = [0.0] * int(length * RATE)
    for start, samples in tones:
        for i, sample in enumerate(samples):
            if start + i < len(buffer):
                buffer[start + i] += sample
    peak = max(1e-9, max(abs(s) for s in buffer))
    return [s / peak * 0.8 for s in buffer]


def rallo_chime():
    """Two rising bell notes, E6 then B6."""
    return mix(1.8, [tone(1318.5, 0.0, 1.2, 1.0, 3.5, BELL), tone(1975.5, 0.18, 1.6, 0.9, 3.0, BELL)])


def bamboo_knock():
    """Three hollow knocks."""
    return mix(1.5, [tone(420, start, 0.35, 1.0, 22, KNOCK) for start in (0.0, 0.16, 0.42)])


def gentle_bell():
    """One soft A5 bell with a long tail."""
    return mix(2.6, [tone(880, 0.0, 2.6, 1.0, 1.8, BELL)])


def write_caf(name, samples):
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, os.path.join(OUT, name + ".caf")], check=True)


if __name__ == "__main__":
    for name, make in (("rallo-chime", rallo_chime), ("bamboo-knock", bamboo_knock), ("gentle-bell", gentle_bell)):
        write_caf(name, make())
        print(f"wrote {name}.caf")
