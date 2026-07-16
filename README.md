# Tilegrove

Tilegrove is a small shared, agent-legible Pokémon-map world built with Godot, Rust, and SpacetimeDB.

## Architecture

- rust/server is the authoritative SpacetimeDB module. It owns player identities and positions, validates movement against seeded map collision/connections, resolves doorway transitions, and advances probabilistic NPC state on a scheduled tick. Moving NPCs leave a bounded authoritative trail, so absence has legible history without unbounded event growth.
- rust/client is the Godot GDExtension client. It stores profile-specific credentials, calls reducers, subscribes to public tables, and exposes replicated state to GDScript.
- godot remains every human or agent participant's body. It owns input, rendering, animation, screenshots, and the semantic loopback HTTP/SSE interface.
- rust/xtask is the repeatable development workflow. Generated SpacetimeDB Rust bindings live in rust/client/generated and must not be edited by hand.

The participant-facing flow is:

    human or agent
      -> Godot input / loopback HTTP
      -> SpacetimeDB reducer
      -> authoritative table update
      -> Godot subscription cache
      -> scene, semantic SSE, and screenshot

## Local workflow

Generate the local Pokémon-derived assets first:

    python3 tools/generate_pokeemerald_assets.py

Then use the repository task runner:

    cargo xtask doctor
    cargo xtask db start

In another terminal:

    cargo xtask db publish
    cargo xtask db generate
    cargo xtask client build
    cargo xtask godot run

cargo xtask dev performs publish, binding generation, client build, and Godot launch when the local server is already running.

Verification:

    cargo xtask verify
    cargo xtask smoke two-clients

The first command preserves the existing offline gameplay regression suite. The smoke command creates a clean local database, launches two headless Godot clients with separate identities, moves both through authoritative reducers, and verifies players, positions, map authority, and NPC state.

## Godot participant interface

The loopback port defaults to 38473 and scans upward if occupied. Override it with TILEGROVE_CONTROL_PORT.

- GET /state — situated semantic state, visible players, and authority health
- GET /look — nearby landmarks and interactions
- POST /move — request an authoritative move
- POST /interact — interact through the participant's Godot client
- GET /stream — semantic SSE projection
- GET /screenshot — current Godot viewport as PNG (GUI renderer required)

Profiles use separate durable SpacetimeDB credentials:

    cargo xtask play --profile thimble --name Thimble

The launcher gives every profile its own credentials, control port, and live runtime descriptor. It refuses to start the same profile twice, so multiple participants on one computer cannot silently cross credentials or control endpoints. Inspect active instances with:

    cargo xtask players

Connect a profile to another SpacetimeDB deployment without changing its identity:

    cargo xtask play --profile thimble --name Thimble \
      --uri https://example.invalid --database tilegrove

Use `--port PORT` only when a stable explicit control port is needed; otherwise the launcher selects an available profile-derived port.

The shared Tilegrove authority is maintained through checked-in commands rather than an undocumented manual deployment:

    cargo xtask remote publish
    cargo xtask remote status

The publish command targets `https://maincloud.spacetimedb.com / tilegrove`, refuses destructive schema replacement, and verifies the published schema before reporting success.

Human players can launch Godot normally. The first launch presents a connection sheet for profile, display name, server, and database. Tilegrove remembers those settings locally and dismisses the sheet after the authority has accepted the player; use the small **Connection…** button to change them later. A failed connection brings the sheet back with the reported error instead of leaving the player in an ambiguous offline state.

Locally generated Pokémon-derived map and sprite assets remain ignored and are never published by this repository.
