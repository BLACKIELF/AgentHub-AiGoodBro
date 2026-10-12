#!/usr/bin/env python3
"""Compare every native video frame at its original timestamp; never retime inputs."""

import argparse
import csv
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction
from pathlib import Path

import numpy as np


def resolve_path(path):
    try:
        return path.resolve()
    except (OSError, RuntimeError) as error:
        raise ValueError(f"cannot resolve file {path.name}: {type(error).__name__}") from None


def same_file(left, right):
    if resolve_path(left) == resolve_path(right):
        return True
    try:
        return left.samefile(right)
    except FileNotFoundError:
        return False


def check_output_paths(outputs, inputs):
    for label, output in outputs:
        for role, source in inputs:
            if same_file(output, source):
                raise ValueError(f"{label} output must not overwrite {role} input")
    if same_file(outputs[0][1], outputs[1][1]):
        raise ValueError("JSON and CSV outputs must use different files")


def open_output(path, protected, **kwargs):
    # Open without O_TRUNC; check the actual inode before changing any bytes.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT, 0o666)
    try:
        actual = os.fstat(descriptor)
        for role, source in protected:
            try:
                original = source.stat()
            except FileNotFoundError:
                continue
            if os.path.samestat(actual, original):
                raise ValueError(f"output must not overwrite {role}")
        os.ftruncate(descriptor, 0)
        target = os.fdopen(descriptor, "w", encoding="utf-8", **kwargs)
        descriptor = None
        return target
    finally:
        if descriptor is not None:
            os.close(descriptor)


def public_error(error, paths):
    if isinstance(error, OSError) and error.strerror:
        labels = [Path(name).name for name in (error.filename, error.filename2) if name]
        return error.strerror + (": " + " -> ".join(labels) if labels else "")
    message = str(error)
    for path in sorted(set(paths), key=lambda item: len(str(item)), reverse=True):
        message = message.replace(str(path), path.name)
    return message


def probe(path):
    command = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries",
        "stream=width,height,avg_frame_rate,r_frame_rate,start_time,duration:"
        "frame=best_effort_timestamp_time:format=duration",
        "-of", "json", str(path),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        detail = result.stderr.strip().replace(str(path), path.name)
        raise ValueError(f"ffprobe failed for {path.name}: {detail or 'no diagnostic returned'}")
    data = json.loads(result.stdout)
    if not data.get("streams"):
        raise ValueError(f"no video stream: {path.name}")
    stream = data["streams"][0]
    timestamps = [float(frame["best_effort_timestamp_time"]) for frame in data.get("frames", [])]
    if not timestamps or any(not math.isfinite(t) for t in timestamps):
        raise ValueError(f"missing or invalid frame timestamps: {path.name}")
    if any(b <= a for a, b in zip(timestamps, timestamps[1:])):
        raise ValueError(f"non-increasing frame timestamps: {path.name}")
    duration = float(stream.get("duration", data.get("format", {}).get("duration", "nan")))
    if not math.isfinite(duration):
        raise ValueError(f"missing video duration: {path.name}")
    fps = Fraction(stream.get("avg_frame_rate", "0/1"))
    if fps <= 0:
        raise ValueError(f"invalid frame rate: {path.name}")
    return {
        "path": path.name, "width": int(stream["width"]), "height": int(stream["height"]),
        "fps": str(fps), "duration": duration, "frame_count": len(timestamps),
        "first_pts": timestamps[0], "last_pts": timestamps[-1], "timestamps": timestamps,
    }


def read_frame(pipe, size):
    parts = bytearray()
    while len(parts) < size:
        block = pipe.read(size - len(parts))
        if not block:
            break
        parts.extend(block)
    if not parts:
        return None
    if len(parts) != size:
        raise ValueError("decoder returned a partial RGB frame")
    return np.frombuffer(parts, dtype=np.uint8).astype(np.int16)


