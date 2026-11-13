//! Encrypted secret store: a 0600 keyfile holding a random master key, and a
//! store file sealed as one ChaCha20-Poly1305 blob with a per-write subkey.
//!
//! Store file layout (all lengths in bytes):
//!
//!     magic (8) | salt (32) | nonce (12) | ciphertext | tag (16)
//!
//! The subkey is HKDF-SHA256(salt, master key, "venom-secrets v1 store"), and
//! the header (magic, salt, nonce) is the associated data, so every byte of
//! the file is authenticated. The plaintext is
//!
//!     count: u32 | count × (name_len: u16 | name | value_len: u32 | value)
//!
//! little-endian, with names strictly ascending. Names are not secret but are
//! encrypted anyway, so the file reveals only its size.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const reference = @import("reference.zig");

pub const key_length = 32;
pub const magic = "VNMSEC01";
const salt_length = 32;
const header_length = magic.len + salt_length + Aead.nonce_length;
const kdf_info = "venom-secrets v1 store";

pub const max_name = reference.max_name;
pub const max_value = 64 * 1024;
pub const max_entries = 1024;
const max_file = header_length + Aead.tag_length + 4 + max_entries * (2 + max_name + 4 + max_value);

/// The keyfile and the store file are owner-only.
const private: Io.File.Permissions = .fromMode(0o600);

pub const Error = error{
    /// Not `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.
    InvalidName,
    ValueTooLarge,
    TooManySecrets,
    /// The keyfile is not a regular file, or group/other can access it.
    InsecureKeyfile,
    /// The keyfile is not exactly `key_length` bytes.
    InvalidKeyfile,
    /// The store file is truncated, has the wrong magic, or its plaintext is
    /// malformed.
    InvalidStore,
    /// The store file was modified, or was sealed with another key.
    AuthenticationFailed,
    SecretNotFound,
    /// Not a `secret:<name>` reference.
    InvalidReference,
};

/// The master key. Call `wipe` when done with it.
pub const Key = struct {
    bytes: [key_length]u8,

    pub fn wipe(self: *Key) void {
        std.crypto.secureZero(u8, &self.bytes);
    }

    /// Reads the keyfile at `sub_path`, creating it with a fresh random key
    /// and mode 0600 if it does not exist. A keyfile that group or other can
    /// access is refused, not repaired.
    pub fn loadOrCreate(io: Io, dir: Io.Dir, sub_path: []const u8) !Key {
        return load(io, dir, sub_path) catch |err| switch (err) {
            error.FileNotFound => create(io, dir, sub_path) catch |e| switch (e) {
                // Lost a race with another process: use its key.
                error.PathAlreadyExists => load(io, dir, sub_path),
                else => e,
            },
            else => err,
        };
    }

    pub fn load(io: Io, dir: Io.Dir, sub_path: []const u8) !Key {
        const file = try dir.openFile(io, sub_path, .{ .allow_directory = false });
        defer file.close(io);
        const st = try file.stat(io);
        if (st.kind != .file or st.permissions.toMode() & 0o077 != 0) return error.InsecureKeyfile;
        if (st.size != key_length) return error.InvalidKeyfile;
        var key: Key = undefined;
        errdefer key.wipe();
        if (try file.readPositionalAll(io, &key.bytes, 0) != key_length) return error.InvalidKeyfile;
        return key;
    }

    fn create(io: Io, dir: Io.Dir, sub_path: []const u8) !Key {
        var key: Key = undefined;
        try io.randomSecure(&key.bytes);
        errdefer key.wipe();
        const file = try dir.createFile(io, sub_path, .{ .exclusive = true, .permissions = private });
        defer file.close(io);
        errdefer dir.deleteFile(io, sub_path) catch {};
        // umask can only clear bits, but make the mode explicit regardless.
        try file.setPermissions(io, private);
        try file.writeStreamingAll(io, &key.bytes);
        try file.sync(io);
        return key;
    }
};

pub const validName = reference.validName;

fn deriveSubkey(key: *const Key, salt: *const [salt_length]u8) [Aead.key_length]u8 {
    var prk = Hkdf.extract(salt, &key.bytes);
    defer std.crypto.secureZero(u8, &prk);
    var subkey: [Aead.key_length]u8 = undefined;
    Hkdf.expand(&subkey, kdf_info, prk);
    return subkey;
}

