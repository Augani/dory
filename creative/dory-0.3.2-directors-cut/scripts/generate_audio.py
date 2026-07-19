#!/usr/bin/env python3
"""Generate paced Kokoro narration clips and deterministic launch-film sound cues."""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
CUES_PATH = ROOT / "narration-cues.json"
MODEL = Path.home() / ".cache/hyperframes/tts/models/kokoro-v1.0.onnx"
VOICES = Path.home() / ".cache/hyperframes/tts/voices/voices-v1.0.bin"
VOICE = "af_sky"
VOICE_SPEED = 0.96
MASTER_SR = 48_000
FILM_DURATION = 65.0


def fade(audio: np.ndarray, sample_rate: int, seconds: float = 0.018) -> np.ndarray:
    count = min(int(sample_rate * seconds), len(audio) // 2)
    if count:
        ramp = np.linspace(0.0, 1.0, count, dtype=np.float32)
        audio[:count] *= ramp
        audio[-count:] *= ramp[::-1]
    return audio


def stereo(signal: np.ndarray, pan: float = 0.0) -> np.ndarray:
    pan = float(np.clip(pan, -1.0, 1.0))
    left = math.cos((pan + 1.0) * math.pi / 4.0)
    right = math.sin((pan + 1.0) * math.pi / 4.0)
    return np.column_stack((signal * left, signal * right)).astype(np.float32)


def normalize(signal: np.ndarray, peak: float) -> np.ndarray:
    current = float(np.max(np.abs(signal))) if signal.size else 0.0
    return signal if current == 0 else (signal * (peak / current)).astype(np.float32)


def write_stereo(name: str, signal: np.ndarray, peak: float = 0.7) -> None:
    signal = normalize(signal, peak)
    sf.write(ASSETS / name, signal, MASTER_SR, subtype="PCM_24")


def tone(duration: float, frequency_start: float, frequency_end: float, decay: float, phase: float = 0.0) -> np.ndarray:
    count = int(MASTER_SR * duration)
    t = np.arange(count, dtype=np.float64) / MASTER_SR
    sweep = frequency_start + (frequency_end - frequency_start) * (t / max(duration, 1e-6))
    angle = phase + 2.0 * math.pi * np.cumsum(sweep) / MASTER_SR
    envelope = np.exp(-decay * t)
    return (np.sin(angle) * envelope).astype(np.float32)


def mix_mono(*signals: tuple[np.ndarray, float]) -> np.ndarray:
    """Mix differently sized mono signals from time zero."""
    length = max(len(signal) for signal, _gain in signals)
    result = np.zeros(length, dtype=np.float32)
    for signal, gain in signals:
        result[: len(signal)] += signal * gain
    return result


def generate_narration() -> list[dict]:
    cues = json.loads(CUES_PATH.read_text())
    engine = Kokoro(str(MODEL), str(VOICES))
    report = []
    for cue in cues:
        audio, sample_rate = engine.create(
            cue["text"], voice=VOICE, speed=VOICE_SPEED, lang="en-us", trim=True
        )
        audio = np.asarray(audio, dtype=np.float32)
        audio = fade(audio, sample_rate)
        audio = normalize(audio, 0.78)
        out = ASSETS / f"voice-{cue['id']}.wav"
        sf.write(out, audio, sample_rate, subtype="PCM_24")
        duration = len(audio) / sample_rate
        report.append({**cue, "file": out.name, "duration": round(duration, 3)})
    (ROOT / "audio-cue-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def generate_contacts() -> None:
    for index, (f0, f1, pan) in enumerate(
        [(520.0, 760.0, -0.25), (660.0, 980.0, 0.0), (820.0, 1240.0, 0.25)], start=1
    ):
        body = tone(0.42, f0, f1, 10.5)
        shimmer = 0.34 * tone(0.42, f0 * 2.02, f1 * 1.55, 13.0, phase=0.3)
        click = np.zeros_like(body)
        click[:120] = np.linspace(1.0, 0.0, 120, dtype=np.float32)
        write_stereo(f"magnet-{index}.wav", stereo(fade(body + shimmer + 0.18 * click, MASTER_SR), pan), 0.58)


def shaped_noise(duration: float, seed: int, reverse: bool = False) -> np.ndarray:
    count = int(MASTER_SR * duration)
    rng = np.random.default_rng(seed)
    raw = rng.normal(0.0, 1.0, count + 96).astype(np.float32)
    smooth = np.convolve(raw, np.ones(48, dtype=np.float32) / 48.0, mode="valid")[:count]
    high = raw[:count] - np.convolve(raw, np.ones(12, dtype=np.float32) / 12.0, mode="same")[:count]
    t = np.linspace(0.0, 1.0, count, dtype=np.float32)
    envelope = np.maximum(np.sin(np.pi * t), 0.0) ** 1.8
    signal = (0.75 * smooth + 0.12 * high) * envelope
    return signal[::-1].copy() if reverse else signal


def generate_effects() -> None:
    whoosh = shaped_noise(0.58, 3202) + 0.16 * tone(0.58, 180.0, 620.0, 2.2)
    write_stereo("portal-whoosh.wav", stereo(fade(whoosh, MASTER_SR), 0.12), 0.52)

    thunk = mix_mono(
        (tone(0.72, 112.0, 48.0, 8.0), 1.0),
        (tone(0.28, 760.0, 260.0, 15.0), 0.24),
    )
    write_stereo("core-thunk.wav", stereo(fade(thunk, MASTER_SR)), 0.62)

    seal = tone(0.52, 420.0, 210.0, 12.0) + 0.30 * tone(0.52, 920.0, 1260.0, 10.0)
    write_stereo("sandbox-seal.wav", stereo(fade(seal, MASTER_SR)), 0.48)

    rollback = shaped_noise(0.86, 7113, reverse=True) + 0.18 * tone(0.86, 260.0, 980.0, 2.8)
    write_stereo("rollback.wav", stereo(fade(rollback, MASTER_SR), -0.1), 0.48)

    delete = shaped_noise(0.62, 9231, reverse=True) + 0.25 * tone(0.62, 980.0, 160.0, 5.8)
    write_stereo("delete-pop.wav", stereo(fade(delete, MASTER_SR), 0.18), 0.5)

    lock = tone(0.82, 520.0, 760.0, 5.0) + 0.45 * tone(0.82, 780.0, 1140.0, 5.8)
    lock += 0.24 * tone(0.82, 1040.0, 1520.0, 6.6)
    write_stereo("https-lock.wav", stereo(fade(lock, MASTER_SR)), 0.48)


def add_event(track: np.ndarray, event: np.ndarray, start_seconds: float, gain: float = 1.0) -> None:
    start = int(start_seconds * MASTER_SR)
    end = min(start + len(event), len(track))
    if start < len(track):
        track[start:end] += event[: end - start] * gain


def generate_music_bed(report: list[dict]) -> None:
    count = int(FILM_DURATION * MASTER_SR)
    track = np.zeros((count, 2), dtype=np.float32)
    bpm = 118.0
    beat = 60.0 / bpm
    bass_notes = [65.406, 65.406, 77.782, 58.270]

    for beat_index, start in enumerate(np.arange(4.2, FILM_DURATION, beat)):
        if beat_index % 4 == 0:
            kick = tone(0.42, 96.0, 48.0, 13.0)
            add_event(track, stereo(kick), start, 0.28)
        if beat_index % 2 == 1:
            rim = shaped_noise(0.07, 2000 + beat_index)
            add_event(track, stereo(rim, pan=0.25 if beat_index % 4 == 1 else -0.25), start, 0.10)

        note = bass_notes[(beat_index // 4) % len(bass_notes)]
        bass = tone(0.36, note, note * 0.985, 7.0) + 0.18 * tone(0.36, note * 2.0, note * 1.97, 8.5)
        add_event(track, stereo(bass, pan=-0.08), start, 0.12)

        if beat_index % 2 == 0:
            pluck_note = note * (4.0 if beat_index % 8 else 5.0)
            pluck = tone(0.25, pluck_note, pluck_note * 1.02, 16.0)
            add_event(track, stereo(pluck, pan=0.18), start + beat * 0.5, 0.06)

    # Gentle side-chain style ducking under every spoken cue.
    gain = np.ones(count, dtype=np.float32)
    for cue in report:
        start = max(0, int((cue["start"] - 0.08) * MASTER_SR))
        end = min(count, int((cue["start"] + cue["duration"] + 0.16) * MASTER_SR))
        gain[start:end] = np.minimum(gain[start:end], 0.42)
        ramp = int(0.08 * MASTER_SR)
        if start >= ramp:
            gain[start - ramp : start] = np.minimum(gain[start - ramp : start], np.linspace(1.0, 0.42, ramp))
        if end + ramp <= count:
            gain[end : end + ramp] = np.minimum(gain[end : end + ramp], np.linspace(0.42, 1.0, ramp))

    track *= gain[:, None]
    # Fade in after the logo hook and leave a natural tail under the end card.
    fade_in = int(0.8 * MASTER_SR)
    track[int(3.8 * MASTER_SR) : int(3.8 * MASTER_SR) + fade_in] *= np.linspace(0.0, 1.0, fade_in)[:, None]
    track[: int(3.8 * MASTER_SR)] = 0.0
    fade_out = int(2.2 * MASTER_SR)
    track[-fade_out:] *= np.linspace(1.0, 0.0, fade_out)[:, None]
    write_stereo("music-bed.wav", track, 0.24)


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    report = generate_narration()
    generate_contacts()
    generate_effects()
    generate_music_bed(report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
