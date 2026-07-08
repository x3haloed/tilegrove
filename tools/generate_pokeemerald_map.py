#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

from PIL import Image


TILESET_PATHS = {
    "gTileset_General": "data/tilesets/primary/general",
    "gTileset_Petalburg": "data/tilesets/secondary/petalburg",
}

METATILE_BYTES = 16
PRIMARY_METATILE_COUNT = 512
TILE_SIZE = 8
METATILE_SIZE = 16


def image_pixels(image: Image.Image):
    if hasattr(image, "get_flattened_data"):
        return image.get_flattened_data()
    return image.getdata()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a composed preview PNG from pokeemerald map data."
    )
    parser.add_argument(
        "--pokeemerald-root",
        default="/Users/chad/Repos/Research/pokeemerald",
        help="Path to a pokeemerald checkout.",
    )
    parser.add_argument("--map", default="LittlerootTown", help="Map directory name.")
    parser.add_argument(
        "--output",
        default="godot/assets/pokeemerald/maps/littleroot_town.png",
        help="Output PNG path.",
    )
    parser.add_argument(
        "--manifest-output",
        default="godot/assets/pokeemerald/maps/littleroot_town.json",
        help="Output semantic manifest JSON path.",
    )
    return parser.parse_args()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def load_layout(root: Path, layout_id: str) -> dict:
    layouts = read_json(root / "data/layouts/layouts.json")["layouts"]
    for layout in layouts:
        if layout["id"] == layout_id:
            return layout
    raise ValueError(f"Layout not found: {layout_id}")


def load_palettes(tileset_dir: Path) -> list[list[tuple[int, int, int, int]]]:
    palettes = []
    for index in range(16):
        path = tileset_dir / f"palettes/{index:02}.pal"
        lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
        if lines[:3] != ["JASC-PAL", "0100", "16"]:
            raise ValueError(f"Unexpected palette format: {path}")
        colors = []
        for line in lines[3:19]:
            red, green, blue = (int(part) for part in line.split())
            colors.append((red, green, blue, 255))
        palettes.append(colors)
    return palettes


def load_tileset(root: Path, symbol: str) -> dict:
    rel = TILESET_PATHS.get(symbol)
    if rel is None:
        raise ValueError(f"Unsupported tileset symbol: {symbol}")

    directory = root / rel
    image = Image.open(directory / "tiles.png").convert("P")
    metatiles = (directory / "metatiles.bin").read_bytes()
    attributes = (directory / "metatile_attributes.bin").read_bytes()
    return {
        "symbol": symbol,
        "directory": directory,
        "image": image,
        "palettes": load_palettes(directory),
        "metatiles": metatiles,
        "attributes": attributes,
    }