/// Encrypts `plaintext` into a new store-file blob owned by the caller.
pub fn seal(gpa: Allocator, io: Io, key: *const Key, plaintext: []const u8) ![]u8 {
    const blob = try gpa.alloc(u8, header_length + plaintext.len + Aead.tag_length);
    @memcpy(blob[0..magic.len], magic);
    io.random(blob[magic.len..header_length]);
    const header = blob[0..header_length];
    var subkey = deriveSubkey(key, header[magic.len..][0..salt_length]);
    defer std.crypto.secureZero(u8, &subkey);
    const tag = blob[header_length + plaintext.len ..][0..Aead.tag_length];
    Aead.encrypt(blob[header_length..][0..plaintext.len], tag, plaintext, header, header[magic.len + salt_length ..][0..Aead.nonce_length].*, subkey);
    return blob;
}

/// Decrypts a store-file blob. The caller must `secureZero` and free the
/// returned plaintext.
pub fn unseal(gpa: Allocator, key: *const Key, blob: []const u8) ![]u8 {
    if (blob.len < header_length + Aead.tag_length or !std.mem.eql(u8, blob[0..magic.len], magic)) return error.InvalidStore;
    const header = blob[0..header_length];
    const body = blob[header_length .. blob.len - Aead.tag_length];
    var subkey = deriveSubkey(key, header[magic.len..][0..salt_length]);
    defer std.crypto.secureZero(u8, &subkey);
    const plaintext = try gpa.alloc(u8, body.len);
    errdefer gpa.free(plaintext);
    Aead.decrypt(plaintext, body, blob[blob.len - Aead.tag_length ..][0..Aead.tag_length].*, header, header[magic.len + salt_length ..][0..Aead.nonce_length].*, subkey) catch {
        std.crypto.secureZero(u8, plaintext);
        return error.AuthenticationFailed;
    };
    return plaintext;
}

