set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact without running it')]
check:
    zig build check

[doc('Compile every artifact for Linux from any host')]
check-linux:
    zig build check -Dtarget=x86_64-linux-gnu

[doc('Compile every artifact for Windows from any host')]
check-windows:
    zig build check -Dtarget=x86_64-windows-gnu

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Build and run an example: just example [name]')]
example name="devices":
    zig build run-{{ name }}

[doc('Format build.zig and every source file')]
fmt:
    zig fmt build.zig examples src

[doc('Run the Linux backend tests on a Linux host: just linux [filter]')]
linux filter="":
    zig build test:linux {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run the end to end tests against the mock backend: just mock [filter]')]
mock filter="":
    zig build test:mock {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just unit [filter]')]
unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[doc('Run the Windows backend tests on a Windows host: just windows [filter]')]
windows filter="":
    zig build test:windows {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
