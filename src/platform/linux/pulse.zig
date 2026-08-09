const std = @import("std");

const sys = @import("sys.zig");
const tag = @import("tag.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const Error = error{
    Auth,
    Connect,
    Overflow,
    Protocol,
    Refused,
    Transport,
};

pub const Command = enum(u32) {
    err = 0,
    reply = 2,
    auth = 8,
    set_client_name = 9,
    get_server_info = 20,
    get_sink_info_list = 22,
    get_source_info_list = 24,
    subscribe = 35,
    set_sink_volume = 36,
    set_source_volume = 38,
    set_sink_mute = 39,
    set_source_mute = 40,
    set_default_sink = 44,
    set_default_source = 45,
    subscribe_event = 66,
};

pub const protocol_version: u32 = 32;
pub const cookie_bytes: u32 = 256;
pub const descriptor_bytes: u32 = 20;
pub const packet_bytes_max: u32 = 1024 * 64;
pub const payload_bytes_max: u32 = 4096;
pub const path_bytes_max: u32 = 108;
pub const channel_packet: u32 = 0xffffffff;
pub const index_invalid: u32 = 0xffffffff;
pub const volume_norm: u32 = 0x10000;
pub const packets_max: u32 = 64;
pub const version_mask: u32 = 0x0000ffff;
pub const prologue_bytes: u32 = 10;

pub const subscription_mask_sink: u32 = 0x0001;
pub const subscription_mask_source: u32 = 0x0002;
pub const subscription_mask_server: u32 = 0x0080;

pub const facility_mask: u32 = 0x000f;
pub const facility_sink: u32 = 0x0000;
pub const facility_source: u32 = 0x0001;
pub const facility_server: u32 = 0x0007;

pub const change_mask: u32 = 0x0030;
pub const change_new: u32 = 0x0000;
pub const change_changed: u32 = 0x0010;
pub const change_removed: u32 = 0x0020;

const socket_env = "PULSE_SERVER";
const runtime_env = "XDG_RUNTIME_DIR";
const home_env = "HOME";
const socket_suffix = "/pulse/native";
const cookie_suffix = "/.config/pulse/cookie";
const unix_prefix = "unix:";

comptime {
    assert(cookie_bytes == 256);
    assert(descriptor_bytes == 20);
    assert(packet_bytes_max > payload_bytes_max);
    assert(path_bytes_max > socket_suffix.len);
    assert(volume_norm > 0);
    assert(packets_max > 0);
    assert(prologue_bytes == 10);
}

pub const Device = struct {
    channels: u8 = 1,
    index: u32 = 0,
    muted: bool = false,
    name: [tag_name_bytes_max]u8 = [_]u8{0} ** tag_name_bytes_max,
    name_len: u16 = 0,
    description: [tag_name_bytes_max]u8 = [_]u8{0} ** tag_name_bytes_max,
    description_len: u16 = 0,
    volume: u32 = 0,

    pub fn get_name(device: *const Device) []const u8 {
        return device.name[0..device.name_len];
    }

    pub fn get_description(device: *const Device) []const u8 {
        return device.description[0..device.description_len];
    }
};

pub const tag_name_bytes_max: u32 = 256;
pub const devices_max: u32 = 32;

pub const DeviceList = struct {
    count: u32 = 0,
    items: [devices_max]Device = [_]Device{.{}} ** devices_max,

    pub fn slice(list: *const DeviceList) []const Device {
        return list.items[0..list.count];
    }
};

pub const ServerInfo = struct {
    default_sink: [tag_name_bytes_max]u8 = [_]u8{0} ** tag_name_bytes_max,
    default_sink_len: u16 = 0,
    default_source: [tag_name_bytes_max]u8 = [_]u8{0} ** tag_name_bytes_max,
    default_source_len: u16 = 0,

    pub fn get_default_sink(info: *const ServerInfo) []const u8 {
        return info.default_sink[0..info.default_sink_len];
    }

    pub fn get_default_source(info: *const ServerInfo) []const u8 {
        return info.default_source[0..info.default_source_len];
    }
};

