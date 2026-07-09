use serde_json::Value;
use spacetimedb::{
    Identity, ReducerContext, ScheduleAt, Table, TimeDuration, Timestamp, reducer, table,
};

const CLIENT_PROTOCOL: u32 = 1;
const START_MAP: &str = "LittlerootTown";
const START_X: i32 = 10;
const START_Y: i32 = 15;

#[table(accessor = player, public)]
pub struct Player {
    #[primary_key]
    pub identity: Identity,
    pub display_name: String,
    pub client_protocol: u32,
    pub online: bool,
    pub joined_at: Timestamp,
    pub updated_at: Timestamp,
}

#[table(accessor = player_position, public)]
pub struct PlayerPosition {
    #[primary_key]
    pub identity: Identity,
    pub map_name: String,
    pub x: i32,
    pub y: i32,
    pub facing: String,
    pub revision: u64,
    pub updated_at: Timestamp,
}

#[table(accessor = world_map, public)]
pub struct WorldMap {
    #[primary_key]
    pub map_name: String,
    #[unique]
    pub map_constant: String,
    pub width: i32,
    pub height: i32,
    pub manifest_json: String,
    pub seeded_by: Identity,
    pub updated_at: Timestamp,
}

#[table(accessor = npc_state, public)]
pub struct NpcState {
    #[primary_key]
    pub key: String,
    pub map_name: String,
    pub object_id: String,
    pub spawn_x: i32,
    pub spawn_y: i32,
    pub x: i32,
    pub y: i32,
    pub facing: String,
    pub movement_type: String,
    pub range_x: i32,
    pub range_y: i32,
    pub revision: u64,
    pub updated_at: Timestamp,
}

#[table(accessor = world_tick_schedule, scheduled(world_tick))]
pub struct WorldTickSchedule {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
}

#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.world_tick_schedule().insert(WorldTickSchedule {
        scheduled_id: 0,
        scheduled_at: TimeDuration::from_micros(1_000_000).into(),
    });
}

#[reducer(client_connected)]
pub fn client_connected(ctx: &ReducerContext) {
    if let Some(player) = ctx.db.player().identity().find(ctx.sender()) {
        ctx.db.player().identity().update(Player {
            online: true,
            updated_at: ctx.timestamp,
            ..player
        });
    }
}

#[reducer(client_disconnected)]
pub fn client_disconnected(ctx: &ReducerContext) {
    if let Some(player) = ctx.db.player().identity().find(ctx.sender()) {
        ctx.db.player().identity().update(Player {
            online: false,
            updated_at: ctx.timestamp,
            ..player
        });
    }
}

#[reducer]
pub fn join_world(
    ctx: &ReducerContext,
    display_name: String,
    client_protocol: u32,
) -> Result<(), String> {
    if client_protocol != CLIENT_PROTOCOL {
        return Err(format!(
            "Unsupported client protocol {client_protocol}; server requires {CLIENT_PROTOCOL}"
        ));
    }
    let display_name = display_name.trim();
    if display_name.is_empty() || display_name.len() > 48 {
        return Err("Display name must contain 1 to 48 bytes".into());
    }
    if let Some(player) = ctx.db.player().identity().find(ctx.sender()) {
        ctx.db.player().identity().update(Player {
            display_name: display_name.into(),
            client_protocol,
            online: true,
            updated_at: ctx.timestamp,
            ..player
        });
    } else {
        ctx.db.player().insert(Player {
            identity: ctx.sender(),
            display_name: display_name.into(),
            client_protocol,
            online: true,
            joined_at: ctx.timestamp,
            updated_at: ctx.timestamp,
        });
    }
    if ctx
        .db
        .player_position()
        .identity()
        .find(ctx.sender())
        .is_none()
    {
        ctx.db.player_position().insert(PlayerPosition {
            identity: ctx.sender(),
            map_name: START_MAP.into(),
            x: START_X,
            y: START_Y,
            facing: "south".into(),
            revision: 0,
            updated_at: ctx.timestamp,
        });
    }
    Ok(())
}

