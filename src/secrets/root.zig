//! secrets: secrets such as API keys and tokens, encrypted at rest with
//! ChaCha20-Poly1305 (`std.crypto`).
//!
//! The master key lives in a 0600 keyfile (OS keyring integration comes
//! later; `Store.openWithKey` takes a key from elsewhere).
//!
//! Config refers to a secret with one convention, the string
//! `secret:<name>` (`reference`), in a `cfg` secret field:
//! `.api_key = "secret:anthropic"`. Store the value with `secrets.set`, or
//! pass `cfg.SecretStore.init(&store)` so `config set` stores plaintext here
//! under a fresh `cfg-<hex>` name and persists only the reference. Resolve
//! references with `Store.resolve`.
//!
//! A product adds the verbs to its schema and binds the handlers:
//!
//! ```zig
//! const App = cli.Generator(.{ ..., .verbs = input.verbs ++ secrets.manifest });
//! var store = try secrets.Store.open(gpa, io, data_dir, .{});
//! defer store.deinit();
//! var handlers: secrets.Handlers = .init(&store);
//! const b = handlers.bindings(); // pass alongside the product's own bindings
//! ```
//!
//! Values are never logged, and decrypted buffers and keys are zeroed after use.

const store = @import("store.zig");
const verbs = @import("verbs.zig");

pub const Store = store.Store;
pub const Key = store.Key;
pub const Error = store.Error;
pub const reference = @import("reference.zig");
pub const validName = reference.validName;
pub const seal = store.seal;
pub const unseal = store.unseal;
pub const max_name = store.max_name;
pub const max_value = store.max_value;
pub const max_entries = store.max_entries;
pub const magic = store.magic;

/// The `secrets.set|get|list|rm` verb records (ZON verb-schema form), each
/// requiring the `admin` grant. Concatenate onto a product's `verbs`.
pub const manifest = @import("verbs.zon");
pub const Handlers = verbs.Handlers;

test {
    _ = @import("tests.zig");
    _ = reference;
}
