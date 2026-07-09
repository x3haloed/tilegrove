#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from generate_pokeemerald_map import TILESET_PATHS, generate_map, map_slug, read_json

SEED_TILESET_PAIRS = {
    ("gTileset_General", "gTileset_Petalburg"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate all pokeemerald maps supported by the current tileset importer."
    )
    parser.add_argument(
        "--pokeemerald-root",
        default="/Users/chad/Repos/Research/pokeemerald",
        help="Path to a pokeemerald checkout.",
    )
    parser.add_argument(
        "--output-dir",
        default="godot/assets/pokeemerald/maps",
        help="Directory for generated map PNG/JSON files.",
    )
    parser.add_argument(
        "--registry-output",
        default="godot/assets/pokeemerald/maps/world_registry.json",
        help="Output world registry JSON path.",
    )
    return parser.parse_args()


def map_constant_name(map_name: str) -> str:
    parts = []
    previous = ""
    for character in map_name:
        if character == "_":
            parts.append("_")
        else:
            if character.isupper() and previous and previous.islower():
                parts.append("_")
            parts.append(character.upper())
        previous = character
    return "MAP_" + "".join(parts)


def map_constants(pokeemerald_root: Path) -> dict[str, str]:
    groups = read_json(pokeemerald_root / "data/maps/map_groups.json")
    constants = {}
    for group_name in groups["group_order"]:
        for map_name in groups[group_name]:
            constants[map_constant_name(map_name)] = map_name
    return constants


def godot_res_path(path: Path) -> str:
    return "res://" + path.relative_to("godot").as_posix()


def supported_maps(pokeemerald_root: Path) -> list[dict]:
    layouts = {
        layout["id"]: layout
        for layout in read_json(pokeemerald_root / "data/layouts/layouts.json")["layouts"]
    }
    supported_tilesets = set(TILESET_PATHS.keys())
    constants = map_constants(pokeemerald_root)
    maps_by_name = {}

    for map_path in sorted((pokeemerald_root / "data/maps").glob("*/map.json")):
        map_name = map_path.parent.name
        map_data = read_json(map_path)
        layout = layouts.get(map_data.get("layout"))
        if layout is None:
            continue
        maps_by_name[map_name] = {
            "name": map_name,
            "data": map_data,
            "layout": layout,
        }

    selected_names = set()
    for map_name, map_info in maps_by_name.items():
        layout = map_info["layout"]
        pair = (layout["primary_tileset"], layout["secondary_tileset"])
        if pair in SEED_TILESET_PAIRS:
            selected_names.add(map_name)

    for map_name in list(selected_names):
        for warp in maps_by_name[map_name]["data"].get("warp_events") or []:
            target_name = constants.get(warp.get("dest_map", ""))
            if not target_name or target_name not in maps_by_name:
                continue
            target_layout = maps_by_name[target_name]["layout"]
            if target_layout["primary_tileset"] not in supported_tilesets:
                continue
            if target_layout["secondary_tileset"] not in supported_tilesets:
                continue
            selected_names.add(target_name)

    ordered_names = []
    groups = read_json(pokeemerald_root / "data/maps/map_groups.json")
    for group_name in groups["group_order"]:
        for map_name in groups[group_name]:
            if map_name in selected_names:
                ordered_names.append(map_name)

    return [maps_by_name[map_name] for map_name in ordered_names]


def build_registry(pokeemerald_root: Path, output_dir: Path, registry_output: Path) -> dict:
    maps = supported_maps(pokeemerald_root)
    generated = {}

    for map_info in maps:
        map_name = map_info["name"]
        slug = map_slug(map_name)
        generated[map_name] = generate_map(
            pokeemerald_root,
            map_name,
            output_dir / f"{slug}.png",
            output_dir / f"{slug}.json",
        )

    all_constants = map_constants(pokeemerald_root)
    constants = {
        raw_map: map_name
        for raw_map, map_name in all_constants.items()
        if map_name in generated
    }

    registry_maps = {}
    for map_name, result in generated.items():
        manifest = result["manifest"]
        connections = []
        for connection in manifest.get("connections", []):
            raw_map = connection.get("map", "")
            target_map = constants.get(raw_map, "")
            connections.append({
                "direction": connection.get("direction", ""),
                "offset": int(connection.get("offset", 0)),
                "raw_map": raw_map,
                "map": target_map,
                "loaded": bool(target_map),
            })

        registry_maps[map_name] = {
            "slug": result["slug"],
            "constant": map_constant_name(map_name),
            "manifest_path": godot_res_path(Path(result["manifest_path"])),
            "texture_path": godot_res_path(Path(result["output_path"])),
            "layout": manifest["layout"],
            "width": manifest["width"],
            "height": manifest["height"],
            "primary_tileset": manifest["primary_tileset"],
            "secondary_tileset": manifest["secondary_tileset"],
            "connections": connections,
            "warp_count": len(manifest.get("warp_events", [])),
            "landmark_count": len(manifest.get("landmarks", [])),
        }

    registry = {
        "source": "pokeemerald",
        "start_map": "LittlerootTown" if "LittlerootTown" in registry_maps else next(iter(registry_maps), ""),
        "supported_tilesets": sorted(TILESET_PATHS.keys()),
        "map_count": len(registry_maps),
        "maps": registry_maps,
        "map_constants": constants,
    }

    registry_output.parent.mkdir(parents=True, exist_ok=True)
    registry_output.write_text(json.dumps(registry, indent=2) + "\n")
    print(f"Wrote {registry_output} ({len(registry_maps)} maps)")
    return registry


def main() -> None:
    args = parse_args()
    build_registry(
        Path(args.pokeemerald_root),
        Path(args.output_dir),
        Path(args.registry_output),
    )


if __name__ == "__main__":
    main()
