#!/usr/bin/env python3
"""Build the deterministic offline audio package for Dory's Level One ad."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PROJECT_ROOT.parents[1]
AUDIO_DIR = PROJECT_ROOT / "assets" / "audio"
SCRIPT_PATH = PROJECT_ROOT / "SCRIPT.md"
META_PATH = PROJECT_ROOT / "audio_meta.json"
REPORT_PATH = PROJECT_ROOT / "audio-cue-report.json"

MODEL_PATH = Path(
    os.environ.get(
        "DORY_KOKORO_MODEL",
        Path.home() / ".cache/hyperframes/tts/models/kokoro-v1.0.onnx",
    )
).expanduser()
VOICES_PATH = Path(
    os.environ.get(
        "DORY_KOKORO_VOICES",
        Path.home() / ".cache/hyperframes/tts/voices/voices-v1.0.bin",
    )
).expanduser()

VOICE = "af_sky"
VOICE_SPEED = 1.22
VOICE_LANGUAGE = "en-us"
MASTER_SR = 48_000
FILM_DURATION = 21.0
FILM_FRAMES = int(MASTER_SR * FILM_DURATION)
BPM = 132.0
BEAT = 60.0 / BPM

CUES = [
    {
        "id": "01",
        "start": 0.32,
        "text": "A local runtime that stops at containers?",
    },
    {
        "id": "02",
        "start": 3.18,
        "text": "That's level one.",
    },
    {
        "id": "03",
        "start": 4.55,
        "text": (
            "Dory starts with Docker and Compose—then keeps going: one-click Kubernetes, "
            "full Linux desktops, persistent servers, migration, recovery, and isolated "
            "agent sandboxes."
        ),
    },
    {
        "id": "04",
        "start": 14.28,
        "text": "All in one native Mac app. Free and open source.",
    },
    {
        "id": "05",
        "start": 17.10,
        "text": "Dory. More than containers. Your whole dev machine.",
    },
]

SFX_LIBRARY = {
    "core-thunk": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/core-thunk.wav",
    "portal-whoosh": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/portal-whoosh.wav",
    "magnet-1": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/magnet-1.wav",
    "magnet-2": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/magnet-2.wav",
    "magnet-3": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/magnet-3.wav",
    "sandbox-seal": REPO_ROOT
    / "creative/dory-0.3.2-directors-cut/assets/sandbox-seal.wav",
    "capsule-lock": REPO_ROOT
    / "creative/dory-migration-ad/assets/capsule-lock.wav",
    "bridge-whoosh": REPO_ROOT
    / "creative/dory-migration-ad/assets/bridge-whoosh.wav",
    "verify-chime": REPO_ROOT
    / "creative/dory-migration-ad/assets/verify-chime.wav",
    "logo-resolve": REPO_ROOT
    / "creative/dory-migration-ad/assets/logo-resolve.wav",
}

SFX_EVENTS = [
    {"id": "cube-land", "name": "core-thunk", "start": 0.12, "gain": 0.72},
    {"id": "level-stamp", "name": "capsule-lock", "start": 3.18, "gain": 0.46},
    {"id": "button-smack", "name": "core-thunk", "start": 4.46, "gain": 0.30},
    {"id": "level-launch", "name": "portal-whoosh", "start": 4.72, "gain": 0.42},
    {"id": "docker-compose", "name": "magnet-1", "start": 5.55, "gain": 0.40},
    {"id": "kubernetes", "name": "magnet-2", "start": 7.65, "gain": 0.42},
    {"id": "linux-desktops", "name": "magnet-3", "start": 9.10, "gain": 0.44},
    {"id": "persistent-servers", "name": "capsule-lock", "start": 10.45, "gain": 0.36},
    {"id": "migrate-recover", "name": "capsule-lock", "start": 11.75, "gain": 0.38},
    {"id": "agent-sandboxes", "name": "sandbox-seal", "start": 13.05, "gain": 0.42},
    {"id": "fold-whoosh", "name": "bridge-whoosh", "start": 14.02, "gain": 0.46},
    {"id": "fold-lock-1", "name": "magnet-1", "start": 14.10, "gain": 0.24},
    {"id": "fold-lock-2", "name": "magnet-2", "start": 14.16, "gain": 0.24},
    {"id": "fold-lock-3", "name": "magnet-3", "start": 14.22, "gain": 0.24},
    {"id": "open-source", "name": "verify-chime", "start": 16.95, "gain": 0.40},
    {"id": "brand-resolve", "name": "logo-resolve", "start": 19.80, "gain": 0.52},
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dbfs(value: float) -> float | None:
    if value <= 0.0:
        return None
    return round(20.0 * math.log10(value), 3)


def fade(audio: np.ndarray, sample_rate: int, seconds: float = 0.018) -> np.ndarray:
    result = np.asarray(audio, dtype=np.float32).copy()
    count = min(int(sample_rate * seconds), len(result) // 2)
    if count > 0:
        ramp = np.linspace(0.0, 1.0, count, dtype=np.float32)
        result[:count] *= ramp
        result[-count:] *= ramp[::-1]
    return result


def normalize_peak(audio: np.ndarray, target: float, *, raise_quiet: bool = True) -> np.ndarray:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak == 0.0:
        return np.asarray(audio, dtype=np.float32)
    if not raise_quiet and peak <= target:
        return np.asarray(audio, dtype=np.float32)
    return np.asarray(audio * (target / peak), dtype=np.float32)


def resample_linear(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    source = np.asarray(audio, dtype=np.float32)
    if source_rate == target_rate:
        return source.copy()
    if source.size == 0:
        return source.copy()
    target_length = round(len(source) * target_rate / source_rate)
    source_x = np.arange(len(source), dtype=np.float64)
    target_x = np.linspace(0.0, len(source) - 1, target_length, dtype=np.float64)
    if source.ndim == 1:
        return np.interp(target_x, source_x, source).astype(np.float32)
    channels = [np.interp(target_x, source_x, source[:, channel]) for channel in range(source.shape[1])]
    return np.column_stack(channels).astype(np.float32)


def ensure_stereo(audio: np.ndarray) -> np.ndarray:
    signal = np.asarray(audio, dtype=np.float32)
    if signal.ndim == 1:
        return np.column_stack((signal, signal)).astype(np.float32)
    if signal.shape[1] == 1:
        return np.repeat(signal, 2, axis=1).astype(np.float32)
    return signal[:, :2].astype(np.float32)


def pan_mono(audio: np.ndarray, pan: float = 0.0) -> np.ndarray:
    signal = np.asarray(audio, dtype=np.float32)
    pan = float(np.clip(pan, -1.0, 1.0))
    left = math.cos((pan + 1.0) * math.pi / 4.0)
    right = math.sin((pan + 1.0) * math.pi / 4.0)
    return np.column_stack((signal * left, signal * right)).astype(np.float32)


def add_event(track: np.ndarray, audio: np.ndarray, start: float, gain: float = 1.0) -> None:
    event = ensure_stereo(audio)
    start_frame = max(0, int(round(start * MASTER_SR)))
    if start_frame >= len(track):
        return
    end_frame = min(len(track), start_frame + len(event))
    track[start_frame:end_frame] += event[: end_frame - start_frame] * gain


def tone(
    duration: float,
    frequency_start: float,
    frequency_end: float,
    decay: float,
    *,
    phase: float = 0.0,
) -> np.ndarray:
    count = int(round(MASTER_SR * duration))
    t = np.arange(count, dtype=np.float64) / MASTER_SR
    progress = t / max(duration, 1e-6)
    frequency = frequency_start + (frequency_end - frequency_start) * progress
    angle = phase + 2.0 * math.pi * np.cumsum(frequency) / MASTER_SR
    envelope = np.exp(-decay * t)
    return (np.sin(angle) * envelope).astype(np.float32)


def shaped_noise(duration: float, seed: int, *, highpass: bool = False) -> np.ndarray:
    count = int(round(MASTER_SR * duration))
    rng = np.random.default_rng(seed)
    raw = rng.normal(0.0, 1.0, count).astype(np.float32)
    if highpass:
        smooth = np.convolve(raw, np.ones(20, dtype=np.float32) / 20.0, mode="same")
        body = raw - smooth
    else:
        body = np.convolve(raw, np.ones(42, dtype=np.float32) / 42.0, mode="same")
    t = np.linspace(0.0, 1.0, count, dtype=np.float32)
    envelope = np.maximum(np.sin(np.pi * t), 0.0) ** 1.7
    return (body * envelope).astype(np.float32)


def write_audio(path: Path, audio: np.ndarray, *, subtype: str = "PCM_24") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, np.asarray(audio, dtype=np.float32), MASTER_SR, subtype=subtype)


def validate_inputs() -> None:
    if not SCRIPT_PATH.exists():
        raise FileNotFoundError(f"Missing approved script: {SCRIPT_PATH}")
    script = SCRIPT_PATH.read_text(encoding="utf-8")
    for cue in CUES:
        if cue["text"] not in script:
            raise RuntimeError(f"Cue {cue['id']} does not exactly match SCRIPT.md")
    missing = [str(path) for path in (MODEL_PATH, VOICES_PATH) if not path.exists()]
    missing.extend(str(path) for path in SFX_LIBRARY.values() if not path.exists())
    if missing:
        raise FileNotFoundError("Missing required audio inputs:\n" + "\n".join(missing))


def generate_narration() -> tuple[np.ndarray, list[dict[str, Any]]]:
    engine = Kokoro(str(MODEL_PATH), str(VOICES_PATH))
    narration = np.zeros((FILM_FRAMES, 2), dtype=np.float32)
    report: list[dict[str, Any]] = []

    for index, cue in enumerate(CUES):
        audio, sample_rate = engine.create(
            cue["text"],
            voice=VOICE,
            speed=VOICE_SPEED,
            lang=VOICE_LANGUAGE,
            trim=True,
        )
        mono = normalize_peak(fade(np.asarray(audio, dtype=np.float32), sample_rate), 0.78)
        mono_48k = resample_linear(mono, sample_rate, MASTER_SR)
        cue_path = AUDIO_DIR / f"voice-{cue['id']}.wav"
        write_audio(cue_path, mono_48k)

        duration = len(mono_48k) / MASTER_SR
        end = cue["start"] + duration
        next_start = CUES[index + 1]["start"] if index + 1 < len(CUES) else FILM_DURATION
        gap = next_start - end
        if gap < 0.06:
            raise RuntimeError(
                f"Voice cue {cue['id']} leaves only {gap:.3f}s before the next cue/end"
            )

        add_event(narration, mono_48k, cue["start"])
        report.append(
            {
                **cue,
                "end": round(end, 3),
                "duration_s": round(duration, 3),
                "next_gap_s": round(gap, 3),
                "path": str(cue_path.relative_to(PROJECT_ROOT)),
                "sample_rate": MASTER_SR,
                "channels": 1,
                "sha256": sha256(cue_path),
            }
        )

    write_audio(AUDIO_DIR / "narration-master.wav", narration)
    return narration, report


def build_music_bed() -> np.ndarray:
    """Create an unducked 132 BPM electronic arcade bed from seeded synthesis."""
    track = np.zeros((FILM_FRAMES, 2), dtype=np.float32)
    roots = [55.0, 65.406, 73.416, 61.735]
    beat_count = math.ceil(FILM_DURATION / BEAT) + 1

    for beat_index in range(beat_count):
        start = beat_index * BEAT
        root = roots[(beat_index // 8) % len(roots)]
        beat_in_bar = beat_index % 4

        kick_gain = 0.22 if beat_in_bar == 0 else 0.14 if beat_in_bar == 2 else 0.0
        if kick_gain:
            kick = tone(0.34, 96.0, 43.0, 13.5)
            click = tone(0.055, 980.0, 240.0, 38.0)
            kick[: len(click)] += click * 0.11
            add_event(track, pan_mono(kick), start, kick_gain)

        if beat_in_bar in (1, 3):
            clap = shaped_noise(0.085, 13_200 + beat_index, highpass=True)
            add_event(track, pan_mono(clap, 0.10 if beat_in_bar == 1 else -0.10), start, 0.034)

        hat = shaped_noise(0.042, 22_400 + beat_index, highpass=True)
        add_event(
            track,
            pan_mono(hat, -0.28 if beat_index % 2 == 0 else 0.28),
            start + BEAT * 0.5,
            0.018,
        )

        bass = tone(0.31, root, root * 0.993, 7.7)
        bass += 0.13 * tone(0.31, root * 2.0, root * 1.988, 9.4, phase=0.2)
        add_event(track, pan_mono(bass, -0.05), start, 0.092)

        if beat_index % 2 == 0:
            ratio = 5.0 if beat_index % 8 == 0 else 4.0
            note = root * ratio
            pluck = tone(0.29, note, note * 1.012, 14.0)
            pluck += 0.20 * tone(0.29, note * 2.0, note * 2.01, 18.0, phase=0.25)
            add_event(track, pan_mono(pluck, 0.16), start + BEAT * 0.25, 0.052)

        if 11 <= beat_index <= 31:
            ratios = (4.0, 5.0, 6.0, 8.0)
            arp_note = root * ratios[(beat_index - 11) % len(ratios)]
            arp = tone(0.18, arp_note, arp_note * 1.008, 17.0)
            add_event(
                track,
                pan_mono(arp, -0.18 if beat_index % 2 == 0 else 0.18),
                start + BEAT * 0.72,
                0.028,
            )

    for bar_index, start in enumerate(np.arange(0.0, FILM_DURATION, BEAT * 4.0)):
        root = roots[bar_index % len(roots)]
        duration = BEAT * 4.08
        pad = tone(duration, root * 2.0, root * 2.004, 0.75)
        pad += 0.38 * tone(duration, root * 3.0, root * 3.006, 0.82, phase=0.32)
        pad += 0.20 * tone(duration, root * 4.0, root * 4.003, 0.90, phase=0.58)
        add_event(track, pan_mono(pad, -0.12 if bar_index % 2 == 0 else 0.12), start, 0.018)

    for accent_index, beat_number in enumerate((7, 11, 31, 37, 46)):
        start = beat_number * BEAT
        root = roots[(beat_number // 8) % len(roots)]
        accent = tone(0.40, root * 6.0, root * 8.0, 8.8)
        accent += 0.42 * tone(0.40, root * 8.0, root * 10.0, 10.0, phase=0.2)
        add_event(track, pan_mono(accent, -0.12 + accent_index * 0.06), start, 0.038)

    fade_in = int(0.28 * MASTER_SR)
    fade_out = int(1.00 * MASTER_SR)
    track[:fade_in] *= np.linspace(0.0, 1.0, fade_in, dtype=np.float32)[:, None]
    track[-fade_out:] *= np.linspace(1.0, 0.0, fade_out, dtype=np.float32)[:, None]
    track = normalize_peak(track, 0.24)
    write_audio(AUDIO_DIR / "music-bed.wav", track)
    return track


def load_sfx(path: Path) -> tuple[np.ndarray, float]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    stereo = ensure_stereo(audio)
    if sample_rate != MASTER_SR:
        stereo = resample_linear(stereo, sample_rate, MASTER_SR)
    return stereo, len(stereo) / MASTER_SR


def build_sfx_master() -> tuple[np.ndarray, list[dict[str, Any]]]:
    track = np.zeros((FILM_FRAMES, 2), dtype=np.float32)
    cache: dict[str, tuple[np.ndarray, float]] = {}
    report: list[dict[str, Any]] = []

    for event in SFX_EVENTS:
        name = event["name"]
        if name not in cache:
            cache[name] = load_sfx(SFX_LIBRARY[name])
        audio, duration = cache[name]
        add_event(track, audio, event["start"], event["gain"])
        report.append(
            {
                **event,
                "end": round(min(FILM_DURATION, event["start"] + duration), 3),
                "duration_s": round(duration, 3),
                "source": str(SFX_LIBRARY[name].relative_to(REPO_ROOT)),
                "source_sha256": sha256(SFX_LIBRARY[name]),
            }
        )

    track = normalize_peak(track, 0.52, raise_quiet=False)
    write_audio(AUDIO_DIR / "sfx-master.wav", track)
    return track, report


def duck_envelope(
    cues: list[dict[str, Any]], *, target: float, attack: float, release: float
) -> np.ndarray:
    envelope = np.ones(FILM_FRAMES, dtype=np.float32)
    for cue in cues:
        start = float(cue["start"])
        end = float(cue["end"])
        attack_start = max(0, int(round((start - attack) * MASTER_SR)))
        speech_start = max(0, int(round(start * MASTER_SR)))
        speech_end = min(FILM_FRAMES, int(round(end * MASTER_SR)))
        release_end = min(FILM_FRAMES, int(round((end + release) * MASTER_SR)))
        if speech_start > attack_start:
            ramp = np.linspace(1.0, target, speech_start - attack_start, endpoint=False)
            envelope[attack_start:speech_start] = np.minimum(
                envelope[attack_start:speech_start], ramp
            )
        envelope[speech_start:speech_end] = np.minimum(
            envelope[speech_start:speech_end], target
        )
        if release_end > speech_end:
            ramp = np.linspace(target, 1.0, release_end - speech_end, endpoint=False)
            envelope[speech_end:release_end] = np.minimum(
                envelope[speech_end:release_end], ramp
            )
    return envelope


def make_premaster(
    narration: np.ndarray,
    music: np.ndarray,
    sfx: np.ndarray,
    cue_report: list[dict[str, Any]],
) -> np.ndarray:
    music_duck = duck_envelope(cue_report, target=0.34, attack=0.08, release=0.16)
    sfx_duck = duck_envelope(cue_report, target=0.66, attack=0.035, release=0.09)
    mix = narration * 0.98
    mix += music * music_duck[:, None] * 0.72
    mix += sfx * sfx_duck[:, None] * 0.56

    # Gentle linked saturation trims transient crests before transparent EBU R128 normalization.
    drive = 1.08
    mix = np.tanh(mix * drive) / np.tanh(drive)
    mix = normalize_peak(mix, 0.89, raise_quiet=False)
    return np.asarray(mix, dtype=np.float32)


def ffmpeg_loudness(path: Path) -> dict[str, float | str | None]:
    command = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-i",
        str(path),
        "-af",
        "loudnorm=I=-14:TP=-1:LRA=7:print_format=json",
        "-f",
        "null",
        "-",
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=True)
    blocks = re.findall(r"\{\s*\"input_i\".*?\}", completed.stderr, flags=re.DOTALL)
    if not blocks:
        raise RuntimeError("ffmpeg loudnorm did not return its measurement JSON")
    data = json.loads(blocks[-1])
    return {
        "input_i": data.get("input_i"),
        "input_tp": data.get("input_tp"),
        "input_lra": data.get("input_lra"),
        "input_thresh": data.get("input_thresh"),
        "target_offset": data.get("target_offset"),
    }


def loudness_master(premaster: np.ndarray) -> tuple[Path, dict[str, Any], dict[str, Any]]:
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.NamedTemporaryFile(
        prefix="level-one-premaster-", suffix=".wav", dir=AUDIO_DIR, delete=False
    )
    temporary_path = Path(temporary.name)
    temporary.close()
    master_path = AUDIO_DIR / "soundtrack-master.wav"
    try:
        write_audio(temporary_path, premaster)
        before = ffmpeg_loudness(temporary_path)
        filter_value = (
            "loudnorm=I=-14:TP=-1:LRA=7:"
            f"measured_I={before['input_i']}:"
            f"measured_LRA={before['input_lra']}:"
            f"measured_TP={before['input_tp']}:"
            f"measured_thresh={before['input_thresh']}:"
            f"offset={before['target_offset']}:linear=true:print_format=summary"
        )
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(temporary_path),
            "-af",
            filter_value,
            "-ar",
            str(MASTER_SR),
            "-ac",
            "2",
            "-c:a",
            "pcm_s24le",
            str(master_path),
        ]
        subprocess.run(command, capture_output=True, text=True, check=True)
        after = ffmpeg_loudness(master_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return master_path, before, after


def measure_file(path: Path) -> dict[str, Any]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64)))) if audio.size else 0.0
    clipped = int(np.count_nonzero(np.abs(audio) >= 1.0))
    return {
        "path": str(path.relative_to(PROJECT_ROOT)),
        "duration_s": round(len(audio) / sample_rate, 6),
        "frames": len(audio),
        "sample_rate": sample_rate,
        "channels": audio.shape[1],
        "peak_linear": round(peak, 8),
        "peak_dbfs": dbfs(peak),
        "rms_dbfs": dbfs(rms),
        "clipped_samples": clipped,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def ffmpeg_version() -> str:
    result = subprocess.run(
        ["ffmpeg", "-version"], capture_output=True, text=True, check=True
    )
    return result.stdout.splitlines()[0]


def write_reports(
    cue_report: list[dict[str, Any]],
    sfx_report: list[dict[str, Any]],
    master_path: Path,
    loudness_before: dict[str, Any],
    loudness_after: dict[str, Any],
) -> None:
    audio_paths = sorted(AUDIO_DIR.glob("*.wav"))
    files = {path.name: measure_file(path) for path in audio_paths}
    master = files[master_path.name]
    if master["frames"] != FILM_FRAMES:
        raise RuntimeError(
            f"Master has {master['frames']} frames; expected exactly {FILM_FRAMES}"
        )
    if master["sample_rate"] != MASTER_SR or master["channels"] != 2:
        raise RuntimeError("Master must be 48 kHz stereo")
    if any(item["clipped_samples"] for item in files.values()):
        raise RuntimeError("At least one generated audio file contains clipped samples")

    voices = [
        {
            "id": cue["id"],
            "text": cue["text"],
            "start_s": cue["start"],
            "duration_s": cue["duration_s"],
            "end_s": cue["end"],
            "path": cue["path"],
            "words": [],
        }
        for cue in cue_report
    ]
    audio_meta = {
        "version": 1,
        "duration_s": FILM_DURATION,
        "sample_rate": MASTER_SR,
        "voice": {
            "provider": "kokoro-onnx",
            "id": VOICE,
            "language": VOICE_LANGUAGE,
            "speed": VOICE_SPEED,
            "model": MODEL_PATH.name,
            "model_sha256": sha256(MODEL_PATH),
            "voices_sha256": sha256(VOICES_PATH),
        },
        "voices": voices,
        "narration": {
            "path": "assets/audio/narration-master.wav",
            "volume": 0.98,
        },
        "bgm": {
            "path": "assets/audio/music-bed.wav",
            "mode": "deterministic-synthesis",
            "bpm": BPM,
            "duration_s": FILM_DURATION,
            "raw_unducked": True,
            "mix_volume": 0.72,
            "duck_target": 0.34,
        },
        "sfx": [
            {
                "id": item["id"],
                "name": item["name"],
                "start_s": item["start"],
                "duration_s": item["duration_s"],
                "gain": item["gain"],
                "source": item["source"],
            }
            for item in sfx_report
        ],
        "sfx_master": {
            "path": "assets/audio/sfx-master.wav",
            "mix_volume": 0.56,
            "duck_target": 0.66,
        },
        "master": {
            "path": "assets/audio/soundtrack-master.wav",
            "target_lufs_i": -14.0,
            "target_true_peak_dbfs": -1.0,
            "measured_loudness": loudness_after,
            "sha256": master["sha256"],
        },
        "total_duration_s": FILM_DURATION,
    }
    META_PATH.write_text(json.dumps(audio_meta, indent=2) + "\n", encoding="utf-8")

    report = {
        "status": "pass",
        "film_duration_s": FILM_DURATION,
        "film_frames": FILM_FRAMES,
        "voice": VOICE,
        "voice_speed": VOICE_SPEED,
        "cue_count": len(cue_report),
        "cues": cue_report,
        "music": {
            "bpm": BPM,
            "beat_s": round(BEAT, 9),
            "raw_unducked_stem": True,
            "path": "assets/audio/music-bed.wav",
        },
        "sfx_events": sfx_report,
        "loudness_before_mastering": loudness_before,
        "loudness_after_mastering": loudness_after,
        "files": files,
        "verification": {
            "master_exactly_21_seconds": master["frames"] == FILM_FRAMES,
            "master_48khz_stereo": master["sample_rate"] == MASTER_SR
            and master["channels"] == 2,
            "all_files_clip_free": all(
                item["clipped_samples"] == 0 for item in files.values()
            ),
            "script_copy_exact": True,
        },
        "generator": {
            "path": "scripts/generate_audio.py",
            "sha256": sha256(Path(__file__)),
            "ffmpeg": ffmpeg_version(),
        },
    }
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    validate_inputs()
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    narration, cue_report = generate_narration()
    music = build_music_bed()
    sfx, sfx_report = build_sfx_master()
    premaster = make_premaster(narration, music, sfx, cue_report)
    master_path, loudness_before, loudness_after = loudness_master(premaster)
    write_reports(cue_report, sfx_report, master_path, loudness_before, loudness_after)
    print(json.dumps({"status": "pass", "master": str(master_path), "cues": cue_report}, indent=2))


if __name__ == "__main__":
    main()
