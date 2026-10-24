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
    try mantra.runtime.open();
    defer mantra.runtime.close();

    var watcher = Watcher{};

    try mantra.events.subscribe(Watcher, &watcher, Watcher.on_change);
    defer mantra.events.unsubscribe();

    var list = Device.List.init();

    try mantra.devices.enumerate(&list, .capture);

    for (list.slice()) |*device| {
        const muted = try mantra.control.is_muted(&device.id);
        const volume = try mantra.control.get_volume(&device.id);

        std.debug.print("{s} muted={} volume={d:.2}\n", .{ device.get_name(), muted, volume });
    }

    const id = try mantra.devices.default(.capture);
    const muted = try mantra.control.is_muted(&id);

    try mantra.control.mute(&id);

    if (!muted) try mantra.control.unmute(&id);

    try mantra.devices.set_default(&id);
    try mantra.control.set_volume(&id, try mantra.control.get_volume(&id));

    std.debug.print("{d} change notifications\n", .{watcher.changes.load(.seq_cst)});
}
