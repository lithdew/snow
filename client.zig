const std = @import("std");
const pike = @import("pike/pike.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

usingnamespace @import("socket.zig");

pub fn Client(comptime opts: Options) type {
    return struct {
        const Self = @This();

        const ClientSocket = Socket(.client, opts);
        const Protocol = opts.protocol_type;

        pub const Connection = struct {
            socket: ClientSocket,
            frame: @Frame(Self.runConnection),
        };

        protocol: Protocol,
        notifier: *const pike.Notifier,
        allocator: *mem.Allocator,
        address: net.Address,

        lock: std.Mutex = .{},
        done: bool = false,

        pool: [opts.max_connections_per_client]*Connection = undefined,
        pool_len: usize = 0,

        pub fn init(protocol: Protocol, allocator: *mem.Allocator, notifier: *const pike.Notifier, address: net.Address) Self {
            return Self{ .protocol = protocol, .allocator = allocator, .notifier = notifier, .address = address };
        }

        pub fn deinit(self: *Self) void {
            var pool: [opts.max_connections_per_client]*Connection = undefined;
            var pool_len: usize = 0;

            {
                const held = self.lock.acquire();
                defer held.release();

                if (self.done) return;
                self.done = true;

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

        pub fn write(self: *Self, message: opts.message_type) !void {
            const conn = try self.getConnection();
            try conn.socket.write(message);
        }

        fn initConnection(self: *Self) !*Connection {
            const conn = try self.allocator.create(Connection);
            errdefer self.allocator.destroy(conn);

            conn.socket = ClientSocket.init(
                try pike.Socket.init(os.AF_INET, os.SOCK_STREAM, os.IPPROTO_TCP, 0),
                self.address,
            );
            errdefer conn.socket.deinit();

            try conn.socket.inner.registerTo(self.notifier);
            try conn.socket.inner.connect(conn.socket.address);

            if (comptime meta.trait.hasFn("handshake")(Protocol)) {
                try self.protocol.handshake(.client, &conn.socket);
            }

            self.pool[self.pool_len] = conn;
            self.pool_len += 1;

            conn.frame = async self.runConnection(conn);

            return conn;
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

        fn getConnection(self: *Self) !*Connection {
            const held = self.lock.acquire();
            defer held.release();

            if (self.done) return error.OperationCancelled;

            var pool = self.pool[0..self.pool_len];
            if (pool.len == 0) return self.initConnection();

            var min_conn = pool[0];
            var min_pending = min_conn.socket.write_queue.pending();
            if (min_pending == 0) return min_conn;

            for (pool[1..]) |conn| {
                const pending = conn.socket.write_queue.pending();
                if (pending == 0) return conn;
                if (pending < min_pending) {
                    min_conn = conn;
                    min_pending = pending;
                }
            }

            if (pool.len < opts.max_connections_per_client) {
                return self.initConnection();
            }

            return min_conn;
        }

        fn runConnection(self: *Self, conn: *Connection) !void {
            yield();
            
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
