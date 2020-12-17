const std = @import("std");
const pike = @import("pike");

const mem = std.mem;

pub const Counter = struct {
    const Self = @This();

    state: isize = 0,
    event: Event = .{},

    pub fn add(self: *Self, delta: isize) void {
        var state = @atomicLoad(isize, &self.state, .Monotonic);
        var new_state: isize = undefined;

        while (true) {
            new_state = state + delta;

            state = @cmpxchgWeak(
                isize,
                &self.state,
                state,
                new_state,
                .Monotonic,
                .Monotonic,
            ) orelse break;
        }

        if (new_state == 0) {
            self.event.notify();
        }
    }

    pub fn wait(self: *Self) void {
        if (@atomicLoad(isize, &self.state, .Monotonic) > 0) {
            self.event.wait();
        }
    }
};

pub fn Queue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        items: [capacity]T = undefined,
        reader: Event = .{},
        writer: Event = .{},
        dead: bool = false,
        head: usize = 0,
        tail: usize = 0,

        const Self = @This();

        pub fn pending(self: *const Self) usize {
            const head = @atomicLoad(usize, &self.head, .Acquire);
            return self.tail -% head;
        }

        pub fn push(self: *Self, item: T) !void {
            while (true) {
                if (@atomicLoad(bool, &self.dead, .Monotonic)) {
                    return error.OperationCancelled;
                }

                const head = @atomicLoad(usize, &self.head, .Acquire);
                if (self.tail -% head < capacity) {
                    self.items[self.tail % capacity] = item;
                    @atomicStore(usize, &self.tail, self.tail +% 1, .Release);
                    self.reader.notify();
                    return;
                }

                self.writer.wait();
            }
        }

        pub fn pop(self: *Self, dst: []T) !usize {
            while (true) {
                const tail = @atomicLoad(usize, &self.tail, .Acquire);
                const popped = tail -% self.head;

                if (popped != 0) {
                    var i: usize = 0;
                    while (i < popped) : (i += 1) {
                        dst[i] = self.items[(self.head + i) % capacity];
                    }

                    @atomicStore(usize, &self.head, tail, .Release);
                    self.writer.notify();

                    return popped;
                }

                if (@atomicLoad(bool, &self.dead, .Monotonic)) {
                    return error.OperationCancelled;
                }

                self.reader.wait();
            }
        }

        pub fn close(self: *Self) void {
            if (@atomicRmw(bool, &self.dead, .Xchg, true, .Monotonic)) {
                return;
            }

            self.reader.notify();
            self.writer.notify();
        }
    };
}

pub const Event = struct {
    state: ?*pike.Task = null,

    var notified: pike.Task = undefined;

    pub fn wait(self: *Event) void {
        var task = pike.Task.init(@frame());
        suspend {
            var state = @atomicLoad(?*pike.Task, &self.state, .Monotonic);
            while (true) {
                const new_state = if (state == &notified) null else if (state == null) &task else unreachable;

                state = @cmpxchgWeak(
                    ?*pike.Task,
                    &self.state,
                    state,
                    new_state,
                    .Release,
                    .Monotonic,
                ) orelse {
                    if (new_state == null) pike.dispatch(&task, .{});
                    break;
                };
            }
        }
    }

    pub fn notify(self: *Event) void {
        var state = @atomicLoad(?*pike.Task, &self.state, .Monotonic);
        while (true) {
            if (state == &notified)
                return;

            const new_state = if (state == null) &notified else null;
            state = @cmpxchgWeak(
                ?*pike.Task,
                &self.state,
                state,
                new_state,
                .Acquire,
                .Monotonic,
            ) orelse {
                if (state) |task| pike.dispatch(task, .{});
                break;
            };
        }
    }
};

/// Async-friendly Mutex ported from Zig's standard library to be compatible
/// with scheduling methods exposed by pike.
pub const Mutex = struct {
    mutex: std.Mutex = .{},
    head: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;

    const Waiter = struct {
        // forced Waiter alignment to ensure it doesn't clash with LOCKED
        next: ?*Waiter align(2),
        tail: *Waiter,
        task: pike.Task,
    };

    pub fn initLocked() Mutex {
        return Mutex{ .head = LOCKED };
    }

    pub fn acquire(self: *Mutex) Held {
        const held = self.mutex.acquire();

        // self.head transitions from multiple stages depending on the value:
        // UNLOCKED -> LOCKED:
        //   acquire Mutex ownership when theres no waiters
        // LOCKED -> <Waiter head ptr>:
        //   Mutex is already owned, enqueue first Waiter
        // <head ptr> -> <head ptr>:
        //   Mutex is owned with pending waiters. Push our waiter to the queue.

        if (self.head == UNLOCKED) {
            self.head = LOCKED;
            held.release();
            return Held{ .lock = self };
        }

        var waiter: Waiter = undefined;
        waiter.next = null;
        waiter.tail = &waiter;

        const head = switch (self.head) {
            UNLOCKED => unreachable,
            LOCKED => null,
            else => @intToPtr(*Waiter, self.head),
        };

        if (head) |h| {
            h.tail.next = &waiter;
            h.tail = &waiter;
        } else {
            self.head = @ptrToInt(&waiter);
        }

        suspend {
            waiter.task = pike.Task.init(@frame());
            held.release();
        }

        return Held{ .lock = self };
    }

    pub const Held = struct {
        lock: *Mutex,

        pub fn release(self: Held) void {
            const waiter = blk: {
                const held = self.lock.mutex.acquire();
                defer held.release();

                // self.head goes through the reverse transition from acquire():
                // <head ptr> -> <new head ptr>:
                //   pop a waiter from the queue to give Mutex ownership when theres still others pending
                // <head ptr> -> LOCKED:
                //   pop the laster waiter from the queue, while also giving it lock ownership when awaken
                // LOCKED -> UNLOCKED:
                //   last lock owner releases lock while no one else is waiting for it

                switch (self.lock.head) {
                    UNLOCKED => unreachable, // Mutex unlocked while unlocking
                    LOCKED => {
                        self.lock.head = UNLOCKED;
                        break :blk null;
                    },
                    else => {
                        const waiter = @intToPtr(*Waiter, self.lock.head);
                        self.lock.head = if (waiter.next == null) LOCKED else @ptrToInt(waiter.next);
                        if (waiter.next) |next|
                            next.tail = waiter.tail;
                        break :blk waiter;
                    },
                }
            };

            if (waiter) |w| {
                pike.dispatch(&w.task, .{});
            }
        }
    };
};
