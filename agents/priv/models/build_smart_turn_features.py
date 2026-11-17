"""Builds `smart_turn_features.onnx`, the Whisper log-mel front end for Smart Turn v3.

Smart Turn v3 takes the 80x800 log-mel spectrogram that
`transformers.WhisperFeatureExtractor(chunk_length=8)` produces from exactly
8 s of 16 kHz audio. Computing that in Elixir would be slow, so this script
expresses the same math as a small fixed-shape ONNX graph that onnxruntime
runs in a few milliseconds:

    pcm [1, 128000] int16 (already left-padded with zeros to 8 s)
      -> scale to [-1, 1) -> zero-mean unit-variance normalization
      -> centered STFT (reflect pad 200, periodic Hann, n_fft 400, hop 160),
         as a strided Conv with windowed DFT kernels
      -> power spectrum -> Slaney mel filterbank (80 bins) -> log10
      -> drop last frame -> clamp to max - 8 -> (x + 4) / 4
    input_features [1, 80, 800] f32

It mirrors pipecat's `compute_whisper_log_mel_features`
(src/pipecat/audio/turn/smart_turn/_whisper_features.py). Run with:

    uv run --with onnx --with numpy python priv/models/build_smart_turn_features.py
"""

import os

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

N_SAMPLES = 128_000
N_FFT = 400
HOP = 160
N_MELS = 80
N_BINS = N_FFT // 2 + 1
SAMPLE_RATE = 16_000


def hz_to_mel(freq):
    freq = np.atleast_1d(np.asarray(freq, dtype=np.float64))
    mels = 3.0 * freq / 200.0
    log_region = freq >= 1000.0
    mels[log_region] = 15.0 + np.log(freq[log_region] / 1000.0) * (27.0 / np.log(6.4))
    return mels


def mel_to_hz(mels):
    mels = np.atleast_1d(np.asarray(mels, dtype=np.float64))
    freq = 200.0 * mels / 3.0
    log_region = mels >= 15.0
    freq[log_region] = 1000.0 * np.exp((np.log(6.4) / 27.0) * (mels[log_region] - 15.0))
    return freq


def mel_filterbank():
    mel_freqs = np.linspace(hz_to_mel(0.0)[0], hz_to_mel(SAMPLE_RATE / 2)[0], N_MELS + 2)
    filter_freqs = mel_to_hz(mel_freqs)
    fft_freqs = np.linspace(0, SAMPLE_RATE // 2, N_BINS)
    filter_diff = np.diff(filter_freqs)
    slopes = filter_freqs[None, :] - fft_freqs[:, None]
    down = -slopes[:, :-2] / filter_diff[:-1]
    up = slopes[:, 2:] / filter_diff[1:]
    filters = np.maximum(0.0, np.minimum(down, up))
    filters *= (2.0 / (filter_freqs[2 : N_MELS + 2] - filter_freqs[:N_MELS]))[None, :]
    return filters.T  # (80, 201)


def dft_kernels():
    window = np.hanning(N_FFT + 1)[:-1]
    n = np.arange(N_FFT)
    k = np.arange(N_BINS)[:, None]
    angle = 2.0 * np.pi * k * n / N_FFT
    real = np.cos(angle) * window
    imag = -np.sin(angle) * window
    return np.concatenate([real, imag])[:, None, :]  # (402, 1, 400)


def const(name, value, dtype=np.float32):
    return numpy_helper.from_array(np.asarray(value, dtype=dtype), name)


def build():
    nodes = [
        helper.make_node("Cast", ["pcm"], ["pcm_f32"], to=TensorProto.FLOAT),
        helper.make_node("Div", ["pcm_f32", "int16_scale"], ["audio"]),
        helper.make_node("ReduceMean", ["audio"], ["mean"], axes=[1], keepdims=1),
        helper.make_node("Sub", ["audio", "mean"], ["centered"]),
        helper.make_node("Mul", ["centered", "centered"], ["squared"]),
        helper.make_node("ReduceMean", ["squared"], ["var"], axes=[1], keepdims=1),
        helper.make_node("Add", ["var", "eps"], ["var_eps"]),
        helper.make_node("Sqrt", ["var_eps"], ["std"]),
        helper.make_node("Div", ["centered", "std"], ["normalized"]),
        helper.make_node("Reshape", ["normalized", "conv_shape"], ["signal"]),
        helper.make_node("Pad", ["signal", "pads"], ["padded"], mode="reflect"),
        helper.make_node("Conv", ["padded", "dft"], ["spectrum"], strides=[HOP]),
        helper.make_node("Mul", ["spectrum", "spectrum"], ["spectrum_sq"]),
        helper.make_node("Slice", ["spectrum_sq", "re_start", "re_end", "axis1"], ["re_sq"]),
        helper.make_node("Slice", ["spectrum_sq", "re_end", "im_end", "axis1"], ["im_sq"]),
        helper.make_node("Add", ["re_sq", "im_sq"], ["power"]),
        helper.make_node("MatMul", ["mel", "power"], ["mel_spec"]),
        helper.make_node("Max", ["mel_spec", "mel_floor"], ["mel_floored"]),
        helper.make_node("Log", ["mel_floored"], ["ln"]),
        helper.make_node("Div", ["ln", "ln10"], ["log_spec_all"]),
        helper.make_node("Slice", ["log_spec_all", "frame_start", "frame_end", "axis2"], ["log_spec"]),
        helper.make_node("ReduceMax", ["log_spec"], ["peak"], keepdims=0),
        helper.make_node("Sub", ["peak", "eight"], ["floor"]),
        helper.make_node("Max", ["log_spec", "floor"], ["clamped"]),
        helper.make_node("Add", ["clamped", "four"], ["shifted"]),
        helper.make_node("Div", ["shifted", "four"], ["input_features"]),
    ]

    initializers = [
        const("int16_scale", 32768.0),
        const("eps", 1e-7),
        const("conv_shape", [1, 1, N_SAMPLES], np.int64),
        const("pads", [0, 0, N_FFT // 2, 0, 0, N_FFT // 2], np.int64),
        const("dft", dft_kernels()),
        const("re_start", [0], np.int64),
        const("re_end", [N_BINS], np.int64),
        const("im_end", [2 * N_BINS], np.int64),
        const("axis1", [1], np.int64),
        const("axis2", [2], np.int64),
        const("mel", mel_filterbank()),
        const("mel_floor", 1e-10),
        const("ln10", np.log(10.0)),
        const("frame_start", [0], np.int64),
        const("frame_end", [N_SAMPLES // HOP], np.int64),
        const("eight", 8.0),
        const("four", 4.0),
    ]

    graph = helper.make_graph(
        nodes,
        "smart_turn_features",
        [helper.make_tensor_value_info("pcm", TensorProto.INT16, [1, N_SAMPLES])],
        [helper.make_tensor_value_info("input_features", TensorProto.FLOAT, [1, N_MELS, N_SAMPLES // HOP])],
        initializers,
    )

    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "smart_turn_features.onnx")
    onnx.save(build(), path)
    print(f"wrote {path}")