#[reducer]
pub fn seed_world_map(
    ctx: &ReducerContext,
    map_name: String,
    map_constant: String,
    manifest_json: String,
) -> Result<(), String> {
    require_player(ctx)?;
    if map_name.is_empty()
        || map_name.len() > 96
        || map_constant.is_empty()
        || map_constant.len() > 128
    {
        return Err("Invalid map identity".into());
    }
    let manifest: Value = serde_json::from_str(&manifest_json)
        .map_err(|error| format!("Invalid manifest JSON: {error}"))?;
    let width = manifest
        .get("width")
        .and_then(Value::as_i64)
        .ok_or("Manifest width missing")? as i32;
    let height = manifest
        .get("height")
        .and_then(Value::as_i64)
        .ok_or("Manifest height missing")? as i32;
    if width <= 0 || height <= 0 || manifest.get("cells").and_then(Value::as_array).is_none() {
        return Err("Manifest has invalid dimensions or cells".into());
    }
    if let Some(existing) = ctx.db.world_map().map_name().find(&map_name) {
        if existing.manifest_json == manifest_json && existing.map_constant == map_constant {
            return Ok(());
        }
        return Err(format!(
            "World map {} is already seeded with different authority data",
            existing.map_name
        ));
    } else {
        ctx.db.world_map().insert(WorldMap {
            map_name: map_name.clone(),
            map_constant,
            width,
            height,
            manifest_json,
            seeded_by: ctx.sender(),
            updated_at: ctx.timestamp,
        });
    }
    seed_npcs(ctx, &map_name, &manifest);
    Ok(())
}

#[reducer]
pub fn world_tick(ctx: &ReducerContext, _schedule: WorldTickSchedule) -> Result<(), String> {
    if ctx.sender() != ctx.identity() {
        return Err("world_tick may only be invoked by the scheduler".into());
    }
    let npcs = ctx.db.npc_state().iter().collect::<Vec<_>>();
    for npc in npcs {
        if npc.movement_type != "MOVEMENT_TYPE_WANDER_AROUND" {
            continue;
        }
        let Some(world_map) = ctx.db.world_map().map_name().find(&npc.map_name) else {
            continue;
        };
        let Ok(manifest) = serde_json::from_str::<Value>(&world_map.manifest_json) else {
            continue;
        };
        let directions = [
            (0, -1, "north"),
            (1, 0, "east"),
            (0, 1, "south"),
            (-1, 0, "west"),
        ];
        let start = deterministic_direction(&npc);
        let mut destination = None;
        for offset in 0..directions.len() {
            let (dx, dy, facing) = directions[(start + offset) % directions.len()];
            let x = npc.x + dx;
            let y = npc.y + dy;
            if (x - npc.spawn_x).abs() > npc.range_x || (y - npc.spawn_y).abs() > npc.range_y {
                continue;
            }
            if !cell_passable(&manifest, x, y) {
                continue;
            }
            let player_occupied =
                ctx.db.player_position().iter().any(|player| {
                    player.map_name == npc.map_name && player.x == x && player.y == y
                });
            let npc_occupied = ctx.db.npc_state().iter().any(|other| {
                other.key != npc.key
                    && other.map_name == npc.map_name
                    && other.x == x
                    && other.y == y
            });
            if player_occupied || npc_occupied {
                continue;
            }
            destination = Some((x, y, facing));
            break;
        }
        if let Some((x, y, facing)) = destination {
            ctx.db.npc_state().key().update(NpcState {
                x,
                y,
                facing: facing.into(),
                revision: npc.revision + 1,
                updated_at: ctx.timestamp,
                ..npc
            });
        }
    }
    Ok(())
}

fn seed_npcs(ctx: &ReducerContext, map_name: &str, manifest: &Value) {
    let Some(landmarks) = manifest.get("landmarks").and_then(Value::as_array) else {
        return;
    };
    for landmark in landmarks {
        if landmark.get("kind").and_then(Value::as_str) != Some("object") {
            continue;
        }
        let Some(object_id) = landmark.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(cell) = landmark
            .get("cells")
            .and_then(Value::as_array)
            .and_then(|cells| cells.first())
        else {
            continue;
        };
        let x = cell.get("x").and_then(Value::as_i64).unwrap_or(0) as i32;
        let y = cell.get("y").and_then(Value::as_i64).unwrap_or(0) as i32;
        let key = format!("{map_name}:{object_id}");
        if ctx.db.npc_state().key().find(&key).is_some() {
            continue;
        }
        let movement_type = landmark
            .get("movement_type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        ctx.db.npc_state().insert(NpcState {
            key,
            map_name: map_name.into(),
            object_id: object_id.into(),
            spawn_x: x,
            spawn_y: y,
            x,
            y,
            facing: initial_npc_facing(&movement_type).into(),
            movement_type,
            range_x: landmark
                .get("movement_range_x")
                .and_then(Value::as_i64)
                .unwrap_or(0) as i32,
            range_y: landmark
                .get("movement_range_y")
                .and_then(Value::as_i64)
                .unwrap_or(0) as i32,
            revision: 0,
            updated_at: ctx.timestamp,
        });
    }
}

