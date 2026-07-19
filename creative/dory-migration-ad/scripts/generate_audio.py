#!/usr/bin/env python3
"""Generate the distinct bm_george narration and deterministic Dory migration soundscape."""

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
VOICE = "bm_george"
VOICE_SPEED = 1.02
MASTER_SR = 48_000
FILM_DURATION = 30.2


def fade(audio: np.ndarray, sample_rate: int, seconds: float = 0.018) -> np.ndarray:
    count = min(int(sample_rate * seconds), len(audio) // 2)
    if count:
        ramp = np.linspace(0.0, 1.0, count, dtype=np.float32)
        audio[:count] *= ramp
        audio[-count:] *= ramp[::-1]
    return audio


def normalize(signal: np.ndarray, peak: float) -> np.ndarray:
    current = float(np.max(np.abs(signal))) if signal.size else 0.0
    if current == 0.0:
        return signal.astype(np.float32)
    return (signal * (peak / current)).astype(np.float32)


def stereo(signal: np.ndarray, pan: float = 0.0) -> np.ndarray:
    pan = float(np.clip(pan, -1.0, 1.0))
    left = math.cos((pan + 1.0) * math.pi / 4.0)
    right = math.sin((pan + 1.0) * math.pi / 4.0)
    return np.column_stack((signal * left, signal * right)).astype(np.float32)


def resample_linear(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return audio.astype(np.float32)
    source_x = np.arange(len(audio), dtype=np.float64)
    target_len = round(len(audio) * target_rate / source_rate)
    target_x = np.linspace(0.0, max(len(audio) - 1, 0), target_len, dtype=np.float64)
    return np.interp(target_x, source_x, audio).astype(np.float32)


def tone(
    duration: float,
    frequency_start: float,
    frequency_end: float,
    decay: float,
    phase: float = 0.0,
) -> np.ndarray:
    count = int(MASTER_SR * duration)
    t = np.arange(count, dtype=np.float64) / MASTER_SR
    sweep = frequency_start + (frequency_end - frequency_start) * (t / max(duration, 1e-6))
    angle = phase + 2.0 * math.pi * np.cumsum(sweep) / MASTER_SR
    envelope = np.exp(-decay * t)
    return (np.sin(angle) * envelope).astype(np.float32)


def shaped_noise(duration: float, seed: int, reverse: bool = False) -> np.ndarray:
    count = int(MASTER_SR * duration)
    rng = np.random.default_rng(seed)
    raw = rng.normal(0.0, 1.0, count + 128).astype(np.float32)
    smooth = np.convolve(raw, np.ones(56, dtype=np.float32) / 56.0, mode="valid")[:count]
    high = raw[:count] - np.convolve(raw[:count], np.ones(10, dtype=np.float32) / 10.0, mode="same")
    t = np.linspace(0.0, 1.0, count, dtype=np.float32)
    envelope = np.maximum(np.sin(np.pi * t), 0.0) ** 1.6
    signal = (0.78 * smooth + 0.08 * high) * envelope
    return signal[::-1].copy() if reverse else signal


def mix_mono(*signals: tuple[np.ndarray, float]) -> np.ndarray:
    length = max(len(signal) for signal, _gain in signals)
    result = np.zeros(length, dtype=np.float32)
    for signal, gain in signals:
        result[: len(signal)] += signal * gain
    return result


def add_event(track: np.ndarray, event: np.ndarray, start_seconds: float, gain: float = 1.0) -> None:
    start = int(start_seconds * MASTER_SR)
    if start >= len(track):
        return
    if event.ndim == 1:
        event = stereo(event)
    end = min(start + len(event), len(track))
    track[start:end] += event[: end - start] * gain


def write_stereo(name: str, signal: np.ndarray, peak: float) -> None:
    sf.write(ASSETS / name, normalize(signal, peak), MASTER_SR, subtype="PCM_24")


def generate_narration() -> list[dict]:
    cues = json.loads(CUES_PATH.read_text())
    engine = Kokoro(str(MODEL), str(VOICES))
    narration = np.zeros((int(FILM_DURATION * MASTER_SR), 2), dtype=np.float32)
    report: list[dict] = []

    for index, cue in enumerate(cues):
        audio, sample_rate = engine.create(
            cue["text"], voice=VOICE, speed=VOICE_SPEED, lang="en-gb", trim=True
        )
        mono = np.asarray(audio, dtype=np.float32)
        mono = normalize(fade(mono, sample_rate), 0.78)
        out = ASSETS / f"voice-{cue['id']}.wav"
        sf.write(out, mono, sample_rate, subtype="PCM_24")

        master_mono = resample_linear(mono, sample_rate, MASTER_SR)
        duration = len(master_mono) / MASTER_SR
        next_start = cues[index + 1]["start"] if index + 1 < len(cues) else FILM_DURATION
        overlap = max(0.0, cue["start"] + duration + 0.06 - next_start)
        add_event(narration, stereo(master_mono), cue["start"], 1.0)
        report.append(
            {
                **cue,
                "file": out.name,
                "duration": round(duration, 3),
                "end": round(cue["start"] + duration, 3),
                "voice": VOICE,
                "speed": VOICE_SPEED,
                "next_cue_overlap": round(overlap, 3),
            }
        )

    write_stereo("narration-master.wav", narration, 0.82)
    (ROOT / "audio-cue-report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def build_effects() -> dict[str, np.ndarray]:
    effects: dict[str, np.ndarray] = {}

    impact = mix_mono(
        (tone(0.52, 104.0, 46.0, 9.5), 1.0),
        (tone(0.26, 620.0, 240.0, 15.0), 0.16),
    )
    effects["hook-impact"] = stereo(fade(impact, MASTER_SR))

    lock = tone(0.28, 560.0, 940.0, 13.0) + 0.28 * tone(0.28, 1120.0, 1540.0, 15.0)
    effects["capsule-lock"] = stereo(fade(lock, MASTER_SR))

    scan = shaped_noise(0.72, 5102) + 0.16 * tone(0.72, 190.0, 920.0, 2.2)
    effects["scan-sweep"] = stereo(fade(scan, MASTER_SR), -0.08)

    whoosh = shaped_noise(0.68, 7711) + 0.20 * tone(0.68, 150.0, 700.0, 2.4)
    effects["bridge-whoosh"] = stereo(fade(whoosh, MASTER_SR), 0.12)

    verify = tone(0.68, 620.0, 880.0, 5.2)
    verify += 0.52 * tone(0.68, 930.0, 1320.0, 5.8)
    verify += 0.22 * tone(0.68, 1240.0, 1760.0, 6.4)
    effects["verify-chime"] = stereo(fade(verify, MASTER_SR), 0.08)

    resolve = tone(1.05, 392.0, 523.25, 3.8)
    resolve += 0.56 * tone(1.05, 587.33, 783.99, 4.5)
    resolve += 0.28 * tone(1.05, 783.99, 1046.5, 5.0)
    effects["logo-resolve"] = stereo(fade(resolve, MASTER_SR))

    for name, signal in effects.items():
        write_stereo(f"{name}.wav", signal, 0.56 if name == "hook-impact" else 0.48)
    return effects


def generate_sfx_master(effects: dict[str, np.ndarray]) -> None:
    track = np.zeros((int(FILM_DURATION * MASTER_SR), 2), dtype=np.float32)
    add_event(track, effects["hook-impact"], 0.20, 0.76)
    for index, at in enumerate((5.10, 5.55, 6.00, 6.45, 6.90)):
        add_event(track, effects["capsule-lock"], at, 0.46 + index * 0.035)
    add_event(track, effects["scan-sweep"], 8.95, 0.78)
    add_event(track, effects["capsule-lock"], 11.50, 0.60)
    for index, at in enumerate((15.22, 16.02, 16.82)):
        add_event(track, effects["capsule-lock"], at, 0.54 + index * 0.05)
    add_event(track, effects["bridge-whoosh"], 19.30, 0.82)
    for index, at in enumerate((21.10, 22.45, 23.80)):
        add_event(track, effects["capsule-lock"], at, 0.58 + index * 0.04)
    add_event(track, effects["verify-chime"], 24.15, 0.68)
    add_event(track, effects["logo-resolve"], 24.82, 0.66)
    write_stereo("sfx-master.wav", track, 0.48)


def generate_music_bed(report: list[dict]) -> None:
    count = int(FILM_DURATION * MASTER_SR)
    track = np.zeros((count, 2), dtype=np.float32)
    bpm = 122.0
    beat = 60.0 / bpm
    progression = [55.0, 65.406, 73.416, 61.735]

    for beat_index, start in enumerate(np.arange(0.0, FILM_DURATION, beat)):
        phrase = (beat_index // 8) % len(progression)
        root = progression[phrase]

        if beat_index % 4 == 0:
            kick = tone(0.38, 92.0, 44.0, 13.0)
            add_event(track, stereo(kick), start, 0.22)
        if beat_index % 4 == 2:
            clap = shaped_noise(0.075, 8100 + beat_index)
            add_event(track, stereo(clap, pan=0.12), start, 0.065)
        if beat_index % 2 == 1:
            tick = shaped_noise(0.035, 9200 + beat_index)
            add_event(track, stereo(tick, pan=-0.30 if beat_index % 4 == 1 else 0.30), start, 0.028)

        bass = tone(0.32, root, root * 0.992, 7.8)
        bass += 0.14 * tone(0.32, root * 2.0, root * 1.985, 9.2)
        add_event(track, stereo(bass, pan=-0.06), start, 0.10)

        if beat_index % 2 == 0:
            interval = 5.0 if beat_index % 8 == 0 else 4.0
            pluck_frequency = root * interval
            pluck = tone(0.34, pluck_frequency, pluck_frequency * 1.014, 13.0)
            pluck += 0.22 * tone(0.34, pluck_frequency * 2.0, pluck_frequency * 2.01, 16.0)
            add_event(track, stereo(pluck, pan=0.16), start + beat * 0.5, 0.052)

    # A restrained sustained layer gives the light canvas warmth without turning cinematic.
    for bar_index, start in enumerate(np.arange(0.0, FILM_DURATION, beat * 4.0)):
        root = progression[bar_index % len(progression)]
        pad = tone(beat * 4.1, root * 2.0, root * 2.004, 0.9)
        pad += 0.46 * tone(beat * 4.1, root * 3.0, root * 3.006, 1.0, phase=0.3)
        add_event(track, stereo(pad, pan=-0.12 if bar_index % 2 == 0 else 0.12), start, 0.018)

    gain = np.ones(count, dtype=np.float32)
    for cue in report:
        start = max(0, int((cue["start"] - 0.08) * MASTER_SR))
        end = min(count, int((cue["end"] + 0.16) * MASTER_SR))
        gain[start:end] = np.minimum(gain[start:end], 0.42)
        ramp = int(0.08 * MASTER_SR)
        if start >= ramp:
            gain[start - ramp : start] = np.minimum(
                gain[start - ramp : start], np.linspace(1.0, 0.42, ramp, dtype=np.float32)
            )
        if end + ramp <= count:
            gain[end : end + ramp] = np.minimum(
                gain[end : end + ramp], np.linspace(0.42, 1.0, ramp, dtype=np.float32)
            )

    track *= gain[:, None]
    fade_in = int(0.42 * MASTER_SR)
    fade_out = int(1.4 * MASTER_SR)
    track[:fade_in] *= np.linspace(0.0, 1.0, fade_in, dtype=np.float32)[:, None]
    track[-fade_out:] *= np.linspace(1.0, 0.0, fade_out, dtype=np.float32)[:, None]
    write_stereo("music-bed.wav", track, 0.22)


def generate_premaster() -> None:
    narration, narration_rate = sf.read(ASSETS / "narration-master.wav", dtype="float32")
    music, music_rate = sf.read(ASSETS / "music-bed.wav", dtype="float32")
    effects, effects_rate = sf.read(ASSETS / "sfx-master.wav", dtype="float32")
    if {narration_rate, music_rate, effects_rate} != {MASTER_SR}:
        raise RuntimeError("premaster stems must all be 48 kHz")
    length = min(len(narration), len(music), len(effects))
    premaster = narration[:length] + music[:length] * 0.78 + effects[:length] * 0.72
    write_stereo("soundtrack-premaster.wav", premaster, 0.90)


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    report = generate_narration()
    effects = build_effects()
    generate_sfx_master(effects)
    generate_music_bed(report)
    generate_premaster()
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
