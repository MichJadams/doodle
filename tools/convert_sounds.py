"""Convert source sound effects (WAV / AIFF, 16/24-bit PCM, any rate/channels)
into Doodle's runtime format: mono, 16-bit PCM, 44100 Hz WAV, peak-normalized.

Usage: python -I tools/convert_sounds.py <in.wav|in.aiff> <out.wav> [<in> <out> ...]
Stdlib only.
"""
import struct
import sys

OUT_RATE = 44100
PEAK = 0.89  # ~ -1 dB


def ext80_to_float(b):
    # AIFF sample rate: 80-bit IEEE 754 extended, big-endian.
    exp = ((b[0] & 0x7F) << 8) | b[1]
    mant = int.from_bytes(b[2:10], "big")
    if exp == 0 and mant == 0:
        return 0.0
    return mant * 2.0 ** (exp - 16383 - 63)


def decode_pcm(data, width, big_endian):
    n = len(data) // width
    out = [0] * n
    order = "big" if big_endian else "little"
    if width == 1:  # WAV 8-bit is unsigned
        return [(x - 128) / 128.0 for x in data]
    scale = float(1 << (8 * width - 1))
    for i in range(n):
        out[i] = int.from_bytes(data[i * width:(i + 1) * width], order, signed=True) / scale
    return out


def read_wav(buf):
    assert buf[:4] == b"RIFF" and buf[8:12] == b"WAVE", "not a WAV"
    i = 12
    fmt = None
    data = None
    while i + 8 <= len(buf):
        cid, size = buf[i:i + 4], struct.unpack("<I", buf[i + 4:i + 8])[0]
        body = buf[i + 8:i + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            data = body
        i += 8 + size + (size & 1)
    tag, ch, rate, _, _, bits = fmt
    assert tag in (1, 0xFFFE), "only PCM WAV is supported"
    return decode_pcm(data, bits // 8, False), ch, rate


def read_aiff(buf):
    assert buf[:4] == b"FORM" and buf[8:12] in (b"AIFF", b"AIFC"), "not an AIFF"
    i = 12
    comm = None
    data = None
    while i + 8 <= len(buf):
        cid, size = buf[i:i + 4], struct.unpack(">I", buf[i + 4:i + 8])[0]
        body = buf[i + 8:i + 8 + size]
        if cid == b"COMM":
            ch, frames, bits = struct.unpack(">hIh", body[:8])
            comm = (ch, frames, bits, ext80_to_float(body[8:18]))
        elif cid == b"SSND":
            offset = struct.unpack(">I", body[:4])[0]
            data = body[8 + offset:]
        i += 8 + size + (size & 1)
    ch, frames, bits, rate = comm
    width = (bits + 7) // 8
    return decode_pcm(data[:frames * ch * width], width, True), ch, int(round(rate))


def convert(src, dst):
    with open(src, "rb") as f:
        buf = f.read()
    samples, ch, rate = (read_aiff if buf[:4] == b"FORM" else read_wav)(buf)
    mono = [sum(samples[i:i + ch]) / ch for i in range(0, len(samples) - ch + 1, ch)]
    if rate != OUT_RATE:  # linear resample
        step = rate / OUT_RATE
        n = int(len(mono) / step)
        res = [0.0] * n
        for k in range(n):
            p = k * step
            j = int(p)
            t = p - j
            a = mono[j]
            b = mono[j + 1] if j + 1 < len(mono) else a
            res[k] = a + (b - a) * t
        mono = res
    peak = max(1e-9, max(abs(x) for x in mono))
    g = PEAK / peak
    pcm = struct.pack("<%dh" % len(mono), *(max(-32768, min(32767, int(x * g * 32767))) for x in mono))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, OUT_RATE, OUT_RATE * 2, 2, 16)
    hdr += b"data" + struct.pack("<I", len(pcm))
    with open(dst, "wb") as f:
        f.write(hdr + pcm)
    print(f"{src} ({ch}ch {rate}Hz) -> {dst}: {len(mono) / OUT_RATE:.1f}s, gain x{g:.2f}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or len(args) % 2:
        sys.exit(__doc__)
    for k in range(0, len(args), 2):
        convert(args[k], args[k + 1])
