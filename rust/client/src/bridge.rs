#[path = "../generated/mod.rs"]
mod generated;

use std::collections::HashMap;

use generated::{
    DbConnection, NpcState, NpcStateTableAccess, Player, PlayerPosition, PlayerPositionTableAccess,
    PlayerTableAccess, WorldMapTableAccess, join_world, move_player, seed_world_map, use_doorway,
};
use godot::prelude::*;
use spacetimedb_sdk::{DbContext, Table, credentials};

const CLIENT_PROTOCOL: u32 = 1;
const DEFAULT_URI: &str = "http://127.0.0.1:3000";
const DEFAULT_DATABASE: &str = "tilegrove-dev";

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct TilegroveBridge {
    connection: Option<DbConnection>,
    connected: bool,
    subscribed: bool,
    status: String,
    last_error: String,
    #[base]
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for TilegroveBridge {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            connection: None,
            connected: false,
            subscribed: false,
            status: "disconnected".into(),
            last_error: String::new(),
            base,
        }
    }
}

#[godot_api]
impl TilegroveBridge {
    #[func]
    pub fn surface_name(&self) -> GString {
        "Tilegrove".into()
    }

    #[func]
    pub fn connect_local(&mut self, profile: GString) -> bool {
        self.connect_to(DEFAULT_URI.into(), DEFAULT_DATABASE.into(), profile)
    }

    #[func]
    pub fn connect_to(&mut self, uri: GString, database: GString, profile: GString) -> bool {
        self.connection = None;
        self.connected = false;
        self.subscribed = false;
        self.last_error.clear();
        self.status = "connecting".into();
        let uri = uri.to_string();
        let database = database.to_string();
        let key = credential_key(&uri, &database, &profile.to_string());
        let token = match credentials::File::new(&key).load() {
            Ok(token) => token,
            Err(error) => {
                self.last_error = format!("Could not load credentials: {error}");
                None
            }
        };
        let save_key = key.clone();
        match DbConnection::builder()
            .with_uri(uri)
            .with_database_name(database)
            .with_token(token)
            .on_connect(move |ctx, _identity, token| {
                if let Err(error) = credentials::File::new(&save_key).save(token.to_string()) {
                    godot_warn!("Could not save Tilegrove credentials: {}", error);
                }
                ctx.subscription_builder().subscribe([
                    "SELECT * FROM player",
                    "SELECT * FROM player_position",
                    "SELECT * FROM world_map",
                    "SELECT * FROM npc_state",
                ]);
            })
            .build()
        {
            Ok(connection) => {
                self.connection = Some(connection);
                self.connected = true;
                self.status = "connected".into();
                true
            }
            Err(error) => {
                self.status = "connect failed".into();
                self.last_error = error.to_string();
                false
            }
        }
    }

    #[func]
    pub fn poll(&mut self) {
        let Some(connection) = self.connection.as_ref() else {
            return;
        };
        match connection.frame_tick() {
            Ok(()) => {
                self.connected = connection.is_active();
                self.subscribed = self.connected;
                self.status = if self.connected {
                    "connected"
                } else {
                    "disconnected"
                }
                .into();
            }
            Err(error) => {
                self.connected = false;
                self.status = "disconnected".into();
                self.last_error = error.to_string();
            }
        }
    }

    #[func]
    pub fn join_world(&mut self, display_name: GString) -> bool {
        self.call(|connection| {
            connection
                .reducers
                .join_world(display_name.to_string(), CLIENT_PROTOCOL)
        })
    }

    #[func]
    pub fn seed_world_map(
        &mut self,
        map_name: GString,
        map_constant: GString,
        manifest_json: GString,
    ) -> bool {
        self.call(|connection| {
            connection.reducers.seed_world_map(
                map_name.to_string(),
                map_constant.to_string(),
                manifest_json.to_string(),
            )
        })
    }

    #[func]
    pub fn move_player(&mut self, direction: GString) -> bool {
        self.call(|connection| connection.reducers.move_player(direction.to_string()))
    }

    #[func]
    pub fn use_doorway(&mut self, target_id: GString) -> bool {
        self.call(|connection| connection.reducers.use_doorway(target_id.to_string()))
    }

