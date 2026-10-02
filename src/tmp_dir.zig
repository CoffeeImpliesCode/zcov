//! Per-run coverage output and cold build caches live under an existing
//! absolute `$TMPDIR`. Unset or empty values use the POSIX `/tmp` default;
//! an invalid explicit value fails instead of silently using system temp.

const std = @import("std");

pub const Error = error{
    /// `$TMPDIR` is not absolute, or its run directory could not be created.
    TmpDirUnavailable,
};

const default_root = "/tmp";

fn root(parent_environ: *const std.process.Environ.Map) Error![]const u8 {
    const value = parent_environ.get("TMPDIR") orelse return default_root;
    if (value.len == 0) return default_root;
    if (!std.fs.path.isAbsolute(value)) {
        std.debug.print("zig-cov: TMPDIR must be an absolute directory: {s}\n", .{value});
        return error.TmpDirUnavailable;
    }
    return value;
}

/// Create `<root>/<prefix>-<pid>` and return it as a slice of `buf`.
///
/// An existing directory of that name is reused, matching the previous
/// pid-suffixed behaviour: a recycled pid picks up the same path rather than
/// failing.
pub fn createRunDir(
    io: std.Io,
    parent_environ: *const std.process.Environ.Map,
    prefix: []const u8,
    buf: []u8,
) Error![]const u8 {
    const base = try root(parent_environ);

    const path = std.fmt.bufPrint(buf, "{s}/{s}-{d}", .{
        base,
        prefix,
        std.c.getpid(),
    }) catch {
        std.debug.print(
            "zig-cov: scratch path under {s} does not fit in {d} bytes\n",
            .{ base, buf.len },
        );
        return error.TmpDirUnavailable;
    };

    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print(
                "zig-cov: cannot create scratch directory {s} ({s})\n" ++
                    "         Create $TMPDIR, or unset it to use {s}.\n",
                .{ path, @errorName(e), default_root },
            );
            return error.TmpDirUnavailable;
        },
    };
    return path;
}
