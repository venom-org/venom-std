//! The local protocol: secure Unix sockets, poll reactor, first-byte
//! routing, bounded framing and hello (transport), plus NDJSON verb dispatch
//! against a verb model, caller identity/grants and audit.
pub const SocketOptions = @import("os.zig").SocketOptions;
pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").Options;
pub const Handler = @import("server.zig").Handler;
pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").Options;
pub const HelloOptions = @import("hello.zig").Options;
pub const Identity = @import("hello.zig").Identity;
pub const Connection = @import("wire.zig").Connection;
pub const Protocol = @import("wire.zig").Protocol;
pub const Message = @import("wire.zig").Message;
pub const Frame = @import("wire.zig").Frame;
pub const Kind = @import("wire.zig").Kind;
pub const errors = @import("errors.zig");
pub const schema = @import("schema.zig");
pub const Dispatcher = @import("dispatch.zig").Dispatcher;
pub const DispatcherOptions = @import("dispatch.zig").Options;
pub const VerbHandler = @import("dispatch.zig").VerbHandler;
pub const Binding = @import("dispatch.zig").Binding;
pub const Call = @import("dispatch.zig").Call;
pub const Ticket = @import("dispatch.zig").Ticket;
pub const Id = @import("dispatch.zig").Id;
pub const parseRequest = @import("dispatch.zig").parseRequest;
pub const Response = @import("response.zig").Response;
pub const default_max_frame = @import("wire.zig").default_max_frame;
pub const hard_max_frame = @import("wire.zig").hard_max_frame;

test {
    _ = @import("tests.zig");
    _ = @import("grants_tests.zig");
    _ = @import("managers.zig");
    _ = @import("bound.zig");
    _ = @import("errors.zig");
    _ = @import("schema.zig");
    _ = @import("dispatch.zig");
    _ = @import("response.zig");
}

pub const grants = @import("grants.zig");
pub const process = @import("process.zig");
pub const managers = @import("managers.zig");
pub const bound = @import("bound.zig");
pub const audit = @import("audit.zig");

pub const grant_verbs = @import("grant_verbs.zig");

pub const authorizePath = @import("paths.zig").authorize;

pub const events = @import("events.zig");
test {
    _ = events;
}

/// Canonical destination path (symlinks resolved, missing leaves allowed).
pub const canonicalPath = @import("paths.zig").canonical;
/// POSIX helpers shared with the `cli` bundles (doctor checks).
pub const os = @import("os.zig");
