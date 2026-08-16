<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="assets/mantra-lockup-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="assets/mantra-lockup-on-light.svg">
        <img alt="mantra" src="assets/mantra-lockup-on-light.svg" width="500">
    </picture>
</p>

&nbsp;

<p align="center">
    A library for audio endpoint control on Windows and Linux, covering enumeration, mute, volume, the default device, and device change events.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/mantra/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/mantra/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://ziglang.org"><img alt="zig" src="https://img.shields.io/badge/zig-0.16.0-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

mantra lists the audio devices on a machine, mutes them, sets their volume, and reports
changes. A device is addressed by an opaque id the backend hands out, so the same four
namespaces cover both platforms: `runtime`, `devices`, `control`, and `events`.

## Features

- **Three backends**: The Linux path speaks the PulseAudio protocol over its unix socket,
  the Windows path drives MMDevice through COM, and a mock backend stands in for tests.
- **No client libraries**: The Linux side links nothing, and the Windows side links only
  `kernel32` and `ole32`.
- **Fixed bounds**: A device list holds 32 entries, an id is at most 512 bytes, and a name
  is at most 256, so nothing allocates.
- **Both directions**: The capture and render sides share one API, separated by a
  `Direction` rather than by a second set of calls.
- **Change events**: A callback reports a device added, removed, changed in state, or made
  default.

## Install

The library ships as a Zig package holding one module, also named `mantra`. Fetch it into
your own project and import the module in your `build.zig`.

```
zig fetch --save git+https://github.com/braycarlson/mantra
```

```zig
const mantra = b.dependency("mantra", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("mantra", mantra.module("mantra"));
```

mantra requires Zig 0.16.0.

## Usage

The runtime opens once, and every call after that takes an id from an enumeration or from
`devices.default`. A volume is a float from 0.0 to 1.0.

```zig
const std = @import("std");

const mantra = @import("mantra");

pub fn main() !void {
    try mantra.runtime.open();
    defer mantra.runtime.close();

    var list = mantra.DeviceList.init();

    try mantra.devices.enumerate(.capture, &list);

    for (list.items[0..list.count]) |device| {
        const muted = try mantra.control.is_muted(&device.id);
        const volume = try mantra.control.get_volume(&device.id);

        std.debug.print("{s} muted={} volume={d:.2}\n", .{
            device.name[0..device.name_len],
            muted,
            volume,
        });
    }

    const id = try mantra.devices.default(.capture);

    try mantra.control.set_mute(&id, true);
}
```

The `capabilities` declaration states what the running backend supports, so a caller can
check for default selection and events rather than discovering the gap through an error.

## Development

The recipes below wrap `zig build`, and a bare `just` lists them all. The tidy law is a
test rather than a separate linter, so the mechanical rules run with everything else.

| Command | What it runs |
|---|---|
| `just ci` | The formatting check, compilation, and each available suite. |
| `just test` | Each available suite and the formatting check. |
| `just mock` | The full pipeline against the mock backend. |
| `just linux` | The endpoint tests, on a Linux host with a sound server. |
| `just tidy` | The tidy law on its own. |
| `just check-windows` | The compile of every artifact for Windows from any host. |

## Licence

MIT. See [LICENSE](LICENSE).
