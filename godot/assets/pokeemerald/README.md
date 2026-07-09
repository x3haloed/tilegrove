# Local pokeemerald assets

This directory is for generated local assets derived from a local pokeemerald checkout.

The generated map, tileset, and object sprite outputs are intentionally ignored by git.
Keep generator code in the repository, but do not publish the generated Pokemon-derived
PNG/JSON assets.

Current generation command:

```bash
python3 tools/generate_pokeemerald_assets.py
```
