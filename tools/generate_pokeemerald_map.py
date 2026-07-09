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
        help="Output PNG path. Defaults to godot/assets/pokeemerald/maps/<map>.png.",
    )
    parser.add_argument(
        "--manifest-output",
        help="Output semantic manifest JSON path. Defaults to godot/assets/pokeemerald/maps/<map>.json.",
    )
    return parser.parse_args()


def map_slug(map_name: str) -> str:
    slug = []
    for index, character in enumerate(map_name):
        if character.isupper() and index > 0 and not map_name[index - 1].isupper():
            slug.append("_")
        slug.append(character.lower())
    return "".join(slug)


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


def humanize_symbol(value: str) -> str:
    cleaned = value
    for prefix in (
        "MAP_",
        "OBJ_EVENT_GFX_",
        "LOCALID_",
        "FLAG_",
        "MOVEMENT_TYPE_",
        "TRAINER_TYPE_",
        "BG_EVENT_",
    ):
        cleaned = cleaned.removeprefix(prefix)
    return cleaned.replace("_", " ").title()


def point_cell(x: int, y: int) -> dict:
    return {"x": int(x), "y": int(y)}


def boundary_cells(rows: list[list[dict]], direction: str) -> list[dict]:
    height = len(rows)
    width = len(rows[0]) if height else 0
    cells = []
    if direction == "up":
        candidates = [(x, 0) for x in range(width)]
    elif direction == "down":
        candidates = [(x, height - 1) for x in range(width)]
    elif direction == "left":
        candidates = [(0, y) for y in range(height)]
    elif direction == "right":
        candidates = [(width - 1, y) for y in range(height)]
    else:
        candidates = []

    for x, y in candidates:
        if rows[y][x]["passable"]:
            cells.append(point_cell(x, y))
    return cells


def parse_script_blocks(source: str) -> dict[str, list[str]]:
    blocks: dict[str, list[str]] = {}
    current_label = ""
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.endswith(":") and not stripped.startswith("."):
            current_label = stripped.rstrip(":")
            blocks[current_label] = []
            continue
        if current_label:
            blocks[current_label].append(line)
    return blocks


def first_msgbox_text_symbol(blocks: dict[str, list[str]], script_symbol: str) -> str:
    for line in blocks.get(script_symbol, []):
        stripped = line.strip()
        if not stripped.startswith("msgbox "):
            continue
        return stripped.removeprefix("msgbox ").split(",", 1)[0].strip()
    return ""


def decode_string_fragment(fragment: str) -> str:
    if "$" in fragment:
        fragment = fragment.split("$", 1)[0]
    return (
        fragment
        .replace(r"\p", "\n\n")
        .replace(r"\l", "\n")
        .replace(r"\n", "\n")
        .replace(r"\"", '"')
    )


def text_for_symbol(blocks: dict[str, list[str]], text_symbol: str) -> str:
    parts = []
    for line in blocks.get(text_symbol, []):
        stripped = line.strip()
        if not stripped.startswith(".string "):
            if parts:
                break
            continue
        quote_start = stripped.find('"')
        quote_end = stripped.rfind('"')
        if quote_start == -1 or quote_end <= quote_start:
            continue
        fragment = stripped[quote_start + 1:quote_end]
        parts.append(decode_string_fragment(fragment))
        if "$" in fragment:
            break
    return "".join(parts).strip()


def load_script_texts(root: Path, map_name: str) -> dict[str, dict]:
    sources = []
    for path in (
        root / "data/event_scripts.s",
        root / f"data/maps/{map_name}/scripts.inc",
    ):
        if path.exists():
            sources.append(path.read_text())

    blocks: dict[str, list[str]] = {}
    for source in sources:
        blocks.update(parse_script_blocks(source))

    script_texts = {}
    for script_symbol in blocks.keys():
        text_symbol = first_msgbox_text_symbol(blocks, script_symbol)
        if not text_symbol:
            continue
        text = text_for_symbol(blocks, text_symbol)
        if not text:
            continue
        script_texts[script_symbol] = {
            "text_symbol": text_symbol,
            "text": text,
        }
    return script_texts


def text_fields_for_script(script_texts: dict[str, dict], script: str) -> dict:
    text_data = script_texts.get(script)
    if not text_data:
        return {}
    return {
        "text_symbol": text_data["text_symbol"],
        "text": text_data["text"],
    }


