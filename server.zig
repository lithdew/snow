const std = @import("std");
const pike = @import("pike");
const sync = @import("sync.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;
const atomic = std.atomic;

const snow_sock = @import("socket.zig");

pub fn Server(comptime opts: snow_sock.Options) type {
    return struct {
        const Self = @This();

        const Node = struct {
            ptr: *Connection,
            next: ?*Node = null,
        };

        const ServerSocket = snow_sock.Socket(.server, opts);
        const Protocol = opts.protocol_type;

        pub const Connection = struct {
            node: Node,
            socket: ServerSocket,
            frame: @Frame(Self.runConnection),
        };

        protocol: Protocol,
        allocator: *mem.Allocator,
        notifier: *const pike.Notifier,
        socket: pike.Socket,

        lock: sync.Mutex = .{},
        done: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),

        pool: [opts.max_connections_per_server]*Connection = undefined,
        pool_len: usize = 0,

        cleanup_counter: sync.Counter = .{},
        cleanup_queue: ?*Node = null,

        frame: @Frame(Self.run) = undefined,

        pub fn init(protocol: Protocol, allocator: *mem.Allocator, notifier: *const pike.Notifier, address: net.Address) !Self {
            var self = Self{
                .protocol = protocol,
                .allocator = allocator,
                .notifier = notifier,
                .socket = try pike.Socket.init(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP, 0),
            };
            errdefer self.socket.deinit();

            try self.socket.set(.reuse_address, true);
            try self.socket.bind(address);
            try self.socket.listen(128);

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.done.swap(true, .SeqCst)) return;

            self.socket.deinit();
            await self.frame catch {};

            self.close();

            self.cleanup_counter.wait();
            self.purge();
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

                if (comptime meta.trait.hasFn("close")(Protocol)) {
                    self.protocol.close(.server, &conn.socket);
                }
            }
        }

        pub fn purge(self: *Self) void {
            const held = self.lock.acquire();
            defer held.release();

            while (self.cleanup_queue) |head| {
                await head.ptr.frame catch {};
                self.cleanup_queue = head.next;

                if (comptime meta.trait.hasFn("purge")(Protocol)) {
                    var items: [opts.write_queue_size]opts.message_type = undefined;

                    const queue = &head.ptr.socket.write_queue;
                    const remaining = queue.tail -% queue.head;

                    var i: usize = 0;
                    while (i < remaining) : (i += 1) {
                        items[i] = queue.items[(queue.head + i) % queue.items.len];
                    }

                    queue.head = queue.tail;

                    self.protocol.purge(.server, &head.ptr.socket, items[0..remaining]);
                }

                self.allocator.destroy(head.ptr);
            }
        }

        fn cleanup(self: *Self, node: *Node) void {
            const held = self.lock.acquire();
            defer held.release();

            node.next = self.cleanup_queue;
            self.cleanup_queue = node;
        }

        pub fn serve(self: *Self) !void {
            try self.socket.registerTo(self.notifier);
            self.frame = async self.run();
        }

        fn run(self: *Self) !void {
            snow_sock.yield();

            defer if (!self.done.swap(true, .SeqCst)) {
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

                self.purge();
            }
        }

        fn accept(self: *Self) !void {
            self.cleanup_counter.add(1);
            errdefer self.cleanup_counter.add(-1);

            const conn = try self.allocator.create(Connection);
            errdefer self.allocator.destroy(conn);

            conn.node = .{ .ptr = conn };

            const peer = try self.socket.accept();

            conn.socket = ServerSocket.init(peer.socket, peer.address);
            errdefer conn.socket.deinit();

            try conn.socket.unwrap().registerTo(self.notifier);

            {
                const held = self.lock.acquire();
                defer held.release();

                if (self.pool_len + 1 == opts.max_connections_per_server) {
                    return error.MaxConnectionLimitExceeded;
                }

                self.pool[self.pool_len] = conn;
                self.pool_len += 1;
            }

            conn.frame = async self.runConnection(conn);
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
            defer {
                if (self.deleteConnection(conn)) {
                    conn.socket.deinit();

                    if (comptime meta.trait.hasFn("close")(Protocol)) {
                        self.protocol.close(.server, &conn.socket);
                    }
                }

                self.cleanup(&conn.node);
                self.cleanup_counter.add(-1);
            }

            snow_sock.yield();

            if (comptime meta.trait.hasFn("handshake")(Protocol)) {
                conn.socket.context = try self.protocol.handshake(.server, &conn.socket.inner);
            }

            try conn.socket.run(self.protocol);
        }
    };
}