fn initial_npc_facing(movement_type: &str) -> &'static str {
    if movement_type.contains("UP") || movement_type.contains("NORTH") {
        "north"
    } else if movement_type.contains("LEFT") || movement_type.contains("WEST") {
        "west"
    } else if movement_type.contains("RIGHT") || movement_type.contains("EAST") {
        "east"
    } else {
        "south"
    }
}

fn deterministic_direction(npc: &NpcState) -> usize {
    let hash = npc.key.bytes().fold(0usize, |value, byte| {
        value.wrapping_mul(31).wrapping_add(byte as usize)
    });
    (hash + npc.revision as usize) % 4
}

#[reducer]
pub fn move_player(ctx: &ReducerContext, direction: String) -> Result<(), String> {
    require_player(ctx)?;
    let position = ctx
        .db
        .player_position()
        .identity()
        .find(ctx.sender())
        .ok_or_else(|| "Player position not found".to_string())?;
    let (dx, dy, facing) = match direction.trim().to_ascii_lowercase().as_str() {
        "north" | "up" => (0, -1, "north"),
        "south" | "down" => (0, 1, "south"),
        "west" | "left" => (-1, 0, "west"),
        "east" | "right" => (1, 0, "east"),
        _ => return Err("Unknown movement direction".into()),
    };
    let current_map = ctx
        .db
        .world_map()
        .map_name()
        .find(&position.map_name)
        .ok_or_else(|| format!("World map {} is not seeded", position.map_name))?;
    let manifest: Value = serde_json::from_str(&current_map.manifest_json)
        .map_err(|error| format!("Stored manifest is invalid: {error}"))?;
    let target_x = position.x + dx;
    let target_y = position.y + dy;
    let (map_name, x, y) = if cell_passable(&manifest, target_x, target_y) {
        (position.map_name.clone(), target_x, target_y)
    } else if target_x < 0
        || target_y < 0
        || target_x >= current_map.width
        || target_y >= current_map.height
    {
        connection_target(ctx, &manifest, &direction, target_x, target_y)?
    } else {
        return Err(format!("Movement blocked at ({target_x},{target_y})"));
    };
    if ctx.db.player_position().iter().any(|other| {
        other.identity != ctx.sender() && other.map_name == map_name && other.x == x && other.y == y
    }) {
        return Err("Another player occupies that cell".into());
    }
    if ctx
        .db
        .npc_state()
        .iter()
        .any(|npc| npc.map_name == map_name && npc.x == x && npc.y == y)
    {
        return Err("An NPC occupies that cell".into());
    }
    ctx.db.player_position().identity().update(PlayerPosition {
        map_name,
        x,
        y,
        facing: facing.into(),
        revision: position.revision + 1,
        updated_at: ctx.timestamp,
        ..position
    });
    Ok(())
}

