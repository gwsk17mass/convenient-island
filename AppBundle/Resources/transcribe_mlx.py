#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


def read_wav_mono(path: Path):
    import numpy as np
    from scipy.io import wavfile

    sample_rate, audio = wavfile.read(path)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if audio.dtype == np.int16:
        audio = audio.astype(np.float32) / 32768.0
    else:
        audio = audio.astype(np.float32)
        peak = np.max(np.abs(audio)) or 1.0
        if peak > 1.0:
            audio = audio / peak
    if sample_rate != 16000:
        raise ValueError(f"Expected 16000 Hz WAV, got {sample_rate}")
    return audio, sample_rate


def fmt_time(seconds):
    seconds = max(0, float(seconds))
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millis = int(round((seconds - int(seconds)) * 1000))
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def write_outputs(result, output_prefix: Path):
    output_prefix.parent.mkdir(parents=True, exist_ok=True)
    output_prefix.with_suffix(".json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    txt_lines = []
    md_lines = ["# Транскрибация", ""]
    srt_lines = []
    for index, segment in enumerate(result.get("segments", []), start=1):
        start = fmt_time(segment.get("start", 0))
        end = fmt_time(segment.get("end", 0))
        text = (segment.get("text") or "").strip()
        if not text:
            continue
        txt_lines.append(f"[{start} - {end}] {text}")
        md_lines.extend([f"**[{start} - {end}]** {text}", ""])
        srt_lines.extend([str(index), f'{start.replace(".", ",")} --> {end.replace(".", ",")}', text, ""])
    output_prefix.with_suffix(".txt").write_text("\n".join(txt_lines) + "\n", encoding="utf-8")
    output_prefix.with_suffix(".md").write_text("\n".join(md_lines).rstrip() + "\n", encoding="utf-8")
    output_prefix.with_suffix(".srt").write_text("\n".join(srt_lines), encoding="utf-8")


def transcribe(audio, sample_rate, args):
    import mlx_whisper

    chunk_samples = int(args.chunk_seconds * sample_rate) if args.chunk_seconds else len(audio)
    segments = []
    text_parts = []
    previous_tail = ""
    total_chunks = max(1, (len(audio) + chunk_samples - 1) // chunk_samples)
    for chunk_index, start_sample in enumerate(range(0, len(audio), chunk_samples), start=1):
        end_sample = min(len(audio), start_sample + chunk_samples)
        offset = start_sample / sample_rate
        print(f"Chunk {chunk_index}/{total_chunks}", file=sys.stderr, flush=True)
        prompt = previous_tail or None
        result = mlx_whisper.transcribe(
            audio[start_sample:end_sample],
            path_or_hf_repo=args.model,
            language=args.language,
            task="transcribe",
            verbose=False,
            condition_on_previous_text=True,
            initial_prompt=prompt,
        )
        for segment in result.get("segments", []):
            adjusted = dict(segment)
            adjusted["start"] = float(adjusted.get("start", 0)) + offset
            adjusted["end"] = float(adjusted.get("end", 0)) + offset
            segments.append(adjusted)
        chunk_text = (result.get("text") or "").strip()
        if chunk_text:
            text_parts.append(chunk_text)
            previous_tail = " ".join(text_parts)[-1200:]
        partial = {
            "text": " ".join(text_parts),
            "segments": segments,
            "source_wav": str(args.wav),
            "model": args.model,
            "sample_rate": sample_rate,
            "chunks_completed": chunk_index,
            "chunks_total": total_chunks,
        }
        write_outputs(partial, args.output_prefix)
    return partial


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("wav", type=Path)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output-prefix", type=Path, required=True)
    parser.add_argument("--language", default="ru")
    parser.add_argument("--chunk-seconds", type=float, default=600)
    args = parser.parse_args()
    model_path = args.model.expanduser().resolve()
    if not model_path.is_dir() or not (model_path / "config.json").is_file() or not (model_path / "weights.safetensors").is_file():
        parser.error("--model must point to a complete local model directory")
    args.model = str(model_path)
    audio, sample_rate = read_wav_mono(args.wav)
    result = transcribe(audio, sample_rate, args)
    write_outputs(result, args.output_prefix)


if __name__ == "__main__":
    main()