def build_landmarks(map_data: dict, rows: list[list[dict]], script_texts: dict[str, dict]) -> list[dict]:
    landmarks = []
    for index, connection in enumerate(map_data.get("connections", [])):
        direction = connection.get("direction", "")
        target = connection.get("map", "")
        landmarks.append({
            "id": f"exit_{direction}_{index}",
            "kind": "exit",
            "name": f"{humanize_symbol(direction)} exit to {humanize_symbol(target)}",
            "cells": boundary_cells(rows, direction),
            "direction": direction,
            "target_map_raw": target,
            "offset": int(connection.get("offset", 0)),
        })

    for index, warp in enumerate(map_data.get("warp_events", [])):
        target = warp.get("dest_map", "")
        landmarks.append({
            "id": f"warp_{index}_{warp.get('x', 0)}_{warp.get('y', 0)}",
            "kind": "doorway",
            "name": f"Doorway to {humanize_symbol(target)}",
            "cells": [point_cell(warp.get("x", 0), warp.get("y", 0))],
            "target_map_raw": target,
            "dest_warp_id": str(warp.get("dest_warp_id", "")),
        })

    for index, event in enumerate(map_data.get("bg_events", [])):
        event_type = event.get("type", "background")
        script = event.get("script", "")
        landmark = {
            "id": f"bg_{index}_{event.get('x', 0)}_{event.get('y', 0)}",
            "kind": event_type,
            "name": f"{humanize_symbol(event_type)}: {humanize_symbol(script)}",
            "cells": [point_cell(event.get("x", 0), event.get("y", 0))],
            "script": script,
        }
        landmark.update(text_fields_for_script(script_texts, script))
        landmarks.append(landmark)

    for index, event in enumerate(map_data.get("object_events", [])):
        graphics = event.get("graphics_id", "object")
        script = event.get("script", "")
        landmark = {
            "id": f"object_{index}_{event.get('x', 0)}_{event.get('y', 0)}",
            "kind": "object",
            "name": humanize_symbol(graphics),
            "cells": [point_cell(event.get("x", 0), event.get("y", 0))],
            "graphics_id": graphics,
            "script": script,
        }
        landmark.update(text_fields_for_script(script_texts, script))
        landmarks.append(landmark)

    for index, event in enumerate(map_data.get("coord_events", [])):
        script = event.get("script", "")
        landmark = {
            "id": f"trigger_{index}_{event.get('x', 0)}_{event.get('y', 0)}",
            "kind": "trigger",
            "name": f"Trigger: {humanize_symbol(script)}",
            "cells": [point_cell(event.get("x", 0), event.get("y", 0))],
            "script": script,
        }
        landmark.update(text_fields_for_script(script_texts, script))
        landmarks.append(landmark)

    return landmarks


def build_manifest(
    map_name: str,
    map_data: dict,
    layout: dict,
    primary: dict,
    secondary: dict,
    values: tuple[int, ...],
    script_texts: dict[str, dict],
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
        "bg_events": map_data.get("bg_events", []),
        "landmarks": build_landmarks(map_data, rows, script_texts),
        "cells": rows,
    }


def generate_map(
    pokeemerald_root: Path,
    map_name: str,
    output_path: Path | None = None,
    manifest_path: Path | None = None,
) -> dict:
    map_data = read_json(pokeemerald_root / f"data/maps/{map_name}/map.json")
    layout = load_layout(pokeemerald_root, map_data["layout"])

    width = int(layout["width"])
    height = int(layout["height"])
    primary = load_tileset(pokeemerald_root, layout["primary_tileset"])
    secondary = load_tileset(pokeemerald_root, layout["secondary_tileset"])
    blockdata = (pokeemerald_root / layout["blockdata_filepath"]).read_bytes()
    expected_size = width * height * 2
    if len(blockdata) != expected_size:
        raise ValueError(
            f"Unexpected blockdata size for {map_name}: {len(blockdata)} != {expected_size}"
        )

    output = Image.new("RGBA", (width * METATILE_SIZE, height * METATILE_SIZE))
    values = struct.unpack(f"<{width * height}H", blockdata)
    for index, block_value in enumerate(values):
        x = (index % width) * METATILE_SIZE
        y = (index // width) * METATILE_SIZE
        draw_metatile(output, primary, secondary, block_value, x, y)

    slug = map_slug(map_name)
    resolved_output_path = output_path or Path(f"godot/assets/pokeemerald/maps/{slug}.png")
    resolved_output_path.parent.mkdir(parents=True, exist_ok=True)
    output.save(resolved_output_path)
    print(f"Wrote {resolved_output_path} ({output.width}x{output.height})")

    script_texts = load_script_texts(pokeemerald_root, map_name)
    manifest = build_manifest(map_name, map_data, layout, primary, secondary, values, script_texts)
    resolved_manifest_path = manifest_path or Path(f"godot/assets/pokeemerald/maps/{slug}.json")
    resolved_manifest_path.parent.mkdir(parents=True, exist_ok=True)
    resolved_manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote {resolved_manifest_path} ({width}x{height} cells)")

    return {
        "map": map_name,
        "slug": slug,
        "output_path": str(resolved_output_path),
        "manifest_path": str(resolved_manifest_path),
        "manifest": manifest,
    }


def main() -> None:
    args = parse_args()
    root = Path(args.pokeemerald_root)
    slug = map_slug(args.map)
    generate_map(
        root,
        args.map,
        Path(args.output) if args.output else Path(f"godot/assets/pokeemerald/maps/{slug}.png"),
        Path(args.manifest_output) if args.manifest_output else Path(f"godot/assets/pokeemerald/maps/{slug}.json"),
    )


if __name__ == "__main__":
    main()