pub const Event = struct {
    facility: u32,
    change: u32,
};

pub fn to_pulse_volume(level: f32) u32 {
    const clamped = std.math.clamp(level, 0.0, 1.0);
    const scaled = @round(clamped * @as(f32, @floatFromInt(volume_norm)));
    const result: u32 = @intFromFloat(scaled);

    assert(result <= volume_norm);

    return result;
}

pub fn from_pulse_volume(value: u32) f32 {
    const raw = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(volume_norm));
    const result = std.math.clamp(raw, 0.0, 1.0);

    assert(result >= 0.0);
    assert(result <= 1.0);

    return result;
}

pub const Connection = struct {
    packet: [packet_bytes_max]u8 = undefined,
    payload: [payload_bytes_max]u8 = undefined,
    sequence: u32 = 0,
    socket: ?sys.Fd = null,
    version: u32 = protocol_version,

    pub fn init() Connection {
        const result = Connection{};

        assert(result.socket == null);

        return result;
    }

    pub fn open(connection: *Connection, client: []const u8) Error!void {
        assert(connection.socket == null);
        assert(client.len > 0);

        var storage: [path_bytes_max]u8 = undefined;

        const path = resolve_socket(&storage) orelse {
            return Error.Connect;
        };

        try connection.connect(path);
        errdefer connection.close();

        try connection.authenticate();
        try connection.set_client_name(client);

        assert(connection.socket != null);
    }

    pub fn close(connection: *Connection) void {
        const handle = connection.socket orelse return;

        connection.socket = null;

        sys.close(handle);

        assert(connection.socket == null);
    }

    pub fn is_open(connection: *const Connection) bool {
        return connection.socket != null;
    }

    pub fn list(connection: *Connection, command: Command, out: *DeviceList) Error!void {
        assert(command == .get_sink_info_list or command == .get_source_info_list);

        var writer = tag.Writer.init(&connection.payload);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        const reply = try connection.request(command, body);

        const formats_from: u32 = if (command == .get_sink_info_list) 21 else 22;

        var reader = tag.Reader.init(reply);

        out.count = 0;

        while (!reader.is_empty()) {
            if (out.count >= devices_max) {
                return;
            }

            const device = read_device(&reader, connection.version, formats_from) catch {
                return Error.Protocol;
            };

            out.items[out.count] = device;
            out.count += 1;
        }
    }

    pub fn server_info(connection: *Connection, out: *ServerInfo) Error!void {
        var writer = tag.Writer.init(&connection.payload);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        const reply = try connection.request(.get_server_info, body);

        var reader = tag.Reader.init(reply);

        var index: u32 = 0;

        while (index < 4) : (index += 1) {
            _ = reader.read_string() catch {
                return Error.Protocol;
            };
        }

        reader.skip() catch {
            return Error.Protocol;
        };

        const sink = reader.read_string() catch {
            return Error.Protocol;
        };

        const source = reader.read_string() catch {
            return Error.Protocol;
        };

        out.default_sink_len = copy_into(&out.default_sink, sink);
        out.default_source_len = copy_into(&out.default_source, source);
    }

    pub fn set_mute(
        connection: *Connection,
        command: Command,
        name: []const u8,
        muted: bool,
    ) Error!void {
        assert(command == .set_sink_mute or command == .set_source_mute);
        assert(name.len > 0);

        var writer = tag.Writer.init(&connection.payload);

        writer.put_u32(index_invalid);
        writer.put_string(name);
        writer.put_boolean(muted);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        _ = try connection.request(command, body);
    }

    pub fn set_volume(
        connection: *Connection,
        command: Command,
        name: []const u8,
        channels: u8,
        level: u32,
    ) Error!void {
        assert(command == .set_sink_volume or command == .set_source_volume);
        assert(name.len > 0);
        assert(channels > 0);

        var writer = tag.Writer.init(&connection.payload);

        writer.put_u32(index_invalid);
        writer.put_string(name);
        writer.put_cvolume(channels, level);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        _ = try connection.request(command, body);
    }

    pub fn set_default(connection: *Connection, command: Command, name: []const u8) Error!void {
        assert(command == .set_default_sink or command == .set_default_source);
        assert(name.len > 0);

        var writer = tag.Writer.init(&connection.payload);

        writer.put_string(name);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        _ = try connection.request(command, body);
    }

    pub fn subscribe(connection: *Connection, mask: u32) Error!void {
        var writer = tag.Writer.init(&connection.payload);

        writer.put_u32(mask);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        _ = try connection.request(.subscribe, body);
    }

    pub fn read_event(connection: *Connection) Error!?Event {
        const packet = try connection.receive();

        var reader = tag.Reader.init(packet);

        const command = reader.read_u32() catch {
            return Error.Protocol;
        };

        _ = reader.read_u32() catch {
            return Error.Protocol;
        };

        if (command != @intFromEnum(Command.subscribe_event)) {
            return null;
        }

        const raw = reader.read_u32() catch {
            return Error.Protocol;
        };

        return Event{
            .facility = raw & facility_mask,
            .change = raw & change_mask,
        };
    }

    fn connect(connection: *Connection, path: []const u8) Error!void {
        assert(path.len > 0);
        assert(path.len < path_bytes_max);

        const handle = sys.unix_socket() catch {
            return Error.Connect;
        };

        errdefer sys.close(handle);

        var address = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };

        @memset(&address.path, 0);
        @memcpy(address.path[0..path.len], path);

        sys.connect(handle, &address, @sizeOf(linux.sockaddr.un)) catch {
            return Error.Connect;
        };

        connection.socket = handle;
    }

    fn authenticate(connection: *Connection) Error!void {
        var cookie: [cookie_bytes]u8 = [_]u8{0} ** cookie_bytes;

        load_cookie(&cookie);

        var writer = tag.Writer.init(&connection.payload);

        writer.put_u32(protocol_version);
        writer.put_arbitrary(&cookie);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        const reply = connection.request(.auth, body) catch {
            return Error.Auth;
        };

        var reader = tag.Reader.init(reply);

        const remote = reader.read_u32() catch {
            return Error.Auth;
        };

        connection.version = @min(protocol_version, remote & version_mask);

        assert(connection.version <= protocol_version);
    }

    fn set_client_name(connection: *Connection, client: []const u8) Error!void {
        assert(client.len > 0);

        const entries = [_]tag.Property{
            .{ .key = "application.name", .value = client },
        };

        var writer = tag.Writer.init(&connection.payload);

        writer.put_proplist(&entries);

        const body = writer.written() catch {
            return Error.Overflow;
        };

        _ = try connection.request(.set_client_name, body);
    }

    fn request(connection: *Connection, command: Command, body: []const u8) Error![]const u8 {
        const handle = connection.socket orelse {
            return Error.Transport;
        };

        connection.sequence +%= 1;

        const serial = connection.sequence;

        var header: [descriptor_bytes + prologue_bytes]u8 = undefined;

        const length: u32 = @intCast(body.len + prologue_bytes);

        std.mem.writeInt(u32, header[0..4], length, .big);
        std.mem.writeInt(u32, header[4..8], channel_packet, .big);
        std.mem.writeInt(u32, header[8..12], 0, .big);
        std.mem.writeInt(u32, header[12..16], 0, .big);
        std.mem.writeInt(u32, header[16..20], 0, .big);

        header[20] = @intFromEnum(tag.Tag.uint32);

        std.mem.writeInt(u32, header[21..25], @intFromEnum(command), .big);

        header[25] = @intFromEnum(tag.Tag.uint32);

        std.mem.writeInt(u32, header[26..30], serial, .big);

        sys.write_all(handle, &header) catch {
            return Error.Transport;
        };

        sys.write_all(handle, body) catch {
            return Error.Transport;
        };

        var attempts: u32 = 0;

        while (attempts < packets_max) : (attempts += 1) {
            const packet = try connection.receive();

            var reader = tag.Reader.init(packet);

            const reply_command = reader.read_u32() catch {
                return Error.Protocol;
            };

            const reply_serial = reader.read_u32() catch {
                return Error.Protocol;
            };

            if (reply_serial != serial) {
                continue;
            }

            if (reply_command == @intFromEnum(Command.err)) {
                return Error.Refused;
            }

            if (reply_command != @intFromEnum(Command.reply)) {
                return Error.Protocol;
            }

            return packet[reader.offset..];
        }

        return Error.Protocol;
    }

    fn receive(connection: *Connection) Error![]const u8 {
        const handle = connection.socket orelse {
            return Error.Transport;
        };

        var descriptor: [descriptor_bytes]u8 = undefined;

        sys.read_all(handle, &descriptor) catch {
            return Error.Transport;
        };

        const length = std.mem.readInt(u32, descriptor[0..4], .big);

        if (length > packet_bytes_max) {
            return Error.Protocol;
        }

        if (length == 0) {
            return connection.packet[0..0];
        }

        const body = connection.packet[0..length];

        sys.read_all(handle, body) catch {
            return Error.Transport;
        };

        return body;
    }
};