/// Secrets held in memory, decrypted. Every mutation is persisted atomically
/// before it returns; on failure the store is left as it was. Values are
/// zeroed when replaced, removed, or on `deinit`. Nothing here logs.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    path: []u8,
    key: Key,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { name: []u8, value: []u8 };

    pub const Options = struct {
        /// The store file, relative to `dir`.
        store: []const u8 = "secrets.bin",
        /// The keyfile, relative to `dir`. Created on first use.
        keyfile: []const u8 = "secrets.key",
    };

    /// Opens (or starts) the store in `dir`, which must outlive the store.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) !Store {
        var key = try Key.loadOrCreate(io, dir, options.keyfile);
        errdefer key.wipe();
        return openWithKey(gpa, io, dir, options.store, key);
    }

    /// Opens the store with an explicit key (e.g. from an OS keyring). The
    /// store takes ownership of `key` and wipes it on `deinit`.
    pub fn openWithKey(gpa: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, key: Key) !Store {
        var self: Store = .{ .gpa = gpa, .io = io, .dir = dir, .path = try gpa.dupe(u8, sub_path), .key = key };
        errdefer self.deinit();
        const blob = dir.readFileAlloc(io, sub_path, gpa, .limited(max_file)) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        defer gpa.free(blob);
        const plaintext = try unseal(gpa, &self.key, blob);
        defer {
            std.crypto.secureZero(u8, plaintext);
            gpa.free(plaintext);
        }
        try self.decode(plaintext);
        return self;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.deinit(self.gpa);
        self.gpa.free(self.path);
        self.key.wipe();
        self.* = undefined;
    }

    pub fn get(self: *const Store, name: []const u8) ?[]const u8 {
        const i = self.find(name) orelse return null;
        return self.entries.items[i].value;
    }

    /// Resolves a `secret:<name>` reference, as held by `cfg` secret fields.
    pub fn resolve(self: *const Store, ref: []const u8) Error![]const u8 {
        const name = reference.parse(ref) orelse return error.InvalidReference;
        return self.get(name) orelse error.SecretNotFound;
    }

    /// The `cfg.SecretStore` adapter (`cfg.SecretStore.init(&store)`): stores
    /// `secret` under a new random name and returns its reference,
    /// `secret:cfg-<32 hex>`, allocated with `a`. It never overwrites an
    /// existing entry. `key`, the config path, is not part of the name.
    pub fn put(self: *Store, a: Allocator, key: []const u8, secret: []const u8) anyerror![]const u8 {
        _ = key;
        var name: [4 + 32]u8 = undefined;
        while (true) {
            var raw: [16]u8 = undefined;
            self.io.random(&raw);
            name = ("cfg-" ++ std.fmt.bytesToHex(raw, .lower)).*;
            if (self.get(&name) == null) break;
        }
        _ = try self.set(&name, secret);
        return std.fmt.allocPrint(a, reference.prefix ++ "{s}", .{&name});
    }

    /// The secrets, sorted by name. Invalidated by any mutation.
    pub fn list(self: *const Store) []const Entry {
        return self.entries.items;
    }

    /// Adds or replaces a secret. Returns true if it was new.
    pub fn set(self: *Store, name: []const u8, value: []const u8) !bool {
        if (!validName(name)) return error.InvalidName;
        if (value.len > max_value) return error.ValueTooLarge;
        const copy = try self.gpa.dupe(u8, value);
        errdefer wipeFree(self.gpa, copy);
        const at = self.lowerBound(name);
        if (at < self.entries.items.len and std.mem.eql(u8, self.entries.items[at].name, name)) {
            const old = self.entries.items[at].value;
            self.entries.items[at].value = copy;
            self.persist() catch |err| {
                self.entries.items[at].value = old;
                return err;
            };
            wipeFree(self.gpa, old);
            return false;
        }
        if (self.entries.items.len >= max_entries) return error.TooManySecrets;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.entries.insert(self.gpa, at, .{ .name = owned, .value = copy });
        self.persist() catch |err| {
            _ = self.entries.orderedRemove(at);
            return err;
        };
        return true;
    }

    /// Removes a secret. Returns false if there was none by that name.
    pub fn remove(self: *Store, name: []const u8) !bool {
        const at = self.find(name) orelse return false;
        const entry = self.entries.orderedRemove(at);
        self.persist() catch |err| {
            self.entries.insert(self.gpa, at, entry) catch unreachable; // capacity is retained
            return err;
        };
        self.freeEntry(entry);
        return true;
    }

    fn find(self: *const Store, name: []const u8) ?usize {
        const at = self.lowerBound(name);
        if (at < self.entries.items.len and std.mem.eql(u8, self.entries.items[at].name, name)) return at;
        return null;
    }

    fn lowerBound(self: *const Store, name: []const u8) usize {
        return std.sort.lowerBound(Entry, self.entries.items, name, struct {
            fn order(key: []const u8, e: Entry) std.math.Order {
                return std.mem.order(u8, key, e.name);
            }
        }.order);
    }

    fn freeEntry(self: *Store, e: Entry) void {
        self.gpa.free(e.name);
        wipeFree(self.gpa, e.value);
    }

    fn persist(self: *Store) !void {
        const plaintext = try self.encode();
        defer wipeFree(self.gpa, plaintext);
        const blob = try seal(self.gpa, self.io, &self.key, plaintext);
        defer self.gpa.free(blob);
        var atomic = try self.dir.createFileAtomic(self.io, self.path, .{ .permissions = private, .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, blob);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }

    fn encode(self: *const Store) ![]u8 {
        var len: usize = 4;
        for (self.entries.items) |e| len += 2 + e.name.len + 4 + e.value.len;
        const out = try self.gpa.alloc(u8, len);
        var w: usize = 0;
        std.mem.writeInt(u32, out[w..][0..4], @intCast(self.entries.items.len), .little);
        w += 4;
        for (self.entries.items) |e| {
            std.mem.writeInt(u16, out[w..][0..2], @intCast(e.name.len), .little);
            w += 2;
            @memcpy(out[w..][0..e.name.len], e.name);
            w += e.name.len;
            std.mem.writeInt(u32, out[w..][0..4], @intCast(e.value.len), .little);
            w += 4;
            @memcpy(out[w..][0..e.value.len], e.value);
            w += e.value.len;
        }
        return out;
    }

    fn decode(self: *Store, bytes: []const u8) !void {
        var r: usize = 0;
        const count = try readInt(u32, bytes, &r);
        if (count > max_entries) return error.InvalidStore;
        try self.entries.ensureTotalCapacity(self.gpa, count);
        for (0..count) |_| {
            const name = try readBytes(bytes, &r, try readInt(u16, bytes, &r));
            const value = try readBytes(bytes, &r, try readInt(u32, bytes, &r));
            if (!validName(name) or value.len > max_value) return error.InvalidStore;
            if (self.entries.items.len > 0 and std.mem.order(u8, self.entries.getLast().name, name) != .lt) return error.InvalidStore;
            const owned_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned_name);
            const owned_value = try self.gpa.dupe(u8, value);
            self.entries.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
        }
        if (r != bytes.len) return error.InvalidStore;
    }
};

fn readInt(comptime T: type, bytes: []const u8, r: *usize) !T {
    const n = @sizeOf(T);
    if (bytes.len - r.* < n) return error.InvalidStore;
    defer r.* += n;
    return std.mem.readInt(T, bytes[r.*..][0..n], .little);
}

fn readBytes(bytes: []const u8, r: *usize, n: usize) ![]const u8 {
    if (bytes.len - r.* < n) return error.InvalidStore;
    defer r.* += n;
    return bytes[r.*..][0..n];
}

fn wipeFree(gpa: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    gpa.free(bytes);
}
