const std = @import("std");

const mantra = @import("mantra");

const Device = mantra.Device;
const Direction = mantra.Direction;

const Watcher = struct {
    changes: std.atomic.Value(u32) = .init(0),

    fn on_change(watcher: *Watcher, _: Device.Event, _: ?Direction) void {
        _ = watcher.changes.fetchAdd(1, .seq_cst);
    }
};

pub fn main() !void {
    var mixer: mantra.Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var watcher = Watcher{};

    try mixer.subscribe(Watcher, &watcher, Watcher.on_change);
    defer mixer.unsubscribe();

    var list = Device.List.init();

    try mixer.enumerate(&list, .capture);

    for (list.slice()) |*device| {
        const muted = try mixer.is_muted(&device.id);
        const volume = try mixer.get_volume(&device.id);

        std.debug.print("{s} muted={} volume={d:.2}\n", .{ device.get_name(), muted, volume });
    }

    const id = try mixer.default(.capture);
    const muted = try mixer.is_muted(&id);

    try mixer.mute(&id);

    if (!muted) try mixer.unmute(&id);

    try mixer.set_default(&id);
    try mixer.set_volume(&id, try mixer.get_volume(&id));

    std.debug.print("{d} change notifications\n", .{watcher.changes.load(.seq_cst)});
}
