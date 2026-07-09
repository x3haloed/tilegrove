mod bridge;

use godot::prelude::*;

struct TilegroveExtension;

#[gdextension]
unsafe impl ExtensionLibrary for TilegroveExtension {}
