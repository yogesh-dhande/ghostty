//! Root of the test executable built with `Config.embedded_apprt_test`, where
//! `apprt.runtime` is `apprt/embedded.zig`. Only the embedded runtime's tests
//! belong here; everything else is covered by `main.zig`.
const std = @import("std");
const apprt = @import("apprt.zig");

test {
    std.testing.log_level = std.log.Level.err;
    _ = apprt.embedded;
}
