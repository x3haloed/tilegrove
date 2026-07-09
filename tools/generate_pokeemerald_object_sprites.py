#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


SOURCE_ROOT = Path("graphics/object_events/pics")
FRAME_COUNT_BY_WIDTH = {
    144: 9,
}
GRAPHICS_ID_OVERRIDES = {
    "OBJ_EVENT_GFX_PLAYER": "people/brendan/walking.png",
    "OBJ_EVENT_GFX_TRUCK": "misc/truck.png",
}


def image_pixels(image: Image.Image):
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return image.getdata()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate simple standing overworld object sprites from pokeemerald PNG sheets."
    )
    parser.add_argument(
        "--pokeemerald-root",
        default="/Users/chad/Repos/Research/pokeemerald",
        help="Path to a pokeemerald checkout.",
    )
    parser.add_argument(
        "--output-dir",
        default="godot/assets/pokeemerald/object_sprites",
        help="Directory for generated object sprite PNG files.",
    )
    parser.add_argument(
        "graphics_ids",
        nargs="*",
        help="OBJ_EVENT_GFX_* ids to generate. Defaults to the first-ring Tilegrove ids.",
    )
    return parser.parse_args()


def graphics_slug(graphics_id: str) -> str:
    return graphics_id.removeprefix("OBJ_EVENT_GFX_").lower()


def source_for_graphics_id(root: Path, graphics_id: str) -> Path | None:
    override = GRAPHICS_ID_OVERRIDES.get(graphics_id)
    if override:
        path = root / SOURCE_ROOT / override
        return path if path.exists() else None

    slug = graphics_slug(graphics_id)
    matches = sorted((root / SOURCE_ROOT).glob(f"**/{slug}.png"))
    if matches:
        return matches[0]
    return None


def transparent_rgba(image: Image.Image) -> Image.Image:
    indexed = image.convert("P")
    palette = indexed.getpalette()
    rgba = indexed.convert("RGBA")
    pixels = []
    transparent_rgb = tuple(palette[:3]) if palette else (0, 0, 0)
    for value, pixel in zip(image_pixels(indexed), image_pixels(rgba), strict=False):
        if value == 0 or pixel[:3] == transparent_rgb:
            pixels.append((0, 0, 0, 0))
        else:
            pixels.append(pixel)
    rgba.putdata(pixels)
    return rgba


def standing_frame(image: Image.Image) -> Image.Image:
    frame_count = FRAME_COUNT_BY_WIDTH.get(image.width, 1)
    frame_width = image.width // frame_count
    return image.crop((0, 0, frame_width, image.height))


def output_image(image: Image.Image, graphics_id: str) -> Image.Image:
    if image.width == 144 and image.height in (16, 32):
        return image
    return standing_frame(image)


def generate_sprite(root: Path, output_dir: Path, graphics_id: str) -> Path | None:
    source = source_for_graphics_id(root, graphics_id)
    if source is None:
        print(f"Missing source for {graphics_id}")
        return None

    image = Image.open(source)
    output = transparent_rgba(output_image(image, graphics_id))
    output_path = output_dir / f"{graphics_slug(graphics_id)}.png"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output.save(output_path)
    print(f"Wrote {output_path} from {source.relative_to(root)} ({output.width}x{output.height})")
    return output_path


def main() -> None:
    args = parse_args()
    graphics_ids = args.graphics_ids or [
        "OBJ_EVENT_GFX_PLAYER",
        "OBJ_EVENT_GFX_TWIN",
        "OBJ_EVENT_GFX_FAT_MAN",
        "OBJ_EVENT_GFX_BOY_2",
        "OBJ_EVENT_GFX_MOM",
        "OBJ_EVENT_GFX_TRUCK",
        "OBJ_EVENT_GFX_PROF_BIRCH",
        "OBJ_EVENT_GFX_SCIENTIST_1",
    ]
    for graphics_id in graphics_ids:
        generate_sprite(Path(args.pokeemerald_root), Path(args.output_dir), graphics_id)


if __name__ == "__main__":
    main()
