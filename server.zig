const std = @import("std");
const pike = @import("pike/pike.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;
const atomic = std.atomic;

usingnamespace @import("socket.zig");

pub fn Server(comptime opts: Options) type {
    return struct {
        const Self = @This();

        const ServerSocket = Socket(.server, opts);
        const Protocol = opts.protocol_type;

        pub const Connection = struct {
            socket: ServerSocket,
            frame: @Frame(Self.runConnection),
        };

        protocol: Protocol,
        allocator: *mem.Allocator,
        notifier: *const pike.Notifier,
        socket: pike.Socket,

        lock: std.Mutex = .{},
        done: atomic.Bool = atomic.Bool.init(false),

        pool: [opts.max_connections_per_server]*Connection = undefined,
        pool_len: usize = 0,

        frame: @Frame(Self.run) = undefined,

        pub fn init(protocol: Protocol, allocator: *mem.Allocator, notifier: *const pike.Notifier, address: net.Address) !Self {
            var self = Self{
                .protocol = protocol,
                .allocator = allocator,
                .notifier = notifier,
                .socket = try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0),
            };
            errdefer self.socket.deinit();

            try self.socket.set(.reuse_address, true);
            try self.socket.bind(address);
            try self.socket.listen(128);

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (!self.done.xchg(true, .SeqCst)) {
                self.socket.deinit();
                await self.frame catch {};
                self.close();
            }
        }

        pub fn close(self: *Self) void {
            var pool: [opts.max_connections_per_server]*Connection = undefined;
            var pool_len: usize = 0;

            {
                const held = self.lock.acquire();
                defer held.release();

                pool = self.pool;
                pool_len = self.pool_len;
                self.pool = undefined;
                self.pool_len = 0;
            }

            for (pool[0..pool_len]) |conn| {
                conn.socket.deinit();
                await conn.frame catch {};
                self.allocator.destroy(conn);
            }
        }

        pub fn serve(self: *Self) !void {
            try self.socket.registerTo(self.notifier);
            self.frame = async self.run();
        }

        fn run(self: *Self) !void {
            yield();

            defer if (!self.done.xchg(true, .SeqCst)) {
                self.socket.deinit();
                self.close();
            };

            while (true) {
                self.accept() catch |err| switch (err) {
                    error.SocketNotListening,
                    error.OperationCancelled,
                    => return,
                    else => {
                        continue;
                    },
                };
            }
        }

        fn accept(self: *Self) !void {
            const conn = try self.allocator.create(Connection);
            errdefer self.allocator.destroy(conn);

            const peer = try self.socket.accept();

            conn.socket = ServerSocket.init(peer.socket, peer.address);
            errdefer conn.socket.deinit();

            try conn.socket.inner.registerTo(self.notifier);

            if (comptime meta.trait.hasFn("handshake")(Protocol)) {
                try self.protocol.handshake(.server, &conn.socket);
            }

            {
                const held = self.lock.acquire();
                defer held.release();

                if (self.pool_len == opts.max_connections_per_server) {
                    return error.MaxConnectionLimitExceeded;
                }

                self.pool[self.pool_len] = conn;
                self.pool_len += 1;
            }

            conn.frame = async self.runConnection(conn);
        }

        fn deinitConnection(self: *Self, conn: *Connection) void {
            if (self.deleteConnection(conn)) {
                conn.socket.deinit();
                await conn.frame catch {};
                self.allocator.destroy(conn);
            }
        }

        fn deleteConnection(self: *Self, conn: *Connection) bool {
            const held = self.lock.acquire();
            defer held.release();

            var pool = self.pool[0..self.pool_len];

            if (mem.indexOfScalar(*Connection, pool, conn)) |i| {
                mem.copy(*Connection, pool[i..], pool[i + 1 ..]);
                self.pool_len -= 1;
                return true;
            }

            return false;
        }

        fn runConnection(self: *Self, conn: *Connection) !void {
            defer if (self.deleteConnection(conn)) {
                conn.socket.inner.deinit();
                suspend {
                    self.allocator.destroy(conn);
                }
            };

            try conn.socket.run(self.protocol);
        }
    };
}