def load_masks(path, width, height):
    if path is None:
        return []
    masks = json.loads(path.read_text())
    if not isinstance(masks, list):
        raise ValueError("masks must be a JSON list")
    for mask in masks:
        for key in ("x", "y", "width", "height"):
            if type(mask.get(key)) is not int:
                raise ValueError(f"mask {key} must be an integer")
        x, y, w, h = [mask[key] for key in ("x", "y", "width", "height")]
        if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height:
            raise ValueError("mask rectangle lies outside the native frame")
        start, end = float(mask.get("start", "nan")), float(mask.get("end", "nan"))
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
            raise ValueError("each mask needs valid start and end seconds")
        if not isinstance(mask.get("reason"), str) or not mask["reason"].strip():
            raise ValueError("each mask needs a specific reason")
    return masks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--masks", type=Path)
    parser.add_argument("--mae-tolerance", type=float, default=0.0)
    parser.add_argument("--pixel-threshold", type=float, default=8.0)
    parser.add_argument("--motion-epsilon", type=float, default=0.05)
    parser.add_argument("--freeze-seconds", type=float, default=0.2)
    args = parser.parse_args()
    report = {
        "comparison_completed": False, "pixel_criterion_passed": False,
        "parameters": {key: value.name if isinstance(value, Path) else value for key, value in vars(args).items()},
        "scope": "Native RGB frames and original PTS; audio and viewing quality are not evaluated.",
    }
    private_paths = [value for value in vars(args).values() if isinstance(value, Path)]
    private_paths += [path.absolute() for path in private_paths]
    output, csv_path, outputs, protected = args.report, None, [], []
    outputs_checked = False
    processes, logs = [], []
    code = 2
    try:
        if args.report.suffix.lower() != ".json":
            raise ValueError("report path must have a .json suffix")
        inputs = [resolve_path(args.reference), resolve_path(args.candidate)]
        protected = list(zip(("reference", "candidate"), inputs))
        if args.masks:
            protected.append(("mask", resolve_path(args.masks)))
        output = resolve_path(args.report)
        csv_path = resolve_path(args.report.with_suffix(".csv"))
        outputs = [("JSON", output), ("CSV", csv_path)]
        private_paths += [path for _, path in protected + outputs]
        check_output_paths(outputs, protected)
        outputs_checked = True
        for name in ("ffmpeg", "ffprobe"):
            if shutil.which(name) is None:
                raise ValueError(f"required existing tool not found: {name}")
        if not 0 <= args.mae_tolerance <= 255 or not 0 <= args.pixel_threshold <= 255:
            raise ValueError("pixel tolerances must be between 0 and 255")
        if not math.isfinite(args.motion_epsilon) or args.motion_epsilon <= 0:
            raise ValueError("motion epsilon must be finite and positive")
        if not math.isfinite(args.freeze_seconds) or args.freeze_seconds <= 0:
            raise ValueError("freeze seconds must be finite and positive")
        reference, candidate = [probe(path) for path in inputs]
        report["reference"] = {key: value for key, value in reference.items() if key != "timestamps"}
        report["candidate"] = {key: value for key, value in candidate.items() if key != "timestamps"}
        equal_count = reference["frame_count"] == candidate["frame_count"]
        pts_error = max((abs(a - b) for a, b in zip(reference["timestamps"], candidate["timestamps"])), default=0)
        report["timeline_checks"] = {
            "native_dimensions_equal": (reference["width"], reference["height"]) == (candidate["width"], candidate["height"]),
            "fps_equal": reference["fps"] == candidate["fps"],
            "frame_count_equal": equal_count,
            "duration_equal": abs(reference["duration"] - candidate["duration"]) <= 1e-5,
            "all_frame_pts_equal": equal_count and pts_error <= 1e-5,
        }
        report["max_frame_pts_error_seconds"] = pts_error
        if not all(report["timeline_checks"].values()):
            raise ValueError("timeline or native geometry mismatch; inputs were not retimed or resized")
        width, height, count = reference["width"], reference["height"], reference["frame_count"]
        masks = load_masks(args.masks, width, height)
        report["masks"] = masks
        output.parent.mkdir(parents=True, exist_ok=True)
        for path in inputs:
            log = tempfile.TemporaryFile()
            logs.append(log)
            processes.append(subprocess.Popen([
                "ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-map", "0:v:0",
                "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-pix_fmt", "rgb24",
                "-f", "rawvideo", "pipe:1",
            ], stdout=subprocess.PIPE, stderr=log))
        previous = [None, None]
        max_mae, max_full_mae, max_changed, max_masked = 0.0, 0.0, 0.0, 0.0
        sum_mae, sum_full_mae, differing, pixel_failures = 0.0, 0.0, 0, 0
        freezes, freeze_start, largest = [], None, []
        fps = float(Fraction(reference["fps"]))

        def close_freeze(end_index):
            nonlocal freeze_start
            if freeze_start is None:
                return
            start = reference["timestamps"][freeze_start]
            end = reference["timestamps"][end_index] if end_index < count else reference["timestamps"][-1] + 1 / fps
            if end - start + 1e-8 >= args.freeze_seconds:
                freezes.append({"start_seconds": start, "end_seconds": end, "seconds": round(end - start, 6)})
            freeze_start = None

        csv_path.parent.mkdir(parents=True, exist_ok=True)
        check_output_paths(outputs, protected)
        with open_output(csv_path, protected + [("JSON output", output)], newline="") as target:
            writer = csv.writer(target)
            writer.writerow(["frame", "pts", "full_mae", "compared_mae", "changed_pixel_fraction", "masked_fraction", "reference_motion", "candidate_motion"])
            for index, timestamp in enumerate(reference["timestamps"]):
                frames = [read_frame(proc.stdout, width * height * 3) for proc in processes]
                if any(frame is None for frame in frames):
                    raise ValueError(f"decoder ended before expected frame {index}")
                frames = [frame.reshape(height, width, 3) for frame in frames]
                keep = np.ones((height, width), dtype=bool)
                for mask in masks:
                    if mask["start"] <= timestamp < mask["end"]:
                        keep[mask["y"]:mask["y"] + mask["height"], mask["x"]:mask["x"] + mask["width"]] = False
                if not keep.any():
                    raise ValueError(f"masks exclude the entire frame at {timestamp}")
                difference = np.abs(frames[0] - frames[1])
                full_mae = float(difference.mean())
                mae = float(difference[keep].mean())
                changed = float((difference.max(axis=2)[keep] > args.pixel_threshold).mean())
                masked = float(1 - keep.mean())
                motion = [float(np.abs(frame - old)[keep].mean()) if old is not None else 0.0 for frame, old in zip(frames, previous)]
                freeze = index > 0 and motion[1] <= args.motion_epsilon and motion[0] > args.motion_epsilon * 4
                if freeze and freeze_start is None:
                    freeze_start = index - 1
                if not freeze:
                    close_freeze(index)
                previous = frames
                max_mae, max_full_mae = max(max_mae, mae), max(max_full_mae, full_mae)
                max_changed, max_masked = max(max_changed, changed), max(max_masked, masked)
                sum_mae += mae
                sum_full_mae += full_mae
                differing += int(mae > 0)
                pixel_failures += int(mae > args.mae_tolerance)
                row = [index, timestamp, full_mae, mae, changed, masked, *motion]
                writer.writerow(row)
                if mae > 0:
                    largest.append({"frame": index, "pts": timestamp, "compared_mae": mae, "full_mae": full_mae})
                    largest.sort(key=lambda item: item["compared_mae"], reverse=True)
                    largest = largest[:30]
        close_freeze(count)
        for proc, log in zip(processes, logs):
            if read_frame(proc.stdout, width * height * 3) is not None:
                raise ValueError("decoded frame count exceeds probed frame count")
            returncode = proc.wait(timeout=30)
            if returncode:
                log.seek(0)
                raise ValueError(log.read().decode(errors="replace")[-2000:] or "ffmpeg decode failed")
        report.update({
            "comparison_completed": True, "compared_frames": count, "metrics_csv": args.report.with_suffix(".csv").name,
            "pixel_criterion_passed": pixel_failures == 0, "pixel_failing_frames": pixel_failures,
            "nonidentical_compared_frames": differing,
            "mean_full_mae": sum_full_mae / count, "max_full_frame_mae": max_full_mae,
            "mean_compared_mae": sum_mae / count, "max_compared_frame_mae": max_mae,
            "max_changed_pixel_fraction": max_changed, "max_masked_fraction": max_masked,
            "largest_differences": largest, "added_freeze_candidates": freezes,
        })
        code = 0 if pixel_failures == 0 and not freezes else 1
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        report["error"] = public_error(error, private_paths)
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            if proc.stdout:
                proc.stdout.close()
        for log in logs:
            log.close()
    report["exit_code"] = code
    # Never replace media or mask input with diagnostics, including on an error path.
    report_written = False
    if outputs_checked:
        try:
            check_output_paths(outputs, protected)
            output.parent.mkdir(parents=True, exist_ok=True)
            with open_output(output, protected + [("CSV output", csv_path)]) as target:
                target.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
            report_written = True
        except (ValueError, OSError) as error:
            code = 2
            report["error"] = public_error(error, private_paths)
    print(json.dumps({"exit_code": code, "report": args.report.name, "report_written": report_written, "compared_frames": report.get("compared_frames", 0), "added_freeze_candidates": report.get("added_freeze_candidates", []), "error": report.get("error")}, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