#[reducer]
pub fn use_doorway(ctx: &ReducerContext, target_id: String) -> Result<(), String> {
    require_player(ctx)?;
    let position = ctx
        .db
        .player_position()
        .identity()
        .find(ctx.sender())
        .ok_or_else(|| "Player position not found".to_string())?;
    let current_map = ctx
        .db
        .world_map()
        .map_name()
        .find(&position.map_name)
        .ok_or_else(|| format!("World map {} is not seeded", position.map_name))?;
    let manifest: Value = serde_json::from_str(&current_map.manifest_json)
        .map_err(|error| format!("Stored manifest is invalid: {error}"))?;
    let landmark = manifest
        .get("landmarks")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("id").and_then(Value::as_str) == Some(target_id.as_str()))
        })
        .ok_or_else(|| format!("Unknown interaction target {target_id}"))?;
    if landmark.get("kind").and_then(Value::as_str) != Some("doorway") {
        return Err("Target is not a doorway".into());
    }
    let in_range = landmark
        .get("cells")
        .and_then(Value::as_array)
        .map(|cells| {
            cells.iter().any(|cell| {
                let x = cell.get("x").and_then(Value::as_i64).unwrap_or(i64::MIN) as i32;
                let y = cell.get("y").and_then(Value::as_i64).unwrap_or(i64::MIN) as i32;
                (position.x - x).abs() + (position.y - y).abs() <= 1
            })
        })
        .unwrap_or(false);
    if !in_range {
        return Err("Doorway is too far away".into());
    }
    let raw_target = landmark
        .get("target_map_raw")
        .and_then(Value::as_str)
        .ok_or("Doorway target missing")?;
    let target_map = ctx
        .db
        .world_map()
        .map_constant()
        .find(raw_target.to_string())
        .ok_or_else(|| format!("Doorway target {raw_target} is not seeded"))?;
    let warp_id = landmark
        .get("dest_warp_id")
        .and_then(Value::as_i64)
        .unwrap_or(0) as usize;
    let target_manifest: Value = serde_json::from_str(&target_map.manifest_json)
        .map_err(|error| format!("Stored target manifest is invalid: {error}"))?;
    let warp = target_manifest
        .get("warp_events")
        .and_then(Value::as_array)
        .and_then(|warps| warps.get(warp_id))
        .ok_or("Target warp is missing")?;
    let x = warp
        .get("x")
        .and_then(Value::as_i64)
        .ok_or("Target warp x missing")? as i32;
    let y = warp
        .get("y")
        .and_then(Value::as_i64)
        .ok_or("Target warp y missing")? as i32;
    if !cell_passable(&target_manifest, x, y) {
        return Err("Target warp cell is blocked".into());
    }
    ctx.db.player_position().identity().update(PlayerPosition {
        map_name: target_map.map_name,
        x,
        y,
        revision: position.revision + 1,
        updated_at: ctx.timestamp,
        ..position
    });
    Ok(())
}

fn cell_passable(manifest: &Value, x: i32, y: i32) -> bool {
    if x < 0 || y < 0 {
        return false;
    }
    manifest
        .get("cells")
        .and_then(Value::as_array)
        .and_then(|rows| rows.get(y as usize))
        .and_then(Value::as_array)
        .and_then(|row| row.get(x as usize))
        .and_then(|cell| cell.get("passable"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn connection_target(
    ctx: &ReducerContext,
    manifest: &Value,
    direction: &str,
    attempted_x: i32,
    attempted_y: i32,
) -> Result<(String, i32, i32), String> {
    let edge = match direction.trim().to_ascii_lowercase().as_str() {
        "north" | "up" => "up",
        "south" | "down" => "down",
        "west" | "left" => "left",
        "east" | "right" => "right",
        _ => return Err("Unknown edge direction".into()),
    };
    let connection = manifest
        .get("connections")
        .and_then(Value::as_array)
        .and_then(|items| {
            items
                .iter()
                .find(|item| item.get("direction").and_then(Value::as_str) == Some(edge))
        })
        .ok_or_else(|| format!("No connection at {edge} edge"))?;
    let map_constant = connection
        .get("map")
        .and_then(Value::as_str)
        .ok_or("Connection map missing")?;
    let offset = connection
        .get("offset")
        .and_then(Value::as_i64)
        .unwrap_or(0) as i32;
    let target_map = ctx
        .db
        .world_map()
        .map_constant()
        .find(map_constant.to_string())
        .ok_or_else(|| format!("Connected map {map_constant} is not seeded"))?;
    let (x, y) = match edge {
        "up" => (attempted_x - offset, target_map.height - 1),
        "down" => (attempted_x - offset, 0),
        "left" => (target_map.width - 1, attempted_y - offset),
        "right" => (0, attempted_y - offset),
        _ => unreachable!(),
    };
    let target_manifest: Value = serde_json::from_str(&target_map.manifest_json)
        .map_err(|error| format!("Stored target manifest is invalid: {error}"))?;
    if !cell_passable(&target_manifest, x, y) {
        return Err(format!(
            "Connected destination {} ({x},{y}) is blocked",
            target_map.map_name
        ));
    }
    Ok((target_map.map_name, x, y))
}

fn require_player(ctx: &ReducerContext) -> Result<Player, String> {
    ctx.db
        .player()
        .identity()
        .find(ctx.sender())
        .ok_or_else(|| "Join the world first".into())
}