    #[func]
    pub fn status(&self) -> GString {
        self.status.as_str().into()
    }
    #[func]
    pub fn last_error(&self) -> GString {
        self.last_error.as_str().into()
    }
    #[func]
    pub fn is_connected(&self) -> bool {
        self.connected
    }
    #[func]
    pub fn is_subscribed(&self) -> bool {
        self.subscribed
    }

    #[func]
    pub fn local_identity(&self) -> GString {
        self.connection
            .as_ref()
            .and_then(|connection| connection.try_identity())
            .map(|identity| GString::from(&identity.to_hex().to_string()))
            .unwrap_or_default()
    }

    #[func]
    pub fn world_map_count(&self) -> i64 {
        self.connection
            .as_ref()
            .map(|connection| connection.db.world_map().iter().count() as i64)
            .unwrap_or(0)
    }

    #[func]
    pub fn local_position(&self) -> Dictionary<Variant, Variant> {
        let Some(connection) = self.connection.as_ref() else {
            return Dictionary::new();
        };
        let Some(identity) = connection.try_identity() else {
            return Dictionary::new();
        };
        connection
            .db
            .player_position()
            .identity()
            .find(&identity)
            .map(|position| position_dictionary(None, &position))
            .unwrap_or_default()
    }

    #[func]
    pub fn players(&self) -> Array<Dictionary<Variant, Variant>> {
        let mut result = Array::new();
        let Some(connection) = self.connection.as_ref() else {
            return result;
        };
        let players = connection
            .db
            .player()
            .iter()
            .map(|player| (player.identity.to_hex().to_string(), player))
            .collect::<HashMap<_, _>>();
        for position in connection.db.player_position().iter() {
            result.push(&position_dictionary(
                players.get(&position.identity.to_hex().to_string()),
                &position,
            ));
        }
        result
    }

    #[func]
    pub fn npcs_on_map(&self, map_name: GString) -> Array<Dictionary<Variant, Variant>> {
        let mut result = Array::new();
        let Some(connection) = self.connection.as_ref() else {
            return result;
        };
        for npc in connection
            .db
            .npc_state()
            .iter()
            .filter(|npc| npc.map_name == map_name.to_string())
        {
            result.push(&npc_dictionary(&npc));
        }
        result
    }
}

impl TilegroveBridge {
    fn call<E>(&mut self, action: impl FnOnce(&DbConnection) -> Result<(), E>) -> bool
    where
        E: std::fmt::Display,
    {
        let Some(connection) = self.connection.as_ref() else {
            self.last_error = "Not connected".into();
            return false;
        };
        match action(connection) {
            Ok(()) => true,
            Err(error) => {
                self.last_error = error.to_string();
                false
            }
        }
    }
}

fn position_dictionary(
    player: Option<&Player>,
    position: &PlayerPosition,
) -> Dictionary<Variant, Variant> {
    let mut result = Dictionary::new();
    let identity = position.identity.to_hex().to_string();
    result.set("identity", identity.clone());
    result.set(
        "display_name",
        player
            .map(|row| row.display_name.clone())
            .unwrap_or_else(|| identity.chars().take(8).collect()),
    );
    result.set("online", player.map(|row| row.online).unwrap_or(false));
    result.set("map", position.map_name.clone());
    result.set("x", position.x);
    result.set("y", position.y);
    result.set("facing", position.facing.clone());
    result.set("revision", position.revision as i64);
    result.set(
        "updated_at_micros",
        position.updated_at.to_micros_since_unix_epoch(),
    );
    result
}

fn npc_dictionary(npc: &NpcState) -> Dictionary<Variant, Variant> {
    let mut result = Dictionary::new();
    result.set("id", npc.object_id.clone());
    result.set("map", npc.map_name.clone());
    result.set("spawn_x", npc.spawn_x);
    result.set("spawn_y", npc.spawn_y);
    result.set("x", npc.x);
    result.set("y", npc.y);
    result.set("facing", npc.facing.clone());
    result.set("movement_type", npc.movement_type.clone());
    result.set("revision", npc.revision as i64);
    result.set(
        "updated_at_micros",
        npc.updated_at.to_micros_since_unix_epoch(),
    );
    result
}

fn credential_key(uri: &str, database: &str, profile: &str) -> String {
    format!(
        "tilegrove-{}-{uri}-{database}",
        if profile.trim().is_empty() {
            "human"
        } else {
            profile.trim()
        }
    )
    .chars()
    .map(|c| {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            c
        } else {
            '_'
        }
    })
    .collect()
}
