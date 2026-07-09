#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from generate_pokeemerald_object_sprites import generate_sprite
from generate_pokeemerald_world import build_registry


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate ignored local Tilegrove assets from a local pokeemerald checkout."
    )
    parser.add_argument(
        "--pokeemerald-root",
        default="/Users/chad/Repos/Research/pokeemerald",
        help="Path to a pokeemerald checkout.",
    )
    parser.add_argument(
        "--maps-output-dir",
        default="godot/assets/pokeemerald/maps",
        help="Directory for generated map PNG/JSON files.",
    )
    parser.add_argument(
        "--registry-output",
        default="godot/assets/pokeemerald/maps/world_registry.json",
        help="Output world registry JSON path.",
    )
    parser.add_argument(
        "--object-sprites-output-dir",
        default="godot/assets/pokeemerald/object_sprites",
        help="Directory for generated object sprite PNG files.",
    )
    return parser.parse_args()


def graphics_ids_from_registry(registry: dict) -> set[str]:
    graphics_ids = {"OBJ_EVENT_GFX_PLAYER"}
    for map_config in registry.get("maps", {}).values():
        manifest_path = Path(str(map_config.get("manifest_path", "")).removeprefix("res://"))
        if not manifest_path.is_absolute():
            manifest_path = Path("godot") / manifest_path
        if not manifest_path.exists():
            continue
        manifest = json.loads(manifest_path.read_text())
        for landmark in manifest.get("landmarks", []):
            if landmark.get("kind") != "object":
                continue
            graphics_id = str(landmark.get("graphics_id", ""))
            if graphics_id.startswith("OBJ_EVENT_GFX_"):
                graphics_ids.add(graphics_id)
    return graphics_ids


def main() -> None:
    args = parse_args()
    pokeemerald_root = Path(args.pokeemerald_root)
    registry = build_registry(
        pokeemerald_root,
        Path(args.maps_output_dir),
        Path(args.registry_output),
    )
    for graphics_id in sorted(graphics_ids_from_registry(registry)):
        generate_sprite(
            pokeemerald_root,
            Path(args.object_sprites_output_dir),
            graphics_id,
        )


if __name__ == "__main__":
    main()
