const std = @import("std");

const mem = std.mem;

pub fn Reader(comptime Socket: type, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();

        socket: *Socket,

        buf: [buffer_size]u8 = undefined,
        pos: usize = 0,

        pub inline fn init(socket: *Socket) Self {
            return Self{ .socket = socket };
        }

        pub inline fn reset(self: *Self) void {
            self.pos = 0;
        }

        pub inline fn readUntil(self: *Self, delimiter: []const u8) ![]const u8 {
            while (true) {
                if (self.pos >= buffer_size) return error.BufferOverflow;

                const num_bytes = try self.socket.read(self.buf[self.pos..]);
                if (num_bytes == 0) return error.EndOfStream;
                self.pos += num_bytes;

                if (mem.indexOf(u8, self.buf[0..self.pos], delimiter)) |i| {
                    return self.buf[0 .. i + 1];
                }
            }
        }

        pub inline fn readLine(self: *Self) ![]const u8 {
            return self.readUntil("\n");
        }

        pub inline fn peek(self: *Self, amount: usize) !void {
            if (self.pos >= amount) return;

            while (self.pos < amount) {
                const num_bytes = try self.socket.read(self.buf[self.pos..]);
                if (num_bytes == 0) return error.EndOfStream;
                self.pos += num_bytes;
            }
        }

        pub inline fn shift(self: *Self, amount: usize) void {
            mem.copy(u8, self.buf[0 .. self.pos - amount], self.buf[amount..self.pos]);
            self.pos -= amount;
        }
    };
}

pub fn Writer(comptime Socket: type, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();

        socket: *Socket,

        buf: [buffer_size]u8 = undefined,
        pos: usize = 0,

        pub inline fn init(socket: *Socket) Self {
            return Self{ .socket = socket };
        }

        pub inline fn write(self: *Self, buf: []const u8) !void {
            mem.copy(u8, try self.peek(buf.len), buf);
        }

        pub inline fn peek(self: *Self, size: usize) ![]u8 {
            if (size > buffer_size) return error.RequestedSizeToolarge;
            if (self.pos + size > buffer_size) try self.shift(buffer_size - size);

            defer self.pos += size;
            return self.buf[self.pos..][0..size];
        }

        pub inline fn flush(self: *Self) !void {
            return self.shift(null);
        }

        pub inline fn shift(self: *Self, amount: ?usize) !void {
            const required_leftover_space = amount orelse 0;

            while (self.pos > required_leftover_space) {
                const num_bytes = try self.socket.write(self.buf[0..self.pos]);
                if (num_bytes == 0) return error.EndOfStream;
                self.pos -= num_bytes;
            }
        }
    };
}
