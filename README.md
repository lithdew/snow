# snow

A small, fast, cross-platform Zig async networking framework built on top of [lithdew/pike](https://github.com/lithdew/pike).

## Protocol

Applications written with _snow_ provide a `Protocol` implementation which specifies how message are encoded / decoded into frames.

Helpers (`io.Reader` / `io.Writer`) are provided to assist developers in specifying how frame encoding / decoding is to be performed.

Given a `Protocol` implementation, a `Client` / `Server` may be instantiated.

Here is an example of a `Protocol` that frames messages based on an End-of-Line character ('\n') suffixed at the end of each message:

```rs
const std = @import("std");
const snow = @import("snow");

const mem = std.mem;

const Protocol = struct {
    pub fn read(self: *Protocol, side: snow.Side, socket: anytype, reader: anytype) !void {
        while (true) {
            const line = try reader.readLine();
            defer reader.shift(line.len);
        }
    }

    pub fn write(self: *Protocol, side: snow.Side, socket: anytype, writer: anytype, items: [][]const u8) !void {
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
```

A `handshake(self: *Protocol, side: Side, socket: anytype)` may additionally be specified in a `Protocol` which gets invoked upon the successful establishment of an incoming / outgoing connection.


## Client

A `Client` comprises of a bounded adaptive pool of outgoing connections that are to be connected to a single IPv4/IPv6 endpoint.

When writing a message to an endpoint with a `Client`, a connection is initially grabbed from the pool. The message is then queued to be written to the connection's underlying socket.

A policy is specified for selecting which connection to grab from a `Client`'s pool. The policy goes as follows:

There exists a configurable maximum number of connections that may belong to a `Client`'s pool (defaulting to 16). If all existing connections in a `Client`'s pool contain queued messages that have yet to be flushed and written, a new connection is created and registered to the pool up to a maximum number of connections.

If the pool's maximum number of connections limit is reached, the connection in the pool with the smallest number of queued messages is returned. Otherwise, a new connection is created and registered to the pool and returned.

## Server

A `Server` comprises of a bounded adaptive pool of incoming connections accepted from a single bounded IPv4/IPv6 endpoint. There exists a configurable maximum number of connections that may belong to a `Server`'s pool (defaulting to 128).

Should an incoming connection be established and the pool underlying a `Server` appears to be full, the connection will be declined and de-initialized.

## Socket

All sockets comprise of two coroutines: a reader coroutine, and a writer coroutine. The reader and writer coroutine are responsible for framing and buffering messages received from / written to a single socket instance, and for executing logic specified under a `Protocol` implementation.

An interesting detail to note is that the writer coroutine is entirely lock-free.

## Performance

_snow_ was written with performance in mind: zero heap allocations occur in all hot paths.

Heap allocations only ever occur when establishing a new incoming / outgoing connection.

All other underlying components are stack-allocated and recycled as much as possible.