import struct
import subprocess
import tempfile
from pathlib import Path


def clean_png_bytes(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Expected PNG image")
    cleaned = bytearray(data[:8])
    offset = 8
    while offset + 12 <= len(data):
        size = struct.unpack(">I", data[offset : offset + 4])[0]
        end = offset + size + 12
        if end > len(data):
            raise ValueError("Invalid PNG chunk")
        if data[offset + 4 : offset + 8] not in (b"tEXt", b"zTXt", b"iTXt", b"eXIf"):
            cleaned.extend(data[offset:end])
        offset = end
    return bytes(cleaned)


def strip_png_metadata(path):
    path.write_bytes(clean_png_bytes(path.read_bytes()))


def strip_icns_metadata(path):
    data = path.read_bytes()
    if data[:4] != b"icns":
        raise ValueError("Expected ICNS icon")
    chunks = []
    offset = 8
    while offset + 8 <= len(data):
        kind = data[offset : offset + 4]
        size = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid ICNS chunk")
        payload = data[offset + 8 : offset + size]
        if payload.startswith(b"\x89PNG\r\n\x1a\n"):
            payload = clean_png_bytes(payload)
        chunks.append((kind, payload))
        offset += size
    table = b"".join(kind + struct.pack(">I", len(payload) + 8) for kind, payload in chunks if kind != b"TOC ")
    body = b"".join(
        kind
        + struct.pack(">I", len(table if kind == b"TOC " else payload) + 8)
        + (table if kind == b"TOC " else payload)
        for kind, payload in chunks
    )
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


root = Path(__file__).resolve().parent.parent
assets = root / "Assets"
assets.mkdir(exist_ok=True)
subprocess.run(
    [
        "xcrun",
        "swift",
        "-module-cache-path",
        str(Path(tempfile.gettempdir()) / "pomodoro-swift-cache"),
        str(root / "Tools/DrawAppIcon.swift"),
        str(assets / "AppIcon.png"),
    ],
    check=True,
)
strip_png_metadata(assets / "AppIcon.png")
with tempfile.TemporaryDirectory(prefix="codex-status-icon-") as temporary:
    iconset = Path(temporary) / "AppIcon.iconset"
    iconset.mkdir()
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            target = iconset / f"icon_{base}x{base}{suffix}.png"
            pixels = str(base * scale)
            subprocess.run(
                ["sips", "-z", pixels, pixels, str(assets / "AppIcon.png"), "--out", str(target)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            strip_png_metadata(target)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(assets / "AppIcon.icns")], check=True)
strip_icns_metadata(assets / "AppIcon.icns")
print("Created Assets/AppIcon.icns")
