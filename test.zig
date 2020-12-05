const std = @import("std");
const sync = @import("sync.zig");
const pike = @import("pike/pike.zig");

const net = std.net;
const mem = std.mem;
const testing = std.testing;

usingnamespace @import("socket.zig");
usingnamespace @import("client.zig");
usingnamespace @import("server.zig");

test "client / server" {
    const Protocol = struct {
        const Self = @This();

        event: sync.Event = .{},

        pub fn deinit(self: *Self) void {
            self.event.notify();
            self.* = undefined;
        }

        pub fn read(self: *Self, side: Side, socket: anytype, reader: anytype) !void {
            while (true) {
                const line = try reader.readLine();
                defer reader.shift(line.len);

                self.event.notify();
            }
        }

        pub fn write(self: *Self, side: Side, socket: anytype, writer: anytype, items: [][]const u8) !void {
            for (items) |message| {
                if (mem.indexOfScalar(u8, message, '\n') != null) {
                    return error.UnexpectedDelimiter;
                }

                const frame = try writer.peek(message.len + 1);
                mem.copy(u8, frame[0..message.len], message);
                frame[message.len..][0] = '\n';
            }

            try writer.flush();
        }
    };

    const opts: Options = .{ .protocol_type = *Protocol };

    const Test = struct {
        fn run(notifier: *const pike.Notifier, protocol: *Protocol, stopped: *bool) !void {
            defer stopped.* = true;

            var server = try Server(opts).init(
                protocol,
                testing.allocator,
                notifier,
                net.Address.initIp4(.{ 0, 0, 0, 0 }, 0),
            );
            defer server.deinit();

            try server.serve();

            var client = Client(opts).init(
                protocol,
                testing.allocator,
                notifier,
                try server.socket.getBindAddress(),
            );
            defer client.deinit();

            inline for (.{ "A", "B", "C", "D" }) |message| {
                try client.write(message);
                protocol.event.wait();
            }
        }
    };

    const notifier = try pike.Notifier.init();
    defer notifier.deinit();

    var protocol: Protocol = .{};
    defer protocol.deinit();

    var stopped = false;
    var frame = async Test.run(&notifier, &protocol, &stopped);

    while (!stopped) {
        try notifier.poll(10_000);
    }

    try nosuspend await frame;
}