def tile_from_sheet(tileset: dict, tile_index: int, palette_index: int) -> Image.Image:
    image: Image.Image = tileset["image"]
    tiles_per_row = image.width // TILE_SIZE
    max_tiles = tiles_per_row * (image.height // TILE_SIZE)
    if tile_index < 0 or tile_index >= max_tiles:
        return Image.new("RGBA", (TILE_SIZE, TILE_SIZE), (255, 0, 255, 255))

    x = (tile_index % tiles_per_row) * TILE_SIZE
    y = (tile_index // tiles_per_row) * TILE_SIZE
    indexed_tile = image.crop((x, y, x + TILE_SIZE, y + TILE_SIZE))
    palette = tileset["palettes"][palette_index]

    output = Image.new("RGBA", (TILE_SIZE, TILE_SIZE))
    pixels = []
    for value in image_pixels(indexed_tile):
        pixels.append(palette[value])
    output.putdata(pixels)
    return output


def draw_metatile(
    output: Image.Image,
    primary: dict,
    secondary: dict,
    block_value: int,
    dest_x: int,
    dest_y: int,
) -> None:
    metatile_id = block_value & 0x03FF
    if metatile_id < PRIMARY_METATILE_COUNT:
        tileset = primary
        local_metatile_id = metatile_id
    else:
        tileset = secondary
        local_metatile_id = metatile_id - PRIMARY_METATILE_COUNT

    start = local_metatile_id * METATILE_BYTES
    end = start + METATILE_BYTES
    metatile = tileset["metatiles"][start:end]
    if len(metatile) != METATILE_BYTES:
        output.alpha_composite(
            Image.new("RGBA", (METATILE_SIZE, METATILE_SIZE), (255, 0, 255, 255)),
            (dest_x, dest_y),
        )
        return

    entries = struct.unpack("<8H", metatile)
    for layer in range(2):
        for quadrant in range(4):
            entry = entries[layer * 4 + quadrant]
            tile_index = entry & 0x03FF
            palette_index = (entry >> 12) & 0x0F
            hflip = bool(entry & 0x0400)
            vflip = bool(entry & 0x0800)

            source_tileset = primary
            local_tile_index = tile_index
            if tile_index >= 512:
                source_tileset = secondary
                local_tile_index = tile_index - 512

            tile = tile_from_sheet(source_tileset, local_tile_index, palette_index)
            if hflip:
                tile = tile.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            if vflip:
                tile = tile.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            if layer == 1:
                tile.putdata([
                    (0, 0, 0, 0) if pixel[3] and pixel[:3] == source_tileset["palettes"][palette_index][0][:3] else pixel
                    for pixel in image_pixels(tile)
                ])

            x = dest_x + (quadrant % 2) * TILE_SIZE
            y = dest_y + (quadrant // 2) * TILE_SIZE
            output.alpha_composite(tile, (x, y))


def metatile_tileset(primary: dict, secondary: dict, metatile_id: int) -> tuple[dict, int]:
    if metatile_id < PRIMARY_METATILE_COUNT:
        return primary, metatile_id
    return secondary, metatile_id - PRIMARY_METATILE_COUNT


def metatile_attributes(primary: dict, secondary: dict, metatile_id: int) -> dict:
    tileset, local_metatile_id = metatile_tileset(primary, secondary, metatile_id)
    start = local_metatile_id * 2
    end = start + 2
    attribute_bytes = tileset["attributes"][start:end]
    if len(attribute_bytes) != 2:
        return {"behavior": None, "layer": None, "tileset": tileset["symbol"]}

    value = struct.unpack("<H", attribute_bytes)[0]
    return {
        "behavior": value & 0x00FF,
        "layer": (value >> 12) & 0x0F,
        "tileset": tileset["symbol"],
    }


def build_manifest(
    map_name: str,
    map_data: dict,
    layout: dict,
    primary: dict,
    secondary: dict,
    values: tuple[int, ...],
) -> dict:
    width = int(layout["width"])
    height = int(layout["height"])
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            raw = values[x + y * width]
            metatile_id = raw & 0x03FF
            attrs = metatile_attributes(primary, secondary, metatile_id)
            row.append(
                {
                    "x": x,
                    "y": y,
                    "raw": raw,
                    "metatile_id": metatile_id,
                    "collision": (raw >> 10) & 0x03,
                    "elevation": (raw >> 12) & 0x0F,
                    "passable": ((raw >> 10) & 0x03) == 0,
                    "behavior": attrs["behavior"],
                    "layer": attrs["layer"],
                    "tileset": attrs["tileset"],
                }
            )
        rows.append(row)

    return {
        "source": "pokeemerald",
        "map": map_name,
        "layout": map_data["layout"],
        "width": width,
        "height": height,
        "metatile_size": METATILE_SIZE,
        "primary_tileset": layout["primary_tileset"],
        "secondary_tileset": layout["secondary_tileset"],
        "connections": map_data.get("connections", []),
        "object_events": map_data.get("object_events", []),
        "warp_events": map_data.get("warp_events", []),
        "coord_events": map_data.get("coord_events", []),
        "cells": rows,
    }


def main() -> None:
    args = parse_args()
    root = Path(args.pokeemerald_root)
    map_data = read_json(root / f"data/maps/{args.map}/map.json")
    layout = load_layout(root, map_data["layout"])

    width = int(layout["width"])
    height = int(layout["height"])
    primary = load_tileset(root, layout["primary_tileset"])
    secondary = load_tileset(root, layout["secondary_tileset"])
    blockdata = (root / layout["blockdata_filepath"]).read_bytes()
    expected_size = width * height * 2
    if len(blockdata) != expected_size:
        raise ValueError(
            f"Unexpected blockdata size for {args.map}: {len(blockdata)} != {expected_size}"
        )

    output = Image.new("RGBA", (width * METATILE_SIZE, height * METATILE_SIZE))
    values = struct.unpack(f"<{width * height}H", blockdata)
    for index, block_value in enumerate(values):
        x = (index % width) * METATILE_SIZE
        y = (index // width) * METATILE_SIZE
        draw_metatile(output, primary, secondary, block_value, x, y)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output.save(output_path)
    print(f"Wrote {output_path} ({output.width}x{output.height})")

    manifest = build_manifest(args.map, map_data, layout, primary, secondary, values)
    manifest_path = Path(args.manifest_output)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote {manifest_path} ({width}x{height} cells)")


if __name__ == "__main__":
    main()