pub const ports_max: u32 = 64;
pub const formats_max: u32 = 32;

fn read_device(reader: *tag.Reader, version: u32, formats_from: u32) tag.Error!Device {
    var device = Device{};

    device.index = try reader.read_u32();

    const name = try reader.read_string();
    const description = try reader.read_string();

    device.name_len = copy_into(&device.name, name);
    device.description_len = copy_into(&device.description, description);

    try reader.skip();
    try reader.skip();

    _ = try reader.read_u32();

    const volume = try reader.read_cvolume();

    device.channels = volume.channels;
    device.volume = volume.level;
    device.muted = try reader.read_boolean();

    _ = try reader.read_u32();
    _ = try reader.read_string();

    try reader.skip();

    _ = try reader.read_string();
    _ = try reader.read_u32();

    if (version >= 13) {
        try reader.skip();
        try reader.skip();
    }

    if (version >= 15) {
        try reader.skip();
        try reader.skip();
        try reader.skip();
        try reader.skip();
    }

    if (version >= 16) {
        try read_ports(reader, version);
    }

    if (version >= formats_from) {
        try read_formats(reader);
    }

    return device;
}

fn read_ports(reader: *tag.Reader, version: u32) tag.Error!void {
    const count = try reader.read_u32();

    if (count > ports_max) {
        return tag.Error.Unexpected;
    }

    var index: u32 = 0;

    while (index < count) : (index += 1) {
        _ = try reader.read_string();
        _ = try reader.read_string();
        _ = try reader.read_u32();

        if (version >= 24) {
            _ = try reader.read_u32();
        }

        if (version >= 34) {
            _ = try reader.read_string();
            _ = try reader.read_u32();
        }
    }

    _ = try reader.read_string();
}

