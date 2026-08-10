#!/usr/bin/env python3
"""Create the production 1024 px app icon from the generated source image."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "AppIcon-original.png"
OUTPUT = ROOT / "Resources" / "AppIcon.png"


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    side = min(source.size)
    left = (source.width - side) // 2
    top = (source.height - side) // 2
    icon = source.crop((left, top, left + side, top + side))
    icon = icon.resize((1024, 1024), Image.Resampling.LANCZOS)

    rgba = icon.convert("RGBA")
    pixels = []
    for red, green, blue, _ in rgba.get_flattened_data():
        # The generated image has a connected near-black canvas around the
        # rounded icon. Preserve the dark blue artwork while turning only that
        # neutral canvas and its antialiased edge transparent.
        brightness = max(red, green, blue)
        alpha = max(0, min(255, round((brightness - 2) * 255 / 42)))
        pixels.append((red, green, blue, alpha))

    rgba.putdata(pixels)
    rgba.save(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    main()
