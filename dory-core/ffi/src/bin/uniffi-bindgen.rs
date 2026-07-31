//! The UniFFI bindings generator for this crate. Build the cdylib, then:
//!   cargo run -p dory-ffi --features bindgen --bin uniffi-bindgen -- \
//!     generate --library target/debug/libdory_ffi.dylib --language swift --out-dir <dir>
fn main() {
    uniffi::uniffi_bindgen_main()
}