fn read_formats(reader: *tag.Reader) tag.Error!void {
    const count = try reader.read_u8();

    if (count > formats_max) {
        return tag.Error.Unexpected;
    }

    var index: u8 = 0;

    while (index < count) : (index += 1) {
        try reader.skip();
    }
}

fn copy_into(buffer: []u8, text: ?[]const u8) u16 {
    const source = text orelse return 0;
    const length: u16 = @intCast(@min(source.len, buffer.len));

    @memcpy(buffer[0..length], source[0..length]);

    return length;
}

fn load_cookie(buffer: *[cookie_bytes]u8) void {
    var storage: [path_bytes_max * 2]u8 = undefined;

    const home = sys.getenv(home_env) orelse return;

    const path = std.fmt.bufPrintZ(
        &storage,
        "{s}{s}",
        .{ home, cookie_suffix },
    ) catch {
        return;
    };

    const handle = sys.open_read(path.ptr) catch {
        return;
    };

    defer sys.close(handle);

    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < cookie_bytes and attempts < cookie_bytes) : (attempts += 1) {
        const count = sys.read(handle, buffer[filled..]) catch {
            return;
        };

        if (count == 0) {
            return;
        }

        filled += count;
    }
}

fn resolve_socket(buffer: *[path_bytes_max]u8) ?[]const u8 {
    if (sys.getenv(socket_env)) |value| {
        if (value.len > 0) {
            const trimmed = if (std.mem.startsWith(u8, value, unix_prefix))
                value[unix_prefix.len..]
            else
                value;

            if (trimmed.len > 0 and trimmed.len < path_bytes_max and trimmed[0] == '/') {
                @memcpy(buffer[0..trimmed.len], trimmed);

                return buffer[0..trimmed.len];
            }
        }
    }

    const runtime = sys.getenv(runtime_env) orelse return null;

    const path = std.fmt.bufPrint(
        buffer,
        "{s}{s}",
        .{ runtime, socket_suffix },
    ) catch {
        return null;
    };

    return path;
}

