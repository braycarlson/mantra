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

[doc('Format build.zig, the examples, and every source file')]
fmt:
    zig fmt build.zig examples src

[doc('Run a fuzzer with a random or a given seed: just fuzz [name] [seed] [events]')]
fuzz name="tag" seed="" events="":
    zig build fuzz -- {{ name }} {{ seed }} {{ events }}

[doc('Lint build.zig, the examples, and every source file with tigerstyle-lsp')]
lint:
    tigerstyle-lsp check build.zig examples src --format concise

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the end to end tests against the fake backend: just test-fake [filter]')]
test-fake filter="":
    zig build test:fake {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[doc('Run the Linux backend tests on a Linux host: just test-linux [filter]')]
test-linux filter="":
    zig build test:linux {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[doc('Run the unit tests and the tidy check: just test-unit [filter]')]
test-unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}

[doc('Run the Windows backend tests on a Windows host: just test-windows [filter]')]
test-windows filter="":
    zig build test:windows {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
