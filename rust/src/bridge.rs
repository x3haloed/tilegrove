use godot::prelude::*;

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct TilegroveBridge {
    #[base]
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for TilegroveBridge {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl TilegroveBridge {
    #[func]
    pub fn surface_name(&self) -> GString {
        "Tilegrove".into()
    }
}
