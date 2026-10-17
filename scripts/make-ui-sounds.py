#!/usr/bin/env python3
"""合成八个 Mulee 操作音效；需要 Python 3 和 numpy。

用法：python3 scripts/make-ui-sounds.py <输出目录>
输出为 48 kHz、16 位单声道 WAV，峰值与发布资源一致。
task_added 来自 AI 生成的固定音频，不能由此脚本重建，因此跳过。
"""
import argparse
from pathlib import Path
import wave

import numpy as np
from numpy.fft import irfft, rfft

SR = 48000
PEAK_DBFS = {
    "download_complete": -12,
    "all_complete": -12,
    "failed": -13,
    "pause": -18,
    "resume": -18,
    "delete": -20,
    "link_received": -16,
    "warning": -13,
}


def envelope(length, attack=0.004, decay=0.25, curve=4.0):
    time = np.arange(length) / SR
    return np.minimum(1, time / attack) * np.exp(-time / decay * curve / 4)


def tone(frequency, duration, attack=0.004, decay=0.25,
         harmonics=((1, 1.0), (2, 0.12), (3, 0.05)), bend=0.0):
    length = int(SR * duration)
    time = np.arange(length) / SR
    frequencies = frequency * (1 + bend * time / duration)
    phase = 2 * np.pi * np.cumsum(frequencies) / SR
    signal = sum(amplitude * np.sin(order * phase) for order, amplitude in harmonics)
    return signal * envelope(length, attack, decay)


def place(duration, parts):
    output = np.zeros(int(SR * duration))
    for start, signal in parts:
        index = int(SR * start)
        output[index:index + len(signal)] += signal[:len(output) - index]
    return output


def quantize(signal, peak_db):
    normalized = signal / (np.abs(signal).max() or 1) * 10 ** (peak_db / 20)
    return (normalized * 32767).astype("<i2")


def trim_and_fade(signal, maximum_duration):
    # 定稿候选按 10 ms 包络裁切，并对起止做淡入淡出，避免点击爆音。
    hop = 480
    peaks = np.array([
        np.abs(signal[index:index + hop]).max()
        for index in range(0, len(signal) - hop, hop)
    ])
    levels = 20 * np.log10(peaks + 1e-9)
    peak = levels.max()
    peak_index = int(np.argmax(levels))
    start = peak_index
    while start > 0 and levels[start - 1] > peak - 35 and peak_index - start < 100:
        start -= 1
    end = min(len(levels), start + int(maximum_duration * 100))
    quiet_frames = 0
    for index in range(peak_index, end):
        quiet_frames = quiet_frames + 1 if levels[index] < peak - 45 else 0
        if quiet_frames >= 8:
            end = index
            break
    segment = signal[start * hop:end * hop].copy()
    fade_in = min(int(SR * 0.003), len(segment))
    segment[:fade_in] *= np.linspace(0, 1, fade_in)
    fade_out = min(max(int(len(segment) * 0.25), int(SR * 0.03)), len(segment))
    segment[-fade_out:] *= np.linspace(1, 0, fade_out) ** 2
    return segment


def save(directory, name, signal):
    # 保留候选筛选前后的两次量化，重建定稿的裁切、淡出和最终电平。
    maximum_duration = {
        "download_complete": 1.2, "all_complete": 1.6, "failed": 0.9,
        "pause": 0.25, "resume": 0.25, "delete": 0.6,
        "link_received": 0.4, "warning": 0.8,
    }
    original_peak = -16 if name == "delete" else -12
    intermediate = quantize(signal, original_peak).astype(np.float32) / 32768
    candidate = trim_and_fade(intermediate, maximum_duration[name])
    candidate = quantize(candidate, -12).astype(np.float32) / 32768
    output = quantize(candidate, PEAK_DBFS[name])
    with wave.open(str(directory / (name + ".wav")), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(SR)
        audio.writeframes(output.tobytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path, help="WAV 输出目录")
    directory = parser.parse_args().output_directory
    directory.mkdir(parents=True, exist_ok=True)
    bell = ((1, 1.0), (2.01, 0.25), (3.0, 0.08), (4.2, 0.04))
    save(directory, "download_complete", place(0.7, [
        (0, tone(1046.5, 0.6, 0.003, 0.30, bell)),
        (0.11, tone(1568, 0.55, 0.003, 0.32, bell)),
    ]))
    save(directory, "all_complete", place(0.95, [
        (0, tone(784, 0.6, 0.003, 0.30, bell)),
        (0.11, tone(1046.5, 0.6, 0.003, 0.30, bell)),
        (0.22, tone(1568, 0.7, 0.003, 0.38, bell)),
    ]))
    save(directory, "failed", place(0.55, [
        (0, tone(392, 0.35, 0.004, 0.18, ((1, 1), (2, 0.2)))),
        (0.13, tone(311, 0.4, 0.004, 0.22, ((1, 1), (2, 0.2)))),
    ]))
    save(directory, "pause", place(0.08, [
        (0, tone(1400, 0.05, 0.001, 0.012, ((1, 1), (3, 0.3)), bend=-0.2)),
    ]))
    save(directory, "resume", place(0.08, [
        (0, tone(1400, 0.05, 0.001, 0.012, ((1, 1), (3, 0.3)), bend=0.3)),
    ]))
    noise = np.random.default_rng(1).normal(size=int(SR * 0.22))
    spectrum = rfft(noise)
    frequencies = np.fft.rfftfreq(len(noise), 1 / SR)
    spectrum *= (frequencies > 1500) & (frequencies < 7000)
    swish = irfft(spectrum) * envelope(len(noise), 0.02, 0.06)
    save(directory, "delete", swish)
    save(directory, "link_received", place(0.2, [
        (0, tone(880, 0.18, 0.002, 0.06, ((1, 1),), bend=0.5)),
    ]))
    save(directory, "warning", place(0.5, [
        (0, tone(740, 0.16, 0.004, 0.08, ((1, 1), (2, 0.1)))),
        (0.2, tone(740, 0.16, 0.004, 0.08, ((1, 1), (2, 0.1)))),
    ]))
    print("已生成 8 个音效；跳过固定资源 task_added。")


if __name__ == "__main__":
    main()