const testing = std.testing;

test "the volume mapping is the percentage every PulseAudio front end shows" {
    try testing.expectEqual(@as(u32, 0), to_pulse_volume(0.0));
    try testing.expectEqual(volume_norm, to_pulse_volume(1.0));
    try testing.expectEqual(volume_norm / 2, to_pulse_volume(0.5));

    try testing.expectEqual(@as(f32, 0.0), from_pulse_volume(0));
    try testing.expectEqual(@as(f32, 1.0), from_pulse_volume(volume_norm));
    try testing.expectEqual(@as(f32, 0.5), from_pulse_volume(volume_norm / 2));
}

test "the volume mapping clamps both directions at the seam" {
    try testing.expectEqual(volume_norm, to_pulse_volume(4.0));
    try testing.expectEqual(@as(u32, 0), to_pulse_volume(-1.0));
    try testing.expectEqual(@as(f32, 1.0), from_pulse_volume(volume_norm * 3));
}

test "the volume mapping round trips within one step" {
    var index: u32 = 0;

    while (index <= 100) : (index += 1) {
        const level = @as(f32, @floatFromInt(index)) / 100.0;
        const back = from_pulse_volume(to_pulse_volume(level));

        try testing.expect(@abs(back - level) < 0.001);
    }
}

test "a fresh connection owns no socket" {
    var connection = Connection.init();

    try testing.expect(!connection.is_open());

    connection.close();

    try testing.expect(!connection.is_open());
}

test "the command numbers match the native protocol" {
    try testing.expectEqual(@as(u32, 8), @intFromEnum(Command.auth));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(Command.set_client_name));
    try testing.expectEqual(@as(u32, 20), @intFromEnum(Command.get_server_info));
    try testing.expectEqual(@as(u32, 22), @intFromEnum(Command.get_sink_info_list));
    try testing.expectEqual(@as(u32, 24), @intFromEnum(Command.get_source_info_list));
    try testing.expectEqual(@as(u32, 35), @intFromEnum(Command.subscribe));
    try testing.expectEqual(@as(u32, 39), @intFromEnum(Command.set_sink_mute));
    try testing.expectEqual(@as(u32, 40), @intFromEnum(Command.set_source_mute));
    try testing.expectEqual(@as(u32, 44), @intFromEnum(Command.set_default_sink));
    try testing.expectEqual(@as(u32, 45), @intFromEnum(Command.set_default_source));
    try testing.expectEqual(@as(u32, 66), @intFromEnum(Command.subscribe_event));
}
