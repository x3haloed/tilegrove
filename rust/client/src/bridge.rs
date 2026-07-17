#[path = "../generated/mod.rs"]
mod generated;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use generated::{
    BoardNoteTableAccess, DbConnection, NpcState, NpcStateTableAccess, Player, PlayerPosition,
    PlayerPositionTableAccess, PlayerPresenceTableAccess, PlayerTableAccess, WorldChatTableAccess,
    WorldMapTableAccess, WorldTrace, WorldTraceTableAccess, delete_board_note, edit_board_note,
    face_player, gesture_player, join_world, move_player, post_board_note, seed_world_map,
    send_world_chat, set_board_note_status, use_doorway,
};
use godot::prelude::*;
use spacetimedb_sdk::__codegen::InternalError;
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
    next_board_action_id: u64,
    board_action_results: Arc<Mutex<HashMap<u64, Option<String>>>>,
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
            next_board_action_id: 1,
            board_action_results: Arc::new(Mutex::new(HashMap::new())),
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
                    "SELECT * FROM player_presence",
                    "SELECT * FROM world_chat",
                    "SELECT * FROM board_note",
                    "SELECT * FROM world_map",
                    "SELECT * FROM npc_state",
                    "SELECT * FROM world_trace",
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
    pub fn face_player(&mut self, direction: GString) -> bool {
        self.call(|connection| connection.reducers.face_player(direction.to_string()))
    }

    #[func]
    pub fn gesture_player(&mut self, gesture: GString) -> bool {
        self.call(|connection| connection.reducers.gesture_player(gesture.to_string()))
    }

    #[func]
    pub fn send_world_chat(&mut self, text: GString) -> bool {
        self.call(|connection| connection.reducers.send_world_chat(text.to_string()))
    }

    #[func]
    pub fn post_board_note(&mut self, board_id: GString, title: GString, body: GString) -> bool {
        self.call(|connection| {
            connection.reducers.post_board_note(
                board_id.to_string(),
                title.to_string(),
                body.to_string(),
            )
        })
    }

    #[func]
    pub fn edit_board_note(&mut self, note_id: i64, title: GString, body: GString) -> bool {
        self.call(|connection| {
            connection
                .reducers
                .edit_board_note(note_id as u64, title.to_string(), body.to_string())
        })
    }

    #[func]
    pub fn delete_board_note(&mut self, note_id: i64) -> bool {
        self.call(|connection| connection.reducers.delete_board_note(note_id as u64))
    }

    #[func]
    pub fn set_board_note_status(
        &mut self,
        note_id: i64,
        status: GString,
        resolution: GString,
    ) -> bool {
        self.call(|connection| {
            connection.reducers.set_board_note_status(
                note_id as u64,
                status.to_string(),
                resolution.to_string(),
            )
        })
    }

    #[func]
    pub fn begin_board_action(
        &mut self,
        action: GString,
        board_id: GString,
        note_id: i64,
        title: GString,
        body: GString,
        resolution: GString,
    ) -> i64 {
        let Some(connection) = self.connection.as_ref() else {
            self.last_error = "Not connected".into();
            return 0;
        };
        let action_id = self.next_board_action_id;
        self.next_board_action_id = self.next_board_action_id.saturating_add(1);
        self.board_action_results
            .lock()
            .unwrap()
            .insert(action_id, None);
        let results = Arc::clone(&self.board_action_results);
        let callback = move |result: Result<Result<(), String>, InternalError>| {
            let message = match result {
                Ok(Ok(())) => String::new(),
                Ok(Err(error)) => error,
                Err(error) => error.to_string(),
            };
            results.lock().unwrap().insert(action_id, Some(message));
        };
        let action = action.to_string();
        let dispatch = match action.as_str() {
            "post" => connection.reducers.post_board_note_then(
                board_id.to_string(),
                title.to_string(),
                body.to_string(),
                move |_, result| callback(result),
            ),
            "edit" => connection.reducers.edit_board_note_then(
                note_id as u64,
                title.to_string(),
                body.to_string(),
                move |_, result| callback(result),
            ),
            "delete" => connection
                .reducers
                .delete_board_note_then(note_id as u64, move |_, result| callback(result)),
            "open" | "claimed" | "done" | "declined" => {
                connection.reducers.set_board_note_status_then(
                    note_id as u64,
                    action,
                    resolution.to_string(),
                    move |_, result| callback(result),
                )
            }
            _ => {
                self.board_action_results.lock().unwrap().remove(&action_id);
                self.last_error = "Unknown board action".into();
                return 0;
            }
        };
        if let Err(error) = dispatch {
            self.board_action_results.lock().unwrap().remove(&action_id);
            self.last_error = error.to_string();
            return 0;
        }
        action_id as i64
    }

    #[func]
    pub fn board_action_result(&self, action_id: i64) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        let state = self
            .board_action_results
            .lock()
            .unwrap()
            .get(&(action_id as u64))
            .cloned();
        match state {
            Some(None) => {
                result.set("complete", false);
            }
            Some(Some(error)) => {
                result.set("complete", true);
                result.set("ok", error.is_empty());
                result.set("error", error);
            }
            None => {
                result.set("complete", true);
                result.set("ok", false);
                result.set("error", "Unknown board action operation.");
            }
        }
        result
    }

    #[func]
    pub fn forget_board_action_result(&mut self, action_id: i64) {
        self.board_action_results
            .lock()
            .unwrap()
            .remove(&(action_id as u64));
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
        let presences = connection
            .db
            .player_presence()
            .iter()
            .map(|presence| (presence.identity.to_hex().to_string(), presence))
            .collect::<HashMap<_, _>>();
        for position in connection.db.player_position().iter() {
            let mut dictionary = position_dictionary(
                players.get(&position.identity.to_hex().to_string()),
                &position,
            );
            if let Some(presence) = presences.get(&position.identity.to_hex().to_string()) {
                dictionary.set("gesture", presence.gesture.clone());
                dictionary.set("gesture_revision", presence.gesture_revision as i64);
            } else {
                dictionary.set("gesture", "");
                dictionary.set("gesture_revision", 0i64);
            }
            result.push(&dictionary);
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

    #[func]
    pub fn traces_on_map(&self, map_name: GString) -> Array<Dictionary<Variant, Variant>> {
        let mut traces = self
            .connection
            .as_ref()
            .map(|connection| {
                connection
                    .db
                    .world_trace()
                    .iter()
                    .filter(|trace| trace.map_name == map_name.to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        traces.sort_by_key(|trace| trace.sequence);
        traces.iter().map(trace_dictionary).collect()
    }

    #[func]
    pub fn chat_messages(&self) -> Array<Dictionary<Variant, Variant>> {
        let mut messages = self
            .connection
            .as_ref()
            .map(|connection| connection.db.world_chat().iter().collect::<Vec<_>>())
            .unwrap_or_default();
        messages.sort_by_key(|message| message.sequence);
        messages
            .iter()
            .rev()
            .take(50)
            .rev()
            .map(|message| {
                let mut result = Dictionary::new();
                result.set("sequence", message.sequence as i64);
                result.set("sender", message.sender.to_hex().to_string());
                result.set("display_name", message.display_name.clone());
                result.set("map", message.map_name.clone());
                result.set("x", message.x);
                result.set("y", message.y);
                result.set("text", message.text.clone());
                result.set(
                    "created_at_micros",
                    message.created_at.to_micros_since_unix_epoch(),
                );
                result
            })
            .collect()
    }

    #[func]
    pub fn board_notes(&self, board_id: GString) -> Array<Dictionary<Variant, Variant>> {
        let mut notes = self
            .connection
            .as_ref()
            .map(|connection| {
                connection
                    .db
                    .board_note()
                    .iter()
                    .filter(|note| note.board_id == board_id.to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        notes.sort_by_key(|note| note.note_id);
        notes
            .iter()
            .map(|note| {
                let mut result = Dictionary::new();
                result.set("note_id", note.note_id as i64);
                result.set("board_id", note.board_id.clone());
                result.set("author", note.author.to_hex().to_string());
                result.set("author_name", note.author_name.clone());
                result.set("title", note.title.clone());
                result.set("body", note.body.clone());
                result.set("status", note.status.clone());
                result.set(
                    "claimant",
                    note.claimant
                        .map(|identity| identity.to_hex().to_string())
                        .unwrap_or_default(),
                );
                result.set("claimant_name", note.claimant_name.clone());
                result.set("resolution", note.resolution.clone());
                result.set("last_actor", note.last_actor.to_hex().to_string());
                result.set("last_actor_name", note.last_actor_name.clone());
                result.set(
                    "created_at_micros",
                    note.created_at.to_micros_since_unix_epoch(),
                );
                result.set(
                    "updated_at_micros",
                    note.updated_at.to_micros_since_unix_epoch(),
                );
                result
            })
            .collect()
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

fn trace_dictionary(trace: &WorldTrace) -> Dictionary<Variant, Variant> {
    let mut result = Dictionary::new();
    result.set("source_id", trace.source_id.clone());
    result.set("map", trace.map_name.clone());
    result.set("x", trace.x);
    result.set("y", trace.y);
    result.set("sequence", trace.sequence as i64);
    result.set(
        "created_at_micros",
        trace.created_at.to_micros_since_unix_epoch(),
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
