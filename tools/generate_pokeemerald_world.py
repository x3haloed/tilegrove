#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from generate_pokeemerald_map import TILESET_PATHS, generate_map, map_slug, read_json


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


def map_constant(map_name: str) -> str:
    return "MAP_" + map_slug(map_name).upper()


def godot_res_path(path: Path) -> str:
    return "res://" + path.relative_to("godot").as_posix()


def supported_maps(pokeemerald_root: Path) -> list[dict]:
    layouts = {
        layout["id"]: layout
        for layout in read_json(pokeemerald_root / "data/layouts/layouts.json")["layouts"]
    }
    supported_tilesets = set(TILESET_PATHS.keys())
    maps = []

    for map_path in sorted((pokeemerald_root / "data/maps").glob("*/map.json")):
        map_name = map_path.parent.name
        map_data = read_json(map_path)
        layout = layouts.get(map_data.get("layout"))
        if layout is None:
            continue
        if layout["primary_tileset"] not in supported_tilesets:
            continue
        if layout["secondary_tileset"] not in supported_tilesets:
            continue
        maps.append({
            "name": map_name,
            "data": map_data,
            "layout": layout,
        })

    return maps


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

    constants = {
        map_constant(map_name): map_name
        for map_name in generated.keys()
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
            "constant": map_constant(map_name),
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
