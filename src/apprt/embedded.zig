//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const global = @import("../global.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const String = @import("../main_c.zig").String;

const log = std.log.scoped(.embedded_window);

fn sanitizeProcessExitCode(exit_code: i32) u32 {
    return if (exit_code < 0) 1 else @intCast(exit_code);
}

fn sanitizeFontSize(points: f32) ?f32 {
    if (!std.math.isFinite(points)) return null;
    return std.math.clamp(points, 1.0, 255.0);
}

pub const SurfaceDataCallback = termio.Termio.DataCallback;
pub const SurfaceReceiveBufferCallback = termio.HostManaged.ReceiveBufferCallback;
pub const SurfaceReceiveResizeCallback = termio.HostManaged.ReceiveResizeCallback;
pub const SessionStateCallback = *const fn (?*anyopaque, u32) callconv(.c) void;

pub const SessionStateFlags = packed struct(u32) {
    screen: bool = false,
    title: bool = false,
    working_directory: bool = false,
    foreground_process: bool = false,
    size: bool = false,
    _padding: u27 = 0,

    fn bits(self: @This()) u32 {
        return @bitCast(self);
    }

    fn unionWith(self: @This(), other: @This()) @This() {
        return @bitCast(self.bits() | other.bits());
    }
};

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,

        /// Read the clipboard value. Returns true if the clipboard request
        /// was started and complete_clipboard_request may be called with the
        /// given state pointer. Returns false if the clipboard request couldn't
        /// be started (such as when no text is available for a paste request).
        read_clipboard: *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            [*:0]const u8,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.c) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (
            SurfaceUD,
            c_int,
            [*]const CAPI.ClipboardContent,
            usize,
            bool,
        ) callconv(.c) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: Options,

    /// The keyboard layout keymap. This is lazily initialized on first
    /// use because creating it requires talking to the text input
    /// system (TIS on macOS), and the first such call in a process is
    /// slow (multiple milliseconds). It is only needed once keyboard
    /// events start flowing, at which point the system is warm.
    keymap: ?input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = null,
        };
    }

    pub fn terminate(self: *App) void {
        if (self.keymap) |*v| v.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap. If it was never initialized we don't need
        // to do anything since lazy initialization will pick up the
        // current layout.
        if (self.keymap) |*v| try v.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Lazily initialize the keymap.
        const keymap: *input.Keymap = keymap: {
            if (self.keymap == null) {
                self.keymap = input.Keymap.init() catch |err| {
                    log.warn("error initializing keymap err={}", .{err});
                    return .unknown;
                };
            }

            break :keymap &self.keymap.?;
        };

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app. A headless surface has no windowing
    /// system view and no renderer; see `Surface.headless`.
    fn newSurface(self: *App, opts: Surface.Options, headless: bool) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts, headless);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                    surface.rt_surface.notifyOwnerSessionStateChange(.{ .title = true });
                },
            },

            .pwd => switch (target) {
                .app => {},
                .surface => |surface| {
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.working_directory) |v| alloc.free(v);
                    surface.rt_surface.working_directory = alloc.dupeZ(u8, value.pwd) catch null;
                    surface.rt_surface.notifyOwnerSessionStateChange(.{ .working_directory = true });
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || apprt.ipc.Errors)!bool {
        switch (action) {
            .new_window => return false,
            .new_tab => return false,
            .toggle_quick_terminal => return false,
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = std.enums.fromInt(PlatformTag, tag_int) orelse return error.InvalidEnumTag;
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

pub const SurfaceHost = extern struct {
    platform_tag: c_int = 0,
    platform: Platform.C = undefined,
    scale_factor: f64 = 1,

    pub fn isValid(self: SurfaceHost) bool {
        _ = std.enums.fromInt(PlatformTag, self.platform_tag) orelse return false;
        return true;
    }

    pub fn eql(self: SurfaceHost, other: SurfaceHost) bool {
        if (self.platform_tag != other.platform_tag) return false;
        if (self.scale_factor != other.scale_factor) return false;
        const tag = std.enums.fromInt(PlatformTag, self.platform_tag) orelse return false;
        return switch (tag) {
            .macos => self.platform.macos.nsview == other.platform.macos.nsview,
            .ios => self.platform.ios.uiview == other.platform.ios.uiview,
        };
    }
};

pub const SurfaceIOBackend = enum(c_int) {
    exec = 0,
    host_managed = 1,
};

pub const Surface = struct {
    app: *App,

    /// The windowing system view this surface renders into. Null for a
    /// headless surface, which has no view and no renderer to use one.
    platform: ?Platform,

    /// True when this surface hosts terminal state with no renderer at all.
    /// See `Surface.headless` in the core surface.
    headless: bool,

    userdata: ?*anyopaque = null,
    io_backend: SurfaceIOBackend = .exec,
    receive_userdata: ?*anyopaque = null,
    receive_buffer: ?SurfaceReceiveBufferCallback = null,
    receive_resize: ?SurfaceReceiveResizeCallback = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,
    working_directory: ?[:0]const u8 = null,
    data_callback: ?SurfaceDataCallback = null,
    data_callback_userdata: ?*anyopaque = null,
    session_state_callback: ?SessionStateCallback = null,
    session_state_userdata: ?*anyopaque = null,

    /// The virtual anchor of an in-progress local drag on a mirror surface, carried across frame
    /// applies. Null when no drag is in progress or the carry was discarded (a new press, or an
    /// apply with no drag in progress). See `CAPI.MirrorDragCarry` and
    /// `CAPI.applySnapshotToSurface`.
    mirror_drag_carry: ?CAPI.MirrorDragCarry = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The IO backend for this embedded surface.
        backend: SurfaceIOBackend = .exec,

        /// Userdata passed to host-managed IO callbacks.
        receive_userdata: ?*anyopaque = null,

        /// Called when Ghostty wants to send input bytes to the host-owned PTY.
        receive_buffer: ?SurfaceReceiveBufferCallback = null,

        /// Called when Ghostty's terminal grid size changes.
        receive_resize: ?SurfaceReceiveResizeCallback = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Whether command execution should use the macOS login shell wrapper.
        use_login_shell: bool = false,

        /// True when use_login_shell should override the app configuration.
        use_login_shell_set: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,
    };

    pub fn init(self: *Surface, app: *App, opts: Options, headless: bool) !void {
        self.* = .{
            .app = app,
            .platform = if (headless) null else try Platform.init(
                opts.platform_tag,
                opts.platform,
            ),
            .headless = headless,
            .userdata = opts.userdata,
            .io_backend = opts.backend,
            .receive_userdata = opts.receive_userdata,
            .receive_buffer = opts.receive_buffer,
            .receive_resize = opts.receive_resize,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                var dir = std.Io.Dir.openDirAbsolute(global.io(), wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close(global.io());

                const stat = dir.stat(global.io()) catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                var wd_val: configpkg.WorkingDirectory = .{ .path = wd };
                if (wd_val.finalize(config.arenaAlloc())) |_| {
                    config.@"working-directory" = wd_val;
                    if (wd_val.value()) |path| {
                        self.working_directory = app.core_app.alloc.dupeZ(u8, path) catch null;
                    }
                } else |err| {
                    log.warn(
                        "error finalizing working directory config dir={s} err={}",
                        .{ wd_val.path, err },
                    );
                }
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                var command: configpkg.Command = undefined;
                try command.parseCLI(config.arenaAlloc(), cmd);
                config.command = command;
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }
        if (opts.use_login_shell_set) {
            config.@"macos-use-login-shell" = opts.use_login_shell;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            if (sanitizeFontSize(opts.font_size)) |points| {
                var font_size = self.core_surface.font_size;
                font_size.points = points;
                try self.core_surface.setFontSize(font_size);
            }
        }
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);
        if (self.working_directory) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    /// Read by the core surface to decide whether to build a renderer.
    pub fn isHeadless(self: *const Surface) bool {
        return self.headless;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn getWorkingDirectory(self: *Surface) ?[:0]const u8 {
        return self.working_directory;
    }

    fn notifyOwnerSessionStateChange(self: *Surface, flags: SessionStateFlags) void {
        const callback = self.session_state_callback orelse return;
        callback(self.session_state_userdata, flags.bits());
    }

    fn setSessionStateCallback(
        self: *Surface,
        callback: ?SessionStateCallback,
        userdata: ?*anyopaque,
    ) void {
        self.session_state_callback = callback;
        self.session_state_userdata = userdata;
        self.core_surface.setScreenChangeNotificationsEnabled(callback != null);
    }

    pub fn notifyOwnerSessionScreenChange(self: *Surface) void {
        self.notifyOwnerSessionStateChange(.{ .screen = true });
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        const started = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );
        if (!started) {
            alloc.destroy(state_ptr);
            return false;
        }

        return true;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn setHost(self: *Surface, host: SurfaceHost) !void {
        // A headless surface has no renderer to rebind onto a host view.
        if (self.headless) return error.SurfaceIsHeadless;

        const scale_factor = @max(1, if (std.math.isNan(host.scale_factor)) 1 else host.scale_factor);
        const platform = try Platform.init(host.platform_tag, host.platform);
        const old_platform = self.platform;
        const old_content_scale = self.content_scale;

        self.platform = platform;
        self.content_scale = .{
            .x = @floatCast(scale_factor),
            .y = @floatCast(scale_factor),
        };
        errdefer {
            self.platform = old_platform;
            self.content_scale = old_content_scale;
        }

        try self.core_surface.rebindRendererHost(self);
        self.updateContentScale(scale_factor, scale_factor);
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // Modifier state must be refreshed even when the position is later
        // deduplicated so subsequent mouse events use the current modifiers.
        self.core_surface.modsChanged(mods);

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
        _ = self;
        var env = try global.environMap();
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                _ = env.orderedRemove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                _ = env.orderedRemove("__XPC_DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("DYLD_FRAMEWORK_PATH");
                _ = env.orderedRemove("DYLD_INSERT_LIBRARIES");
                _ = env.orderedRemove("DYLD_LIBRARY_PATH");
                _ = env.orderedRemove("LD_LIBRARY_PATH");
                _ = env.orderedRemove("SECURITYSESSIONID");
                _ = env.orderedRemove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            _ = env.orderedRemove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) _ = env.orderedRemove("LANGUAGE");
        }

        return env;
    }

    pub fn hostManagedTermioConfig(self: *const Surface) ?termio.HostManaged.Config {
        if (self.io_backend != .host_managed) return null;
        return .{
            .userdata = self.receive_userdata,
            .receive_buffer = self.receive_buffer,
            .receive_resize = self.receive_resize,
        };
    }

    pub fn termioBackend(self: *const Surface) SurfaceIOBackend {
        return self.io_backend;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.Io.Timestamp = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(prev.durationTo(now).toNanoseconds());
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    // ghostty_clipboard_content_s
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*:0]const u8,
    };

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc().free(ptr[0..self.text_len :0]);
            }
        }
    };

    const SnapshotFlags = struct {
        const bold: u16 = 1 << 0;
        const italic: u16 = 1 << 1;
        const faint: u16 = 1 << 2;
        const inverse: u16 = 1 << 4;
        const invisible: u16 = 1 << 5;
        const strikethrough: u16 = 1 << 6;
        const underline: u16 = 1 << 7;
        const spacer: u16 = 1 << 10;
        const row_wrap: u16 = 1 << 11;
        const row_wrap_continuation: u16 = 1 << 12;
    };

    /// Bit values for `Snapshot.selection_flags`. Kept in sync with the identically named bits
    /// documented on `ghostty_terminal_snapshot_s` in include/ghostty.h.
    const SelectionFlags = struct {
        const present: u8 = 1 << 0;
        const rectangle: u8 = 1 << 1;
        const extends_above: u8 = 1 << 2;
        const extends_below: u8 = 1 << 3;
    };

    const SessionConfig = extern struct {
        surface: Surface.Options = .{},
        parked_host: SurfaceHost = .{},
    };

    /// The most codepoints a snapshot cell's grapheme cluster carries, base included. A cell whose
    /// cluster is longer (combining-mark spam, which no legitimate glyph needs) exports as its base
    /// codepoint alone, which bounds both the per-cell copy the export makes and the work the apply
    /// path does per cell.
    const snapshot_max_grapheme_codepoints = 16;

    const SnapshotCell = extern struct {
        codepoint: u32 = 0,
        foreground_rgb: u32 = 0,
        background_rgb: u32 = 0,
        flags: u16 = 0,
        /// The cluster's codepoints beyond `codepoint` (combining marks, ZWJ members, variation
        /// selectors, regional indicators). Zero and null for the overwhelming majority of cells,
        /// which hold a single codepoint. Owned by the Snapshot and released by its deinit.
        grapheme_extra_len: u16 = 0,
        grapheme_extras: ?[*]u32 = null,

        /// The 1-based index of this cell's OSC 8 hyperlink target in the snapshot's link table;
        /// zero when the cell carries no link. Export-only: `applySnapshotToSurface` ignores it.
        link_index: u32 = 0,

        /// The cell's cluster codepoints beyond the base, clamped to the documented cap. Both the
        /// capacity pass and the write pass of `applySnapshotToSurface` read the extras through
        /// here so they cannot disagree about how much a cell contributes.
        fn graphemeExtras(self: SnapshotCell) []const u32 {
            const ptr = self.grapheme_extras orelse return &.{};
            const len = @min(self.grapheme_extra_len, snapshot_max_grapheme_codepoints - 1);
            return ptr[0..len];
        }
    };

    /// A borrowed run of bytes in a snapshot. Owned by the Snapshot and released by its deinit.
    const SnapshotString = extern struct {
        ptr: ?[*]const u8 = null,
        len: usize = 0,
    };

    const SnapshotScrollRect = extern struct {
        row_start: u16 = 0,
        row_count: u16 = 0,
        column_start: u16 = 0,
        column_count: u16 = 0,
        delta_rows: i32 = 0,
        delta_columns: i32 = 0,
    };

    const Snapshot = extern struct {
        columns: u16 = 0,
        rows: u16 = 0,
        cursor_column: u16 = 0,
        cursor_row: u16 = 0,
        cursor_visible: bool = false,
        default_foreground_rgb: u32 = 0,
        default_background_rgb: u32 = 0,
        cell_count: usize = 0,
        cells: ?[*]SnapshotCell = null,
        scroll_rect_count: usize = 0,
        scroll_rects: ?[*]SnapshotScrollRect = null,
        /// True when `scroll_rects` fully describes content movement since the previous frame (no
        /// overflow of the exporting terminal's pending-scroll-rect ring buffer). A mirror's local
        /// drag-carry math is only valid to apply when this is true; false means the mirror cannot
        /// know how content moved and must cancel any in-progress drag instead of guessing.
        scroll_carry_valid: bool = false,
        /// Bits from `SelectionFlags`. Zero (no bit set) means the exporting terminal has no
        /// selection to paint; `selection_start_*`/`selection_end_*` are meaningful only when
        /// `SelectionFlags.present` is set.
        selection_flags: u8 = 0,
        /// The exported selection's endpoints, viewport-relative and clipped to the grid, ordered
        /// start before end. Zero when no selection is present.
        selection_start_x: u16 = 0,
        selection_start_y: u16 = 0,
        selection_end_x: u16 = 0,
        selection_end_y: u16 = 0,
        /// Total rows in the exporting terminal's screen plus scrollback, and the screen-space row
        /// index of the viewport top. Same semantics as `PageList.scrollbar()`.
        scrollbar_total: u32 = 0,
        scrollbar_offset: u32 = 0,
        /// True when the terminal has any mouse tracking mode enabled. Mirrors need this to make
        /// the same click-versus-selection decision the exporting terminal would make.
        mouse_reporting_active: bool = false,
        /// terminal.flags.mouse_shift_capture as 0 = unset, 1 = false, 2 = true.
        mouse_shift_capture: u8 = 0,
        /// The OSC 8 hyperlink targets this snapshot's cells reference, deduplicated by URI bytes.
        /// A cell's `link_index` is 1-based into this table. Populated on export only.
        link_count: usize = 0,
        links: ?[*]SnapshotString = null,

        pub fn deinit(self: *Snapshot) void {
            if (self.cells) |ptr| {
                const cells = ptr[0..self.cell_count];
                freeSnapshotCellGraphemes(cells);
                global.alloc().free(cells);
                self.cells = null;
            }
            self.cell_count = 0;
            if (self.scroll_rects) |ptr| {
                global.alloc().free(ptr[0..self.scroll_rect_count]);
                self.scroll_rects = null;
            }
            self.scroll_rect_count = 0;
            if (self.links) |ptr| {
                const links = ptr[0..self.link_count];
                freeSnapshotLinkStrings(links);
                global.alloc().free(links);
                self.links = null;
            }
            self.link_count = 0;
        }
    };

    const RenderFrame = extern struct {
        version: u32 = 1,
        session_revision: u64 = 0,
        owner_epoch: u64 = 0,
        columns: u16 = 0,
        rows: u16 = 0,
        snapshot: Snapshot = .{},

        pub fn deinit(self: *RenderFrame) void {
            self.snapshot.deinit();
            self.columns = 0;
            self.rows = 0;
        }
    };

    /// Releases the grapheme extras every cell in the slice owns. Snapshot teardown and the export
    /// path's failure exit both go through this, so a partially filled cell buffer cannot leak the
    /// clusters already copied into it.
    fn freeSnapshotCellGraphemes(cells: []SnapshotCell) void {
        for (cells) |cell| {
            const ptr = cell.grapheme_extras orelse continue;
            global.alloc().free(ptr[0..cell.grapheme_extra_len]);
        }
    }

    /// Releases the URI bytes every entry in a snapshot's link table owns, leaving the table itself
    /// to the caller. Snapshot teardown and the export path's failure exit both go through this.
    fn freeSnapshotLinkStrings(links: []const SnapshotString) void {
        for (links) |link| {
            const ptr = link.ptr orelse continue;
            global.alloc().free(ptr[0..link.len]);
        }
    }

    /// Releases everything a half-built snapshot export owns: the clusters of the `written` cells
    /// already filled in, the cell buffer itself, and the link table accumulated so far. The export
    /// returns a bool rather than an error union, so its failure exits unwind through here instead
    /// of through `errdefer`.
    fn abortSnapshotExport(
        cells: []SnapshotCell,
        written: usize,
        links: *std.ArrayListUnmanaged(SnapshotString),
    ) void {
        freeSnapshotCellGraphemes(cells[0..written]);
        if (cells.len > 0) global.alloc().free(cells);
        freeSnapshotLinkStrings(links.items);
        links.deinit(global.alloc());
    }

    /// The 1-based index of `uri` in a snapshot's link table, appending a copy of it when this is
    /// the first cell to reference it. Deduplication is by URI bytes rather than by hyperlink id
    /// because ids are page-local: the same link on two pages of one viewport has two ids, and two
    /// unrelated links on different pages can share one.
    fn snapshotLinkIndex(
        links: *std.ArrayListUnmanaged(SnapshotString),
        uri: []const u8,
    ) !u32 {
        for (links.items, 0..) |link, index| {
            const existing = link.ptr orelse continue;
            if (std.mem.eql(u8, existing[0..link.len], uri)) return @intCast(index + 1);
        }
        const copied = try global.alloc().dupe(u8, uri);
        errdefer global.alloc().free(copied);
        try links.append(global.alloc(), .{ .ptr = copied.ptr, .len = copied.len });
        return @intCast(links.items.len);
    }

    fn unpackRGB(rgb: u32) terminal.color.RGB {
        return .{
            .r = @intCast((rgb >> 16) & 0xFF),
            .g = @intCast((rgb >> 8) & 0xFF),
            .b = @intCast(rgb & 0xFF),
        };
    }

    fn styleForSnapshotCell(cell: SnapshotCell, snapshot: Snapshot) terminal.Style {
        var result: terminal.Style = .{};
        const foreground = unpackRGB(cell.foreground_rgb);
        const background = unpackRGB(cell.background_rgb);
        if (!foreground.eql(unpackRGB(snapshot.default_foreground_rgb))) {
            result.fg_color = .{ .rgb = foreground };
        }
        if (!background.eql(unpackRGB(snapshot.default_background_rgb))) {
            result.bg_color = .{ .rgb = background };
        }
        result.flags.bold = (cell.flags & SnapshotFlags.bold) != 0;
        result.flags.italic = (cell.flags & SnapshotFlags.italic) != 0;
        result.flags.faint = (cell.flags & SnapshotFlags.faint) != 0;
        result.flags.inverse = (cell.flags & SnapshotFlags.inverse) != 0;
        result.flags.invisible = (cell.flags & SnapshotFlags.invisible) != 0;
        result.flags.strikethrough = (cell.flags & SnapshotFlags.strikethrough) != 0;
        result.flags.underline = if ((cell.flags & SnapshotFlags.underline) != 0) .single else .none;
        return result;
    }

    fn cellForSnapshotCell(cell: SnapshotCell) terminal.Cell {
        if (cell.codepoint == 0) return .{};
        var result = terminal.Cell.init(@intCast(cell.codepoint));
        if ((cell.flags & SnapshotFlags.spacer) != 0) {
            result.wide = .spacer_tail;
        }
        return result;
    }

    /// Writes a snapshot cell's cluster codepoints onto the cell just written, so a mirror renders
    /// the whole grapheme rather than its base scalar.
    ///
    /// This uses `setGraphemes` (one exact allocation) rather than repeated `appendGrapheme` calls:
    /// appending grows the cell's grapheme slice in place, which both holds the old and the new
    /// allocation live at once and leaves the page's bitmap allocator fragmented, so a page sized
    /// for exactly what the frame holds could still fail. `applySnapshotToSurface` sizes the page's
    /// grapheme capacity for the sum of these exact allocations before writing any cell.
    fn writeSnapshotCellGraphemes(
        page: *terminal.Page,
        row: *terminal.page.Row,
        dst: *terminal.Cell,
        cell: SnapshotCell,
    ) !void {
        const extras = cell.graphemeExtras();
        if (extras.len == 0) return;

        var cps: [snapshot_max_grapheme_codepoints - 1]u21 = undefined;
        var len: usize = 0;
        for (extras) |cp| {
            // These arrive across a C ABI, so a value outside the Unicode range is representable
            // here in a way it never is for terminal-internal data. It has no glyph and does not
            // fit a u21, so the cluster ends there and the cell keeps what came before it.
            if (cp > 0x10FFFF) break;
            cps[len] = @intCast(cp);
            len += 1;
        }
        if (len == 0) return;
        try page.setGraphemes(row, dst, cps[0..len]);
    }

    fn writeSnapshotCell(
        screen: *terminal.Screen,
        page: *terminal.Page,
        row: *terminal.page.Row,
        dst: *terminal.Cell,
        cell: SnapshotCell,
        snapshot: Snapshot,
    ) !void {
        var next_cell = cellForSnapshotCell(cell);
        const next_style = styleForSnapshotCell(cell, snapshot);
        if (!next_style.default()) {
            const style_id = try page.styles.add(page.memory, next_style);
            next_cell.style_id = style_id;
            row.styled = true;
        }
        if (next_cell.codepoint() != 0 or !next_style.default()) {
            dst.* = next_cell;
            if (next_cell.codepoint() != 0) try writeSnapshotCellGraphemes(page, row, dst, cell);
        } else if (!unpackRGB(cell.background_rgb).eql(unpackRGB(snapshot.default_background_rgb))) {
            dst.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = @intCast((cell.background_rgb >> 16) & 0xFF),
                    .g = @intCast((cell.background_rgb >> 8) & 0xFF),
                    .b = @intCast(cell.background_rgb & 0xFF),
                } },
            };
        }
        row.dirty = true;
        screen.dirty.selection = true;
    }

    /// The signed, viewport-relative virtual position of an in-progress local drag's anchor (the
    /// pin tracking where the left press landed), carried across frame applies via the snapshot's
    /// scroll rects.
    ///
    /// A mirror repaints its whole grid every frame and holds no scrollback (see the doc comment
    /// on `applySnapshotToSurface`), so once the content the anchor was on scrolls above row 0
    /// there is no pin left to track it with: the anchor becomes purely virtual, tracked here as
    /// a coordinate that can run negative, until it either scrolls back into the grid or the drag
    /// ends. `Surface.mirror_drag_carry` holds this across applies; it survives release so a
    /// client can query the drag's final shape via `ghostty_mirror_selection_info` right after
    /// delivering the mouse-up, and is discarded on the next press or on any apply with no local
    /// drag in progress.
    const MirrorDragCarry = struct {
        anchor_x: i32,
        anchor_y: i32,

        /// Preserved so `ghostty_mirror_selection_info` can report the drag's shape without
        /// needing the live, frame-painted selection, which does not exist while the anchor is
        /// virtual (no pin on the current grid corresponds to it).
        rectangle: bool,
    };

    /// Shifts a virtual drag anchor by the content movement `rects` describe, applying the same
    /// delta a real cell at that position would receive: a rect's `delta_rows`/`delta_columns`
    /// apply when the anchor falls inside its `[row_start, row_start + row_count)` x
    /// `[column_start, column_start + column_count)` region.
    ///
    /// Once the anchor has gone above the viewport (negative `y`) no rect region can contain it,
    /// since a rect's coordinates are always grid-relative and non-negative. Content leaving the
    /// top of the viewport keeps pushing that already-virtual anchor further up at the same rate;
    /// a rect spanning the full grid width and starting at row 0 represents exactly that, so only
    /// rects of that shape move a negative anchor. Any other rect says nothing about content above
    /// the viewport and leaves it alone. Pure and grid-state-free so it can be unit tested
    /// directly against literal scroll rects.
    fn shiftVirtualDragAnchor(
        x: i32,
        y: i32,
        columns: u16,
        rects: []const SnapshotScrollRect,
    ) struct { x: i32, y: i32 } {
        var out_x = x;
        var out_y = y;
        for (rects) |rect| {
            if (out_y < 0) {
                const full_width = rect.column_start == 0 and rect.column_count >= columns;
                if (rect.row_start == 0 and full_width) {
                    out_y += rect.delta_rows;
                    out_x += rect.delta_columns;
                }
                continue;
            }

            const row_start: i32 = rect.row_start;
            const row_end: i32 = row_start + @as(i32, rect.row_count);
            const column_start: i32 = rect.column_start;
            const column_end: i32 = column_start + @as(i32, rect.column_count);
            if (out_y >= row_start and out_y < row_end and
                out_x >= column_start and out_x < column_end)
            {
                out_y += rect.delta_rows;
                out_x += rect.delta_columns;
            }
        }
        return .{ .x = out_x, .y = out_y };
    }

    /// Clamps a (possibly virtual: negative, or beyond the grid) coordinate into `[0, columns) x
    /// [0, rows)` and pins it on the just-painted grid. `columns`/`rows` describe that grid, so
    /// the lookup cannot fail and callers do not need to handle a null case.
    fn clampedDragPin(
        screen: *terminal.Screen,
        x: i32,
        y: i32,
        columns: u16,
        rows: u16,
    ) terminal.Pin {
        const clamped_x: terminal.size.CellCountInt = if (x < 0)
            0
        else
            @intCast(@min(x, @as(i32, columns) - 1));
        const clamped_y: u32 = if (y < 0)
            0
        else
            @intCast(@min(y, @as(i32, rows) - 1));
        return screen.pages.pin(.{ .active = .{ .x = clamped_x, .y = clamped_y } }).?;
    }

    /// Reads the coordinate of the gesture's tracked click pin before the grid-wiping reset, for
    /// simple (non-drag-carrying) re-anchoring afterward. Read through `validatedLeftClickPin` so
    /// a pin belonging to a screen the gesture no longer owns is never resurrected on this one.
    fn captureClickCoordinate(surface: *Surface, terminal_state: *terminal.Terminal) ?terminal.point.Coordinate {
        const gesture = &surface.core_surface.mouse.selection_gesture;
        if (gesture.left_click_count == 0) return null;
        const pin = gesture.validatedLeftClickPin(&terminal_state.screens) orelse return null;
        const screen = terminal_state.screens.active;
        const pt = screen.pages.pointFromPin(.active, pin.*) orelse return null;
        return pt.coord();
    }

    /// Re-anchors the gesture's tracked click pin at a coordinate captured before the destructive
    /// grid reset, or ends the gesture if that coordinate no longer fits the grid this frame
    /// painted (or was never captured at all). Used whenever there is no drag carry to apply
    /// instead: a lingering multi-click still needs a valid pin for the next click to compare
    /// against, and a fresh press with no selection yet has nothing to carry.
    fn rebindOrResetClick(
        gesture: *terminal.SelectionGesture,
        terminal_state: *terminal.Terminal,
        screen: *terminal.Screen,
        coord: ?terminal.point.Coordinate,
    ) !void {
        if (coord) |c| {
            if (screen.pages.pin(.{ .active = c })) |pin| {
                try gesture.rebindLeftClickPin(terminal_state, pin);
                return;
            }
        }
        if (gesture.left_click_count > 0) gesture.reset(terminal_state);
    }

    /// Paints the mirror's selection from a snapshot's viewport-relative fields, or clears it when
    /// the snapshot carries none. Goes through `Screen.select`/`clearSelection`, the same plain
    /// mutation path local selection changes that must not copy to the clipboard use, so applying
    /// a frame never triggers a clipboard write (only the mouse release path does that, via
    /// `Surface.setSelectionAndCopy`, which this never calls).
    fn applyMirrorSelectionFromSnapshot(screen: *terminal.Screen, snapshot: Snapshot) !void {
        if (snapshot.selection_flags & SelectionFlags.present == 0) {
            screen.clearSelection();
            return;
        }

        const start = screen.pages.pin(.{ .active = .{
            .x = snapshot.selection_start_x,
            .y = snapshot.selection_start_y,
        } }) orelse {
            screen.clearSelection();
            return;
        };
        const end = screen.pages.pin(.{ .active = .{
            .x = snapshot.selection_end_x,
            .y = snapshot.selection_end_y,
        } }) orelse {
            screen.clearSelection();
            return;
        };
        try screen.select(terminal.Selection.init(
            start,
            end,
            snapshot.selection_flags & SelectionFlags.rectangle != 0,
        ));
    }

    /// A local drag's selection endpoints and shape, captured as active-area coordinates before
    /// the destructive grid reset.
    const MirrorDragSelection = struct {
        start: terminal.point.Coordinate,
        end: terminal.point.Coordinate,
        rectangle: bool,
    };

    /// Reads the live selection a local drag has already produced (via the surface's own mouse
    /// handling, which calls into `SelectionGesture` directly and is not part of frame apply).
    /// Null when the drag has not moved the mouse yet, so `press` has not produced a selection
    /// (see the `SelectionGesture` doc comment: a bare press returns null by default).
    fn captureDragSelection(terminal_state: *terminal.Terminal) ?MirrorDragSelection {
        const screen = terminal_state.screens.active;
        const sel = screen.selection orelse return null;
        const start = screen.pages.pointFromPin(.active, sel.start()) orelse return null;
        const end = screen.pages.pointFromPin(.active, sel.end()) orelse return null;
        return .{ .start = start.coord(), .end = end.coord(), .rectangle = sel.rectangle };
    }

    /// Writes a snapshot onto a mirror surface's terminal state.
    ///
    /// A mirror is viewport-only: it holds no scrollback and every frame rewrites the whole grid.
    /// Its selection is therefore shared with the exporting (host) terminal rather than an
    /// independent local one, except while the mirror surface itself is in the middle of a local
    /// left-button drag:
    ///
    ///  * No drag in progress: the frame is authoritative. Its selection fields (viewport-relative,
    ///    already clipped by the export side) are painted via `applyMirrorSelectionFromSnapshot`,
    ///    replacing whatever the mirror had. This is also what clears a selection the host ended.
    ///  * A drag is in progress: the local gesture is authoritative and the frame's selection is
    ///    never painted, so a live drag is never interrupted by a frame that raced it. The drag's
    ///    anchor (the pin at the original press location) is carried across the reset using the
    ///    snapshot's scroll rects, since a coordinate alone cannot survive `fullReset` once its
    ///    content has scrolled out of the grid entirely (see `MirrorDragCarry`). A frame that
    ///    cannot describe how content moved (`scroll_carry_valid == false`) or that resizes the
    ///    grid out from under the drag cancels it instead of guessing.
    ///
    /// A cell's OSC 8 link fields (`link_index` and the snapshot's link table) are deliberately not
    /// applied: they are export-only. Restoring them would mean sizing a page's `string_bytes` and
    /// `hyperlink_bytes` capacity as well, and Spaces already resolves link hover and clicks from
    /// the Swift snapshot rather than from the mirror surface.
    fn applySnapshotToSurface(surface: *Surface, snapshot: Snapshot) !void {
        if (snapshot.columns == 0 or snapshot.rows == 0) return error.InvalidRenderFrame;
        const expected_cell_count = @as(usize, snapshot.columns) * @as(usize, snapshot.rows);
        if (snapshot.cell_count < expected_cell_count or snapshot.cells == null) return error.InvalidRenderFrame;
        if (snapshot.scroll_rect_count > 0 and snapshot.scroll_rects == null) return error.InvalidRenderFrame;

        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const terminal_state = core_surface.renderer_state.terminal;
        const mouse = &core_surface.mouse;
        const gesture = &mouse.selection_gesture;

        // A local left-button drag is "in progress" when the button is physically down and the
        // gesture has an active click to extend. Both conditions matter: `left_click_count` alone
        // intentionally stays positive between the clicks of a double/triple-click sequence with
        // the button up (see the `SelectionGesture` doc comment), and that lingering state must
        // not lock the mirror into drag mode, which would stop painting the host's selection while
        // the user is not actually touching this surface.
        const left_idx = @intFromEnum(input.MouseButton.left);
        const drag_in_progress = mouse.click_state[left_idx] == .press and gesture.left_click_count > 0;

        // Grid dimensions before the resize below, compared against the snapshot's to decide
        // whether a drag carry can trust the scroll rects: the rects describe movement within the
        // OLD grid, and a resize landing between two applies invalidates that geometry entirely.
        const grid_changed = terminal_state.cols != snapshot.columns or terminal_state.rows != snapshot.rows;

        // Everything a later branch needs from the live gesture/selection is read now, before the
        // `fullReset` below clears the selection and re-anchors every tracked pin (the click pin
        // among them) at the top-left. Mouse input and frame applies both run on the host app's
        // main thread and this holds the renderer state mutex, so this state cannot change under
        // us between the read and the reset.
        const click_coord = captureClickCoordinate(surface, terminal_state);
        const drag_selection = if (drag_in_progress) captureDragSelection(terminal_state) else null;

        try terminal_state.resize(
            global.alloc(),
            .{
                .cols = @intCast(snapshot.columns),
                .rows = @intCast(snapshot.rows),
            },
        );
        terminal_state.fullReset();
        terminal_state.colors.foreground.set(unpackRGB(snapshot.default_foreground_rgb));
        terminal_state.colors.background.set(unpackRGB(snapshot.default_background_rgb));
        terminal_state.flags.dirty.clear = true;
        terminal_state.flags.dirty.palette = true;

        const screen = terminal_state.screens.active;
        const frame_cells = snapshot.cells.?[0..expected_cell_count];

        // Size the page for every cluster this frame carries before touching a single cell. Growing
        // reactively (the recipe Screen.appendGrapheme follows) relocates the page and invalidates
        // the page, row, and cell pointers the write loop below holds; deciding capacity up front
        // keeps them valid for the whole loop. The page is already being resized and fully reset
        // just above, so a capacity decision here costs nothing extra.
        var required_grapheme_bytes: usize = 0;
        for (frame_cells) |frame_cell| {
            const extras = frame_cell.graphemeExtras();
            if (extras.len == 0) continue;
            required_grapheme_bytes += terminal.page.graphemeBytesRequired(extras.len);
        }
        var node = screen.pages.pages.last.?;
        while (node.page().capacity.grapheme_bytes < required_grapheme_bytes) {
            node = try screen.increaseCapacity(node, .grapheme_bytes);
        }

        const page = node.page();
        const grid_rows = page.rows.ptr(page.memory)[0..snapshot.rows];

        for (grid_rows, 0..) |*row, row_index| {
            const cells = row.cells.ptr(page.memory)[0..snapshot.columns];
            screen.clearCells(page, row, cells);
            row.* = .{ .cells = row.cells, .dirty = true };
            const frame_row = frame_cells[row_index * snapshot.columns .. (row_index + 1) * snapshot.columns];
            if (frame_row.len > 0) {
                const row_flags = frame_row[0].flags;
                row.wrap = (row_flags & SnapshotFlags.row_wrap) != 0;
                row.wrap_continuation = (row_flags & SnapshotFlags.row_wrap_continuation) != 0;
            }
            for (cells, frame_row) |*dst, frame_cell| {
                try writeSnapshotCell(screen, page, row, dst, frame_cell, snapshot);
            }
        }

        screen.cursorAbsolute(
            @min(snapshot.cursor_column, snapshot.columns - 1),
            @min(snapshot.cursor_row, snapshot.rows - 1),
        );
        terminal_state.modes.set(.cursor_visible, snapshot.cursor_visible);
        // Restore the exporting terminal's mouse tracking state so this surface arbitrates clicks
        // exactly as the exporting one would: suppressing selection while an application tracks the
        // mouse, and honoring an explicit shift-capture request. Every active tracking mode maps to
        // .normal because a mirror has no write sink for the report it would encode; only whether
        // tracking is on changes surface-local behavior.
        terminal_state.flags.mouse_event = if (snapshot.mouse_reporting_active) .normal else .none;
        terminal_state.flags.mouse_shift_capture = switch (snapshot.mouse_shift_capture) {
            1 => .false,
            2 => .true,
            else => .null,
        };
        screen.cursor.page_row.dirty = true;

        // Selection handling happens last so it resolves against the pages this frame actually
        // wrote, after the grapheme capacity growth above.
        if (!drag_in_progress) {
            // No local drag owns the mirror's selection: paint whatever the frame carries, and
            // drop any carry state from a drag that just ended. (Its last carrying apply already
            // ran with drag_in_progress true; this apply, with the button up, is the one that
            // discards it.)
            surface.mirror_drag_carry = null;
            try applyMirrorSelectionFromSnapshot(screen, snapshot);
            try rebindOrResetClick(gesture, terminal_state, screen, click_coord);
            return;
        }

        // A local drag owns the mirror's selection: never paint the frame's, and cancel instead of
        // guessing when the frame cannot describe how content moved, or the grid changed under the
        // drag. Both make the scroll rects meaningless for carrying the anchor, so the drag simply
        // ends with no selection; the user's next press starts fresh.
        if (!snapshot.scroll_carry_valid or grid_changed) {
            surface.mirror_drag_carry = null;
            screen.clearSelection();
            gesture.reset(terminal_state);
            return;
        }

        const selection = drag_selection orelse {
            // A press with no selection yet (no movement, or a click that intentionally selects
            // nothing on its own): nothing to carry or paint, but the click pin still needs a
            // valid anchor on the repainted grid for the drag that starts moving it.
            surface.mirror_drag_carry = null;
            try rebindOrResetClick(gesture, terminal_state, screen, click_coord);
            return;
        };

        // The anchor is the selection's start endpoint and the live drag point is its end
        // endpoint. This is exact for the default cell-behavior drag, which covers the
        // overwhelming majority of drags including every autoscroll case. Word, line, and output
        // behaviors can invert which endpoint moves with the mouse depending on drag direction
        // (see dragSelectionWord/dragSelectionLine in SelectionGesture.zig); a scroll-carrying
        // frame apply that lands mid-drag on one of those, in the direction where the mapping
        // inverts, carries the wrong endpoint and degrades that drag to a plain cell-shape
        // selection for the rest of the gesture.
        //
        // Deviation from the spec's literal anchor definition, accepted because disambiguating
        // which endpoint is the press location would require matching it against the gesture's
        // tracked click pin through word/line boundary snapping rather than a direct coordinate
        // comparison, and the failure mode self-corrects: the next local mouse-move event
        // recomputes the true selection from the gesture's own drag logic, unaffected by this
        // simplification.
        const rects: []const SnapshotScrollRect = if (snapshot.scroll_rect_count > 0)
            snapshot.scroll_rects.?[0..snapshot.scroll_rect_count]
        else
            &.{};

        const anchor_baseline: struct { x: i32, y: i32 } = if (surface.mirror_drag_carry) |carry|
            .{ .x = carry.anchor_x, .y = carry.anchor_y }
        else
            .{ .x = selection.start.x, .y = @intCast(selection.start.y) };
        const anchor = shiftVirtualDragAnchor(anchor_baseline.x, anchor_baseline.y, snapshot.columns, rects);

        surface.mirror_drag_carry = .{
            .anchor_x = anchor.x,
            .anchor_y = anchor.y,
            .rectangle = selection.rectangle,
        };

        // The drag point never needs multi-frame memory: the mouse can only be over the visible
        // surface while dragging, so it is always re-derived fresh from the live selection rather
        // than carried.
        const other_x: i32 = selection.end.x;
        const other_y: i32 = @intCast(selection.end.y);

        const anchor_pin = clampedDragPin(screen, anchor.x, anchor.y, snapshot.columns, snapshot.rows);
        const other_pin = clampedDragPin(screen, other_x, other_y, snapshot.columns, snapshot.rows);
        try screen.select(terminal.Selection.init(anchor_pin, other_pin, selection.rectangle));
        try gesture.rebindLeftClickPin(terminal_state, anchor_pin);
    }

    const Session = struct {
        app: *App,
        surface: *Surface,
        parked_host: SurfaceHost,
        renderers: std.ArrayListUnmanaged(*Renderer) = .empty,
        owner_renderer: ?*Renderer = null,
        state_mutex: std.Io.Mutex = .init,
        state_callback: ?SessionStateCallback = null,
        state_callback_userdata: ?*anyopaque = null,
        state_revision: u64 = 0,
        pending_state_flags: SessionStateFlags = .{},
        last_known_foreground_pid: u64 = 0,
        last_known_surface_size: SurfaceSize = .{
            .columns = 0,
            .rows = 0,
            .width_px = 0,
            .height_px = 0,
            .cell_width_px = 0,
            .cell_height_px = 0,
        },

        pub fn init(self: *Session, app: *App, config: SessionConfig, headless: bool) !void {
            const surface = try app.newSurface(config.surface, headless);
            const parked_host: SurfaceHost = if (config.parked_host.isValid()) .{
                .platform_tag = config.parked_host.platform_tag,
                .platform = config.parked_host.platform,
                .scale_factor = config.parked_host.scale_factor,
            } else .{
                .platform_tag = config.surface.platform_tag,
                .platform = config.surface.platform,
                .scale_factor = config.surface.scale_factor,
            };

            self.* = .{
                .app = app,
                .surface = surface,
                .parked_host = parked_host,
                .renderers = .empty,
                .owner_renderer = null,
                .state_mutex = .init,
                .state_callback = null,
                .state_callback_userdata = null,
                .state_revision = 0,
                .pending_state_flags = .{},
                .last_known_foreground_pid = 0,
                .last_known_surface_size = .{
                    .columns = 0,
                    .rows = 0,
                    .width_px = 0,
                    .height_px = 0,
                    .cell_width_px = 0,
                    .cell_height_px = 0,
                },
            };
            self.surface.setSessionStateCallback(surfaceStateCallback, self);
            self.last_known_foreground_pid = self.currentForegroundPID();
            self.last_known_surface_size = self.currentSurfaceSize();
        }

        pub fn deinit(self: *Session) void {
            for (self.renderers.items) |renderer_handle| {
                renderer_handle.attached_session = null;
                renderer_handle.role = .detached;
            }
            self.renderers.deinit(global.alloc());
            self.owner_renderer = null;
            self.surface.setSessionStateCallback(null, null);
            self.app.closeSurface(self.surface);
        }

        pub fn attachRenderer(self: *Session, renderer_handle: *Renderer) !void {
            if (renderer_handle.attached_session) |existing_session| {
                if (existing_session != self) try renderer_handle.detach();
            }

            try self.promoteRenderer(renderer_handle);
        }

        pub fn attachViewer(self: *Session, renderer_handle: *Renderer) !void {
            if (renderer_handle.attached_session) |existing_session| {
                if (existing_session != self) try renderer_handle.detach();
                if (existing_session == self) {
                    try self.ensureRendererAttached(renderer_handle);
                    if (renderer_handle.role == .detached) renderer_handle.role = .viewer;
                    return;
                }
            }

            try self.ensureRendererAttached(renderer_handle);
            renderer_handle.attached_session = self;
            if (renderer_handle.role == .detached) renderer_handle.role = .viewer;
        }

        pub fn attachInitialOwnerRenderer(self: *Session, renderer_handle: *Renderer) !void {
            if (renderer_handle.attached_session) |existing_session| {
                if (existing_session != self) try renderer_handle.detach();
            }

            try self.ensureRendererAttached(renderer_handle);
            if (self.owner_renderer) |existing_owner| existing_owner.role = .viewer;
            self.owner_renderer = renderer_handle;
            renderer_handle.attached_session = self;
            renderer_handle.role = .owner;
        }

        pub fn promoteRenderer(self: *Session, renderer_handle: *Renderer) !void {
            const old_session = renderer_handle.attached_session;
            const old_role = renderer_handle.role;
            const was_registered = self.indexOfRenderer(renderer_handle) != null;
            errdefer {
                if (!was_registered) self.removeRenderer(renderer_handle);
                renderer_handle.attached_session = old_session;
                renderer_handle.role = old_role;
            }

            try self.ensureRendererAttached(renderer_handle);

            if (self.owner_renderer) |existing_owner| {
                if (existing_owner == renderer_handle) {
                    renderer_handle.attached_session = self;
                    renderer_handle.role = .owner;
                    return;
                }
            }

            try self.surface.setHost(renderer_handle.host);
            if (self.owner_renderer) |existing_owner| existing_owner.role = .viewer;
            self.owner_renderer = renderer_handle;
            renderer_handle.attached_session = self;
            renderer_handle.role = .owner;
            self.notifyStateChange(self.notifySizeIfChanged());
        }

        pub fn detachRenderer(self: *Session, renderer_handle: *Renderer) !void {
            if (renderer_handle.attached_session != self) return;

            if (self.owner_renderer == renderer_handle) {
                try self.surface.setHost(self.parked_host);
                self.notifyStateChange(self.notifySizeIfChanged());
                self.owner_renderer = null;
            }

            self.removeRenderer(renderer_handle);
            renderer_handle.attached_session = null;
            renderer_handle.role = .detached;
        }

        pub fn detachRendererForFree(self: *Session, renderer_handle: *Renderer) !void {
            if (renderer_handle.attached_session != self) return;

            if (self.owner_renderer == renderer_handle) {
                try self.surface.setHost(self.parked_host);
                self.notifyStateChange(self.notifySizeIfChanged());
                self.owner_renderer = null;
            }

            self.removeRenderer(renderer_handle);
            renderer_handle.attached_session = null;
            renderer_handle.role = .detached;
        }

        fn currentForegroundPID(self: *const Session) u64 {
            return self.surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
        }

        fn currentSurfaceSize(self: *const Session) SurfaceSize {
            const grid_size = self.surface.core_surface.size.grid();
            return .{
                .columns = grid_size.columns,
                .rows = grid_size.rows,
                .width_px = self.surface.core_surface.size.screen.width,
                .height_px = self.surface.core_surface.size.screen.height,
                .cell_width_px = self.surface.core_surface.size.cell.width,
                .cell_height_px = self.surface.core_surface.size.cell.height,
            };
        }

        pub fn setStateCallback(
            self: *Session,
            callback: ?SessionStateCallback,
            userdata: ?*anyopaque,
        ) void {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());

            self.state_callback = callback;
            self.state_callback_userdata = userdata;
        }

        pub fn notifyStateChange(self: *Session, flags: SessionStateFlags) void {
            if (flags.bits() == 0) return;

            var callback: ?SessionStateCallback = null;
            var userdata: ?*anyopaque = null;
            {
                self.state_mutex.lockUncancelable(global.io());
                defer self.state_mutex.unlock(global.io());

                self.state_revision +%= 1;
                self.pending_state_flags = self.pending_state_flags.unionWith(flags);
                callback = self.state_callback;
                userdata = self.state_callback_userdata;
            }

            if (callback) |cb| cb(userdata, flags.bits());
        }

        pub fn stateRevision(self: *Session) u64 {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());

            return self.state_revision;
        }

        pub fn takePendingStateFlags(self: *Session) SessionStateFlags {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());

            const pending = self.pending_state_flags;
            self.pending_state_flags = .{};
            return pending;
        }

        fn notifyForegroundProcessIfChanged(self: *Session) SessionStateFlags {
            const current = self.currentForegroundPID();
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());

            if (current == self.last_known_foreground_pid) return .{};
            self.last_known_foreground_pid = current;
            return .{ .foreground_process = true };
        }

        fn notifySizeIfChanged(self: *Session) SessionStateFlags {
            const current = self.currentSurfaceSize();
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());

            if (std.meta.eql(current, self.last_known_surface_size)) return .{};
            self.last_known_surface_size = current;
            return .{ .size = true };
        }

        fn notifyScreenMutation(self: *Session) void {
            var flags: SessionStateFlags = .{ .screen = true };
            flags = flags.unionWith(self.notifyForegroundProcessIfChanged());
            self.notifyStateChange(flags);
        }

        fn surfaceStateCallback(userdata: ?*anyopaque, flags_raw: u32) callconv(.c) void {
            const ptr = userdata orelse return;
            const session: *Session = @ptrCast(@alignCast(ptr));
            var flags: SessionStateFlags = @bitCast(flags_raw);
            if (flags.screen) {
                flags = flags.unionWith(session.notifyForegroundProcessIfChanged());
            }
            session.notifyStateChange(flags);
        }

        fn ensureRendererAttached(self: *Session, renderer_handle: *Renderer) !void {
            if (self.indexOfRenderer(renderer_handle) != null) return;
            try self.renderers.append(global.alloc(), renderer_handle);
        }

        fn indexOfRenderer(self: *const Session, renderer_handle: *Renderer) ?usize {
            for (self.renderers.items, 0..) |existing_renderer, index| {
                if (existing_renderer == renderer_handle) return index;
            }
            return null;
        }

        fn removeRenderer(self: *Session, renderer_handle: *Renderer) void {
            const index = self.indexOfRenderer(renderer_handle) orelse return;
            _ = self.renderers.swapRemove(index);
        }
    };

    const RendererRole = enum {
        detached,
        viewer,
        owner,
    };

    const Renderer = struct {
        host: SurfaceHost,
        attached_session: ?*Session = null,
        role: RendererRole = .detached,

        pub fn detach(self: *Renderer) !void {
            const session = self.attached_session orelse return;
            try session.detachRenderer(self);
        }

        pub fn detachForFree(self: *Renderer) !void {
            const session = self.attached_session orelse return;
            try session.detachRendererForFree(self);
        }

        pub fn takeOwnership(self: *Renderer) !void {
            const session = self.attached_session orelse return error.RendererDetached;
            try session.promoteRenderer(self);
        }

        pub fn setHost(self: *Renderer, host: SurfaceHost) !void {
            if (self.attached_session) |session| {
                if (self.host.eql(host)) {
                    self.host = host;
                    return;
                }

                if (self.role != .owner) {
                    self.host = host;
                    return;
                }

                try session.surface.setHost(host);
                self.host = host;
                session.notifyStateChange(session.notifySizeIfChanged());
                return;
            }

            self.host = host;
        }

        pub fn isOwner(self: *const Renderer) bool {
            return self.role == .owner;
        }
    };

    const Mirror = struct {
        app: *App,
        session: *Session,
        renderer: *Renderer,

        pub fn init(
            self: *Mirror,
            app: *App,
            host: SurfaceHost,
            config: SessionConfig,
        ) !void {
            var mirror_config = config;
            mirror_config.surface.platform_tag = host.platform_tag;
            mirror_config.surface.platform = host.platform;
            mirror_config.surface.scale_factor = host.scale_factor;
            mirror_config.parked_host = host;

            const session = try global.alloc().create(Session);
            errdefer global.alloc().destroy(session);
            try session.init(app, mirror_config, false);
            errdefer session.deinit();

            const renderer_handle = try global.alloc().create(Renderer);
            errdefer global.alloc().destroy(renderer_handle);
            renderer_handle.* = .{
                .host = host,
                .attached_session = null,
            };
            try session.attachInitialOwnerRenderer(renderer_handle);

            self.* = .{
                .app = app,
                .session = session,
                .renderer = renderer_handle,
            };
        }

        pub fn deinit(self: *Mirror) void {
            ghostty_renderer_free(self.renderer);
            ghostty_session_free(self.session);
        }
    };

    // ghostty_point_s
    const Point = extern struct {
        tag: Tag,
        coord_tag: CoordTag,
        x: u32,
        y: u32,

        const Tag = enum(c_int) {
            active = 0,
            viewport = 1,
            screen = 2,
            history = 3,
        };

        const CoordTag = enum(c_int) {
            exact = 0,
            top_left = 1,
            bottom_right = 2,
        };

        fn pin(
            self: Point,
            screen: *const terminal.Screen,
        ) ?terminal.Pin {
            // The core point tag.
            const tag: terminal.point.Tag = switch (self.tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = @min(self.y, screen.pages.rows -| 1);

            return switch (self.coord_tag) {
                // Exact coordinates require a specific pin.
                .exact => exact: {
                    const pt_x = std.math.cast(
                        terminal.size.CellCountInt,
                        clamped_x,
                    ) orelse std.math.maxInt(terminal.size.CellCountInt);

                    const pt: terminal.Point = switch (tag) {
                        inline else => |v| @unionInit(
                            terminal.Point,
                            @tagName(v),
                            .{ .x = pt_x, .y = clamped_y },
                        ),
                    };

                    break :exact screen.pages.pin(pt) orelse null;
                },

                .top_left => screen.pages.getTopLeft(tag),

                .bottom_right => screen.pages.getBottomRight(tag),
            };
        }
    };

    // ghostty_selection_s
    const Selection = extern struct {
        tl: Point,
        br: Point,
        rectangle: bool,

        fn core(
            self: Selection,
            screen: *const terminal.Screen,
        ) ?terminal.Selection {
            return .{
                .bounds = .{ .untracked = .{
                    .start = self.tl.pin(screen) orelse return null,
                    .end = self.br.pin(screen) orelse return null,
                } },
                .rectangle = self.rectangle,
            };
        }
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc());
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc().create(App);
        errdefer global.alloc().destroy(app);
        try app.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc().destroy(v);
        core_app.destroy();
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_config_key_is_binding(
        config: *Config,
        event: KeyEvent,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return config.keyEventIsBinding(core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, .new_window) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.enums.fromInt(apprt.ColorScheme, scheme_raw) orelse return;

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*, false);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    export fn ghostty_surface_write_buffer(
        surface: *Surface,
        ptr: ?[*]const u8,
        len: usize,
    ) void {
        const slice = ptr orelse return;
        surface.core_surface.io.processOutputBlocking(slice[0..len], true) catch |err| {
            log.err("error processing surface output err={}", .{err});
            return;
        };
    }

    export fn ghostty_surface_process_exit(surface: *Surface, exit_code: i32) void {
        surface.core_surface.io.queueProcessExit(sanitizeProcessExitCode(exit_code), 0);
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface: *Surface,
        source: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        return surface.newSurfaceOptions(source);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Same as ghostty_surface_read_text but reads from the user selection,
    /// if any.
    export fn ghostty_surface_read_selection(
        surface: *Surface,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        // If we don't have a selection, do nothing.
        const core_sel = core_surface.io.terminal.screens.active.selection orelse return false;

        // Read the text from the selection.
        return readTextLocked(surface, core_sel, result);
    }

    /// Sets a surface's selection from screen-space coordinates (row 0 is the oldest scrollback
    /// row, growing downward through the active area), for a host terminal to install a selection
    /// another party (a mirror, over the device API) asked for.
    ///
    /// Coordinates are clamped to the terminal's current grid/scrollback extent rather than
    /// rejected, since the caller's view of that extent (a mirror's last-applied frame) can be a
    /// few rows stale by the time this call lands; clamping keeps a slightly-stale request
    /// selecting the nearest still-valid cell instead of failing outright. Installed through
    /// `Surface.setRemoteSelection`, the notification-aware funnel every selection mutation uses
    /// (so the apprt hears `selection_changed`, without any clipboard write), which tracks the
    /// pins the same way a live mouse-driven selection does: the selection follows scrollback
    /// trimming and content edits like any other.
    ///
    /// Returns false only when the terminal has no rows at all, or a clamped coordinate still
    /// fails to resolve to a pin (both indicate an empty or otherwise unusable terminal, not a
    /// bad request).
    export fn ghostty_surface_set_selection_absolute(
        surface: *Surface,
        start_x: u16,
        start_y: u32,
        end_x: u16,
        end_y: u32,
        rectangle: bool,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        const ok = ok: {
            const terminal_state = core_surface.renderer_state.terminal;
            const screen = terminal_state.screens.active;
            const bar = screen.pages.scrollbar();
            if (bar.total == 0) break :ok false;

            const max_row: u32 = @intCast(bar.total - 1);
            const max_col: terminal.size.CellCountInt = terminal_state.cols - 1;
            const clamped_start: terminal.point.Coordinate = .{
                .x = @min(start_x, max_col),
                .y = @min(start_y, max_row),
            };
            const clamped_end: terminal.point.Coordinate = .{
                .x = @min(end_x, max_col),
                .y = @min(end_y, max_row),
            };

            const start_pin = screen.pages.pin(.{ .screen = clamped_start }) orelse break :ok false;
            const end_pin = screen.pages.pin(.{ .screen = clamped_end }) orelse break :ok false;
            core_surface.setRemoteSelection(terminal.Selection.init(start_pin, end_pin, rectangle)) catch break :ok false;
            break :ok true;
        };
        // Released before refresh() to match every other mutation-then-refresh call site in this
        // file (ghostty_surface_refresh, ghostty_session_refresh): refresh's own callback chain
        // may need the renderer state lock, so holding it here would deadlock.
        core_surface.renderer_state.mutex.unlock(global.io());
        if (ok) surface.refresh();
        return ok;
    }

    /// Clears a surface's selection, for a host terminal to drop a selection another party asked
    /// it to release (for example, a mirror-side click that ends the shared selection). Goes
    /// through `Surface.setRemoteSelection`, the notification-aware funnel every selection
    /// mutation uses, so the apprt hears `selection_changed` and no clipboard write happens
    /// (only the release path after an actual local drag copies).
    export fn ghostty_surface_clear_selection(surface: *Surface) void {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        // Clearing cannot fail: `setSelection(null)` only frees the tracked pins.
        core_surface.setRemoteSelection(null) catch {};
        core_surface.renderer_state.mutex.unlock(global.io());
        surface.refresh();
    }

    /// Read some arbitrary text from the surface.
    ///
    /// This is an expensive operation so it shouldn't be called too
    /// often. We recommend that callers cache the result and throttle
    /// calls to this function.
    export fn ghostty_surface_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer surface.core_surface.renderer_state.mutex.unlock(global.io());

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    fn readTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;

        // Get our text directly from the core surface.
        const text = core_surface.dumpTextLocked(
            global.alloc(),
            core_sel,
        ) catch |err| {
            log.warn("error reading text err={}", .{err});
            return false;
        };

        const vp: CoreSurface.Text.Viewport = text.viewport orelse .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
        };

        result.* = .{
            .tl_px_x = vp.tl_px_x,
            .tl_px_y = vp.tl_px_y,
            .offset_start = vp.offset_start,
            .offset_len = vp.offset_len,
            .text = text.text.ptr,
            .text_len = text.text.len,
        };

        return true;
    }

    fn packRGB(rgb: terminal.color.RGB) u32 {
        return (@as(u32, rgb.r) << 16) |
            (@as(u32, rgb.g) << 8) |
            @as(u32, rgb.b);
    }

    fn snapshotFlagsForCell(
        raw: terminal.Cell,
        style: terminal.Style,
    ) u16 {
        var flags: u16 = 0;
        if (style.flags.bold) flags |= SnapshotFlags.bold;
        if (style.flags.italic) flags |= SnapshotFlags.italic;
        if (style.flags.faint) flags |= SnapshotFlags.faint;
        if (style.flags.inverse) flags |= SnapshotFlags.inverse;
        if (style.flags.invisible) flags |= SnapshotFlags.invisible;
        if (style.flags.strikethrough) flags |= SnapshotFlags.strikethrough;
        if (style.flags.underline != .none) flags |= SnapshotFlags.underline;
        if (raw.wide == .spacer_head or raw.wide == .spacer_tail) flags |= SnapshotFlags.spacer;
        return flags;
    }

    fn snapshotFlagsForRow(row: terminal.page.Row) u16 {
        var flags: u16 = 0;
        if (row.wrap) flags |= SnapshotFlags.row_wrap;
        if (row.wrap_continuation) flags |= SnapshotFlags.row_wrap_continuation;
        return flags;
    }

    /// The result of projecting a terminal's selection into an exported viewport: which
    /// `SelectionFlags` bits apply and the clipped, viewport-relative endpoints. All zero
    /// (`flags == 0`) means no selection is exported, matching a zeroed `Snapshot`.
    const ExportedSelection = struct {
        flags: u8 = 0,
        start_x: u16 = 0,
        start_y: u16 = 0,
        end_x: u16 = 0,
        end_y: u16 = 0,
    };

    /// True if `screen`'s selection exists and has been pruned out from under it: PageList's
    /// prune step (PageList.zig, the tracked-pins loop in the prune block around line 4045)
    /// remaps a garbaged pin to a valid but meaningless (0, 0) coordinate rather than leaving it
    /// dangling, so a garbage pin cannot be detected by a failed pin lookup and must be checked
    /// directly. Shared by `projectSelectionForExport` (to export no selection) and
    /// `exportSnapshotFromSurface` (to actually clear the stale selection off the surface); see
    /// the latter for why both are needed.
    fn selectionGarbageAfterPrune(screen: *terminal.Screen) bool {
        const sel = screen.selection orelse return false;
        return sel.start().garbage or sel.end().garbage;
    }

    /// Projects `screen`'s selection into the viewport a snapshot is about to export, in
    /// screen-space rows starting at `viewport_top` and spanning `rows` rows of `columns` columns.
    ///
    /// A selection with no intersection with the viewport, or whose tracked pins were pruned out
    /// from under it (garbage, see `selectionGarbageAfterPrune`), exports as absent.
    fn projectSelectionForExport(
        screen: *terminal.Screen,
        viewport_top: u32,
        rows: u16,
        columns: u16,
    ) ExportedSelection {
        if (rows == 0 or columns == 0) return .{};
        const sel = screen.selection orelse return .{};
        if (selectionGarbageAfterPrune(screen)) return .{};

        const tl_pin = sel.topLeft(screen);
        const br_pin = sel.bottomRight(screen);
        const tl = (screen.pages.pointFromPin(.screen, tl_pin) orelse return .{}).screen;
        const br = (screen.pages.pointFromPin(.screen, br_pin) orelse return .{}).screen;

        const viewport_bottom = viewport_top + @as(u32, rows) - 1;
        if (tl.y > viewport_bottom or br.y < viewport_top) return .{};

        const last_column: u16 = columns - 1;
        var result: ExportedSelection = .{ .flags = SelectionFlags.present };
        if (sel.rectangle) result.flags |= SelectionFlags.rectangle;

        if (tl.y < viewport_top) {
            result.flags |= SelectionFlags.extends_above;
            result.start_y = 0;
            result.start_x = if (sel.rectangle) @min(tl.x, last_column) else 0;
        } else {
            result.start_y = @intCast(tl.y - viewport_top);
            result.start_x = @min(tl.x, last_column);
        }

        if (br.y > viewport_bottom) {
            result.flags |= SelectionFlags.extends_below;
            result.end_y = rows - 1;
            result.end_x = if (sel.rectangle) @min(br.x, last_column) else last_column;
        } else {
            result.end_y = @intCast(br.y - viewport_top);
            result.end_x = @min(br.x, last_column);
        }

        return result;
    }

    fn exportSnapshotFromSurface(
        surface: *Surface,
        result: *Snapshot,
    ) bool {
        result.* = .{};

        var cleared_garbage_selection = false;
        // Registered before the mutex lock/unlock defers so it runs after the unlock (defers run
        // last-in-first-out): `Surface.refresh` must not be called with the renderer mutex held,
        // matching how `ghostty_surface_clear_selection` refreshes only after releasing the lock.
        defer if (cleared_garbage_selection) surface.refresh();

        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const terminal_state = core_surface.renderer_state.terminal;
        const screen = terminal_state.screens.active;
        const previous_terminal_dirty = terminal_state.flags.dirty;
        const previous_screen_dirty = screen.dirty;

        var render_state: terminal.RenderState = .empty;
        defer render_state.deinit(global.alloc());

        render_state.update(global.alloc(), terminal_state) catch |err| {
            log.warn("error exporting terminal snapshot err={}", .{err});
            return false;
        };

        // Exporting a snapshot consumes terminal dirty state. Force a redraw
        // on the next render pass so snapshot export cannot hide output.
        terminal_state.flags.dirty = previous_terminal_dirty;
        terminal_state.flags.dirty.clear = true;
        screen.dirty = previous_screen_dirty;
        screen.dirty.selection = true;

        const columns: u16 = render_state.cols;
        const rows: u16 = render_state.rows;
        const cell_count: usize = @as(usize, columns) * @as(usize, rows);

        var copied_cells: []SnapshotCell = if (cell_count > 0)
            global.alloc().alloc(SnapshotCell, cell_count) catch |err| {
                log.warn("error allocating snapshot cells err={}", .{err});
                return false;
            }
        else
            &.{};
        errdefer if (cell_count > 0) global.alloc().free(copied_cells);

        const row_data = render_state.row_data.slice();
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_pins = row_data.items(.pin);
        const palette = &render_state.colors.palette;
        const default_fg = render_state.colors.foreground;
        const default_bg = render_state.colors.background;
        var cell_index: usize = 0;
        var links: std.ArrayListUnmanaged(SnapshotString) = .empty;

        for (0..rows) |row_index| {
            const cells_slice = row_cells[row_index].slice();
            const raws = cells_slice.items(.raw);
            const styles = cells_slice.items(.style);
            const graphemes = cells_slice.items(.grapheme);
            const row_flags = snapshotFlagsForRow(row_rows[row_index]);

            // A cell's OSC 8 target lives in the page its row pins, not in the render state's
            // copied cell data. Dereferencing the pin's node is only safe while the terminal
            // cannot change under us — the condition RenderState.linkCells documents — which holds
            // here because the renderer state mutex is held for the whole export.
            const link_pin = row_pins[row_index];
            const link_page = link_pin.node.page();

            for (0..columns) |column_index| {
                const raw = raws[column_index];
                const style: terminal.Style = if (raw.hasStyling()) styles[column_index] else .{};
                const foreground = style.fg(.{
                    .default = default_fg,
                    .palette = palette,
                });
                const background = style.bg(&raw, palette) orelse default_bg;

                // The render state's grapheme slice is only initialized for cells tagged
                // codepoint_grapheme; it is undefined otherwise, so the tag gates the read.
                // Over-cap clusters export as the base codepoint alone, matching the degradation
                // the other snapshot producers apply.
                var extras: []u32 = &.{};
                if (raw.hasGrapheme()) grapheme: {
                    const cps = graphemes[column_index];
                    if (cps.len == 0 or cps.len >= snapshot_max_grapheme_codepoints) break :grapheme;
                    extras = global.alloc().alloc(u32, cps.len) catch |err| {
                        log.warn("error allocating snapshot grapheme cluster err={}", .{err});
                        abortSnapshotExport(copied_cells, cell_index, &links);
                        return false;
                    };
                    for (cps, extras) |cp, *dst| dst.* = @intCast(cp);
                }

                var link_index: u32 = 0;
                if (raw.hyperlink) link: {
                    const rac = link_page.getRowAndCell(column_index, link_pin.y);
                    const id = link_page.lookupHyperlink(rac.cell) orelse break :link;
                    const entry = link_page.hyperlink_set.get(link_page.memory, id);
                    link_index = snapshotLinkIndex(
                        &links,
                        entry.uri.slice(link_page.memory),
                    ) catch |err| {
                        log.warn("error copying snapshot hyperlink err={}", .{err});
                        if (extras.len > 0) global.alloc().free(extras);
                        abortSnapshotExport(copied_cells, cell_index, &links);
                        return false;
                    };
                }

                copied_cells[cell_index] = .{
                    .codepoint = if (raw.hasText()) @intCast(raw.codepoint()) else 0,
                    .foreground_rgb = packRGB(foreground),
                    .background_rgb = packRGB(background),
                    .flags = snapshotFlagsForCell(raw, style) | row_flags,
                    .grapheme_extra_len = @intCast(extras.len),
                    .grapheme_extras = if (extras.len > 0) extras.ptr else null,
                    .link_index = link_index,
                };
                cell_index += 1;
            }
        }

        // Hand the accumulated link table to the snapshot as an exactly sized allocation, so its
        // deinit can free it without knowing the list's capacity.
        const copied_links: []SnapshotString = links.toOwnedSlice(global.alloc()) catch |err| {
            log.warn("error allocating snapshot links err={}", .{err});
            abortSnapshotExport(copied_cells, cell_index, &links);
            return false;
        };

        const cursor = render_state.cursor.viewport;
        // Captured once and reused both for the flag on the result below and to decide whether
        // pending_scroll_rects is trustworthy: an overflowed ring buffer means rects were dropped,
        // so a mirror cannot reconstruct movement from them and must not try.
        var scroll_carry_valid = !terminal_state.pendingRenderScrollRectsOverflowed();
        const pending_scroll_rects = if (scroll_carry_valid)
            terminal_state.pendingRenderScrollRects()
        else
            &[_]terminal.Terminal.RenderScrollRect{};
        var copied_scroll_rects: []SnapshotScrollRect = &.{};
        var scroll_rect_count = pending_scroll_rects.len;
        if (pending_scroll_rects.len > 0) {
            copied_scroll_rects = global.alloc().alloc(SnapshotScrollRect, pending_scroll_rects.len) catch |err| blk: {
                log.warn("error allocating snapshot scroll rects err={}", .{err});
                // Rects existed but could not be exported (and the pending buffer is cleared
                // below regardless), so this frame does not describe how content moved; a
                // mirror must cancel a drag carry rather than trust an empty rect list.
                scroll_carry_valid = false;
                scroll_rect_count = 0;
                break :blk &.{};
            };
            if (scroll_rect_count > 0) {
                for (pending_scroll_rects, 0..) |operation, index| {
                    copied_scroll_rects[index] = .{
                        .row_start = operation.row_start,
                        .row_count = operation.row_count,
                        .column_start = operation.column_start,
                        .column_count = operation.column_count,
                        .delta_rows = operation.delta_rows,
                        .delta_columns = operation.delta_columns,
                    };
                }
            }
        }

        // A garbaged selection (its tracked pins pruned out of scrollback, see
        // `selectionGarbageAfterPrune`) is only half handled by `projectSelectionForExport`
        // below returning absent: that stops this and every future frame from exporting a
        // highlight, but `screen.selection` itself stays installed, so `ghostty_surface_has_
        // selection` keeps reporting true and `ghostty_surface_read_selection` /
        // `Screen.selectionString` (which has no garbage guard) keep formatting whatever text now
        // sits at the pin's remapped (0, 0) location, unrelated to what the user actually
        // selected. Clear it here through `setRemoteSelection`, the same notification-firing,
        // clipboard-silent funnel `ghostty_surface_clear_selection` uses, so subscribers observe
        // the clear via `selection_changed`. The renderer mutex is already held for this whole
        // function (see the lock above), which is `setRemoteSelection`'s contract, so this does
        // not re-acquire it. The Linux headless host clears the equivalent way in its render pass
        // (GhosttyLinuxHeadlessSessionCore.swift) for the identical reason. The deferred
        // `surface.refresh()` registered before the mutex defers (above) schedules the owner
        // view's redraw once the lock is released, so the stale highlight does not linger on the
        // owner's rendered surface until an unrelated event happens to trigger a render.
        if (selectionGarbageAfterPrune(screen)) {
            core_surface.setRemoteSelection(null) catch |err| {
                log.warn("error clearing garbaged selection during snapshot export err={}", .{err});
            };
            cleared_garbage_selection = true;
        }

        const scrollbar = screen.pages.scrollbar();
        const exported_selection = projectSelectionForExport(
            screen,
            @intCast(scrollbar.offset),
            rows,
            columns,
        );

        result.* = .{
            .columns = columns,
            .rows = rows,
            .cursor_column = if (cursor) |vp| @intCast(vp.x) else 0,
            .cursor_row = if (cursor) |vp| @intCast(vp.y) else 0,
            .cursor_visible = render_state.cursor.visible and cursor != null,
            .default_foreground_rgb = packRGB(default_fg),
            .default_background_rgb = packRGB(default_bg),
            .cell_count = cell_count,
            .cells = if (cell_count > 0) copied_cells.ptr else null,
            .scroll_rect_count = scroll_rect_count,
            .scroll_rects = if (scroll_rect_count > 0) copied_scroll_rects.ptr else null,
            .scroll_carry_valid = scroll_carry_valid,
            .selection_flags = exported_selection.flags,
            .selection_start_x = exported_selection.start_x,
            .selection_start_y = exported_selection.start_y,
            .selection_end_x = exported_selection.end_x,
            .selection_end_y = exported_selection.end_y,
            .scrollbar_total = @intCast(scrollbar.total),
            .scrollbar_offset = @intCast(scrollbar.offset),
            .mouse_reporting_active = terminal_state.flags.mouse_event != .none,
            .mouse_shift_capture = switch (terminal_state.flags.mouse_shift_capture) {
                .null => 0,
                .false => 1,
                .true => 2,
            },
            .link_count = copied_links.len,
            .links = if (copied_links.len > 0) copied_links.ptr else null,
        };
        terminal_state.clearPendingRenderScrollRects();
        return true;
    }

    export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void {
        ptr.deinit();
    }

    export fn ghostty_surface_export_snapshot(
        surface: *Surface,
        result: *Snapshot,
    ) bool {
        return exportSnapshotFromSurface(surface, result);
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Rebind the renderer for a live surface to a replacement host view.
    export fn ghostty_surface_set_host(
        surface: *Surface,
        host: *const SurfaceHost,
    ) bool {
        surface.setHost(host.*) catch |err| {
            log.err("error rebinding surface host err={}", .{err});
            return false;
        };
        return true;
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    /// Returns the PID of the foreground process for the surface PTY.
    export fn ghostty_surface_foreground_pid(surface: *Surface) u64 {
        return surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
    }

    /// Reports whether the running application currently has bracketed paste
    /// (DECSET 2004) enabled — the same live mode `ghostty_surface_text`'s paste
    /// encoding is derived from, so an embedder can know ahead of a text write
    /// whether that write will reach the PTY framed.
    export fn ghostty_surface_bracketed_paste(surface: *Surface) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());
        return core_surface.io.terminal.modes.get(.bracketed_paste);
    }

    /// Returns the PTY name for the surface. The returned string must be
    /// freed by the caller via ghostty_string_free.
    export fn ghostty_surface_tty_name(surface: *Surface) String {
        const tty_name = surface.core_surface.getProcessInfo(.tty_name) orelse return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, tty_name) catch |err| {
            log.err("error allocating tty name err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    export fn ghostty_session_config_new() SessionConfig {
        return .{
            .surface = ghostty_surface_config_new(),
            .parked_host = .{},
        };
    }

    fn sessionNew(
        app: *App,
        config: *const SessionConfig,
        headless: bool,
    ) ?*Session {
        const session = global.alloc().create(Session) catch |err| {
            log.err("error allocating session err={}", .{err});
            return null;
        };
        session.init(app, config.*, headless) catch |err| {
            log.err("error initializing session err={}", .{err});
            global.alloc().destroy(session);
            return null;
        };
        return session;
    }

    export fn ghostty_session_new(
        app: *App,
        config: *const SessionConfig,
    ) ?*Session {
        return sessionNew(app, config, false);
    }

    /// A session with terminal state, a host-managed or exec IO backend and no
    /// renderer: no renderer thread, no graphics objects and no platform view.
    /// The platform and parked host fields of the config are ignored.
    export fn ghostty_session_new_headless(
        app: *App,
        config: *const SessionConfig,
    ) ?*Session {
        return sessionNew(app, config, true);
    }

    export fn ghostty_session_free(session: *Session) void {
        session.deinit();
        global.alloc().destroy(session);
    }

    export fn ghostty_session_surface(session: *Session) *Surface {
        return session.surface;
    }

    export fn ghostty_session_refresh(session: *Session) void {
        session.surface.refresh();
        session.notifyStateChange(session.notifyForegroundProcessIfChanged());
    }

    export fn ghostty_session_set_content_scale(session: *Session, x: f64, y: f64) void {
        session.surface.updateContentScale(x, y);
        session.notifyStateChange(session.notifySizeIfChanged());
    }

    export fn ghostty_session_set_focus(session: *Session, focused: bool) void {
        session.surface.focusCallback(focused);
    }

    export fn ghostty_session_set_occlusion(session: *Session, visible: bool) void {
        session.surface.occlusionCallback(visible);
    }

    export fn ghostty_session_set_size(session: *Session, w: u32, h: u32) void {
        session.surface.updateSize(w, h);
        var flags = session.notifySizeIfChanged();
        flags = flags.unionWith(.{ .screen = true });
        flags = flags.unionWith(session.notifyForegroundProcessIfChanged());
        session.notifyStateChange(flags);
    }

    export fn ghostty_session_set_grid_size(session: *Session, columns: u16, rows: u16) void {
        const current_size = ghostty_session_size(session);
        const cell_width = if (current_size.cell_width_px > 0) current_size.cell_width_px else 9;
        const cell_height = if (current_size.cell_height_px > 0) current_size.cell_height_px else 18;
        const width_px = @as(u32, columns) * @as(u32, cell_width);
        const height_px = @as(u32, rows) * @as(u32, cell_height);
        ghostty_session_set_size(session, width_px, height_px);
    }

    export fn ghostty_session_set_font_size(session: *Session, points: f32) void {
        if (points <= 0) return;
        const clamped_points = sanitizeFontSize(points) orelse return;

        var font_size = session.surface.core_surface.font_size;
        font_size.points = clamped_points;
        session.surface.core_surface.setFontSize(font_size) catch |err| {
            log.err("error setting session font size err={}", .{err});
            return;
        };
        session.surface.core_surface.font_size_adjusted = true;
        var flags = session.notifySizeIfChanged();
        flags = flags.unionWith(.{ .screen = true });
        session.notifyStateChange(flags);
    }

    export fn ghostty_session_size(session: *Session) SurfaceSize {
        return ghostty_surface_size(session.surface);
    }

    export fn ghostty_session_foreground_pid(session: *Session) u64 {
        return ghostty_surface_foreground_pid(session.surface);
    }

    export fn ghostty_session_bracketed_paste(session: *Session) bool {
        return ghostty_surface_bracketed_paste(session.surface);
    }

    export fn ghostty_session_state_revision(session: *Session) u64 {
        return session.stateRevision();
    }

    export fn ghostty_session_take_pending_state_flags(session: *Session) u32 {
        return session.takePendingStateFlags().bits();
    }

    export fn ghostty_session_tty_name(session: *Session) String {
        return ghostty_surface_tty_name(session.surface);
    }

    export fn ghostty_session_title(session: *Session) String {
        const title = session.surface.getTitle() orelse return .empty;
        const copy = session.app.core_app.alloc.dupeZ(u8, title) catch |err| {
            log.err("error allocating session title err={}", .{err});
            return .empty;
        };
        return .fromSlice(copy);
    }

    export fn ghostty_session_working_directory(session: *Session) String {
        if (session.surface.getWorkingDirectory()) |working_directory| {
            const copy = session.app.core_app.alloc.dupeZ(u8, working_directory) catch |err| {
                log.err("error allocating session working directory err={}", .{err});
                return .empty;
            };
            return .fromSlice(copy);
        }

        const cwd = session.surface.core_surface.pwd(session.app.core_app.alloc) catch |err| {
            log.err("error resolving session working directory err={}", .{err});
            return .empty;
        } orelse return .empty;
        defer session.app.core_app.alloc.free(cwd);

        const copy = session.app.core_app.alloc.dupeZ(u8, cwd) catch |err| {
            log.err("error allocating session working directory copy err={}", .{err});
            return .empty;
        };
        return .fromSlice(copy);
    }

    export fn ghostty_session_set_state_callback(
        session: *Session,
        callback: ?SessionStateCallback,
        userdata: ?*anyopaque,
    ) void {
        session.setStateCallback(callback, userdata);
    }

    export fn ghostty_session_set_data_callback(
        session: *Session,
        callback: ?SurfaceDataCallback,
        userdata: ?*anyopaque,
    ) void {
        ghostty_surface_set_data_callback(session.surface, callback, userdata);
    }

    export fn ghostty_session_process_output(
        session: *Session,
        ptr: ?[*]const u8,
        len: usize,
    ) void {
        const slice = ptr orelse return;
        session.surface.core_surface.io.processOutputBlocking(slice[0..len], true) catch |err| {
            log.err("error processing session output err={}", .{err});
            return;
        };
        session.notifyScreenMutation();
    }

    /// Wait until this session's IO thread has processed everything queued before this call.
    ///
    /// Host-managed sessions receive their input through that thread's mailbox and emit it to the host
    /// through the receive-buffer callback while handling it, with no completion signal of its own.
    /// This posts a no-op message through the same FIFO mailbox and returns once the thread has reached
    /// it, which proves the earlier input was handled — and therefore handed to the host — first.
    /// Nothing is parsed and no terminal state is touched, so it is safe to call at any point in the
    /// output stream.
    export fn ghostty_session_sync_io(session: *Session) void {
        session.surface.core_surface.io.syncBlocking() catch |err| {
            log.warn("error syncing session io err={}", .{err});
        };
    }

    export fn ghostty_session_send_input_raw(
        session: *Session,
        ptr: ?[*]const u8,
        len: usize,
    ) void {
        ghostty_surface_send_input_raw(session.surface, ptr, len);
        session.notifyStateChange(session.notifyForegroundProcessIfChanged());
    }

    export fn ghostty_session_export_snapshot(
        session: *Session,
        result: *Snapshot,
    ) bool {
        return exportSnapshotFromSurface(session.surface, result);
    }

    export fn ghostty_session_export_render_frame(
        session: *Session,
        result: *RenderFrame,
    ) bool {
        result.* = .{};
        if (!ghostty_session_export_snapshot(session, &result.snapshot)) return false;
        result.version = 1;
        result.session_revision = session.stateRevision();
        result.owner_epoch = 0;
        result.columns = result.snapshot.columns;
        result.rows = result.snapshot.rows;
        return true;
    }

    export fn ghostty_render_frame_free(frame: *RenderFrame) void {
        frame.deinit();
    }

    export fn ghostty_mirror_new(
        app: *App,
        host: *const SurfaceHost,
        config: *const SessionConfig,
    ) ?*Mirror {
        const mirror = global.alloc().create(Mirror) catch |err| {
            log.err("error allocating mirror err={}", .{err});
            return null;
        };
        mirror.init(app, host.*, config.*) catch |err| {
            log.err("error initializing mirror err={}", .{err});
            global.alloc().destroy(mirror);
            return null;
        };
        return mirror;
    }

    export fn ghostty_mirror_apply_render_frame(
        mirror: *Mirror,
        frame: *const RenderFrame,
    ) bool {
        if (frame.version != 1) return false;
        applySnapshotToSurface(mirror.session.surface, frame.snapshot) catch |err| {
            log.err("error applying mirror render frame err={}", .{err});
            return false;
        };
        mirror.session.surface.core_surface.draw() catch |err| {
            log.err("error redrawing mirror render frame err={}", .{err});
            return false;
        };
        return true;
    }

    /// Applies a mirror render frame without presenting it.
    ///
    /// Identical to `ghostty_mirror_apply_render_frame` except that it does not call
    /// `core_surface.draw()`. `applySnapshotToSurface` takes the renderer state mutex itself, so the
    /// surface's terminal state is fully updated by the time this returns; only the present is left to
    /// the caller.
    ///
    /// The draw the other entry point runs is `drawFrame(sync: true)`, which blocks the calling thread
    /// on the swap chain. It also presents whichever cells were last *built*, and building happens on
    /// the render thread only when woken by `ghostty_surface_refresh`, which the apply does not call --
    /// so that draw re-presents the previous frame rather than the one it just applied. An embedder
    /// that presents on its own cadence (refresh then draw, once per display interval) therefore pays
    /// a GPU wait per applied frame for a present it does not use. This entry point is for that
    /// embedder.
    export fn ghostty_mirror_apply_render_frame_no_draw(
        mirror: *Mirror,
        frame: *const RenderFrame,
    ) bool {
        if (frame.version != 1) return false;
        applySnapshotToSurface(mirror.session.surface, frame.snapshot) catch |err| {
            log.err("error applying mirror render frame err={}", .{err});
            return false;
        };
        return true;
    }

    export fn ghostty_mirror_surface(mirror: *Mirror) *Surface {
        return mirror.session.surface;
    }

    /// Mirrors `ghostty_mirror_selection_info_s` in include/ghostty.h. Rows are signed so an
    /// in-progress local drag whose anchor has scrolled above the mirror's viewport (see
    /// `MirrorDragCarry`) can be reported at its true, off-grid row instead of the row-0 position
    /// it is clamped to for painting.
    const MirrorSelectionInfo = extern struct {
        present: bool = false,
        rectangle: bool = false,
        start_x: u16 = 0,
        start_y: i32 = 0,
        end_x: u16 = 0,
        end_y: i32 = 0,
        anchor_clipped: bool = false,
    };

    /// Reports a mirror surface's current selection in viewport coordinates.
    ///
    /// A drag whose anchor is still on the grid is reported straight from the live, painted
    /// selection, ordered top-left first via the same `Selection.topLeft`/`bottomRight` logic the
    /// export path uses (exact, including rectangle-selection column mirroring). A virtual
    /// (off-grid) anchor has no pin to order that way, so it is reported as the raw anchor/drag-
    /// point pair instead, with `anchor_clipped` set: the anchor is always the topmost endpoint in
    /// that case (any on-grid row is greater than a negative one), so start/end ordering by row is
    /// still exact, but column ordering for a rectangle-mode drag is not re-normalized. This only
    /// under-orders the columns of a rectangle drag that is simultaneously scrolled off the top of
    /// the viewport and dragged to a smaller column than its anchor, a compound edge case accepted
    /// rather than adding a second, mostly-unused ordering path for it.
    export fn ghostty_mirror_selection_info(mirror: *Mirror, out: *MirrorSelectionInfo) void {
        out.* = .{};
        const surface = mirror.session.surface;
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen = core_surface.renderer_state.terminal.screens.active;

        if (surface.mirror_drag_carry) |carry| {
            if (carry.anchor_x < 0 or carry.anchor_y < 0) {
                const sel = screen.selection orelse return;
                const other = screen.pages.pointFromPin(.active, sel.end()) orelse return;
                out.* = .{
                    .present = true,
                    .rectangle = carry.rectangle,
                    .start_x = if (carry.anchor_x < 0) 0 else @intCast(carry.anchor_x),
                    .start_y = carry.anchor_y,
                    .end_x = other.coord().x,
                    .end_y = @intCast(other.coord().y),
                    .anchor_clipped = true,
                };
                return;
            }
        }

        const sel = screen.selection orelse return;
        const tl = screen.pages.pointFromPin(.active, sel.topLeft(screen)) orelse return;
        const br = screen.pages.pointFromPin(.active, sel.bottomRight(screen)) orelse return;
        out.* = .{
            .present = true,
            .rectangle = sel.rectangle,
            .start_x = tl.coord().x,
            .start_y = @intCast(tl.coord().y),
            .end_x = br.coord().x,
            .end_y = @intCast(br.coord().y),
            .anchor_clipped = false,
        };
    }

    export fn ghostty_mirror_set_host(
        mirror: *Mirror,
        host: *const SurfaceHost,
    ) bool {
        return ghostty_renderer_set_host(mirror.renderer, host);
    }

    export fn ghostty_mirror_free(mirror: *Mirror) void {
        mirror.deinit();
        global.alloc().destroy(mirror);
    }

    export fn ghostty_renderer_new(host: *const SurfaceHost) ?*Renderer {
        const renderer_handle = global.alloc().create(Renderer) catch |err| {
            log.err("error allocating renderer err={}", .{err});
            return null;
        };
        renderer_handle.* = .{
            .host = host.*,
            .attached_session = null,
        };
        return renderer_handle;
    }

    export fn ghostty_renderer_free(renderer_handle: *Renderer) void {
        renderer_handle.detachForFree() catch |err| {
            log.err(
                "error detaching renderer during free; renderer not freed err={}",
                .{err},
            );
            return;
        };
        global.alloc().destroy(renderer_handle);
    }

    export fn ghostty_renderer_attach(
        renderer_handle: *Renderer,
        session: *Session,
    ) bool {
        session.attachRenderer(renderer_handle) catch |err| {
            log.err("error attaching renderer err={}", .{err});
            return false;
        };
        return true;
    }

    export fn ghostty_renderer_detach(renderer_handle: *Renderer) bool {
        renderer_handle.detach() catch |err| {
            log.err("error detaching renderer err={}", .{err});
            return false;
        };
        return true;
    }

    export fn ghostty_renderer_surface(renderer_handle: *Renderer) ?*Surface {
        const session = renderer_handle.attached_session orelse return null;
        return session.surface;
    }

    export fn ghostty_renderer_set_host(
        renderer_handle: *Renderer,
        host: *const SurfaceHost,
    ) bool {
        renderer_handle.setHost(host.*) catch |err| {
            log.err("error rebinding renderer host err={}", .{err});
            return false;
        };
        return true;
    }

    export fn ghostty_renderer_session(renderer_handle: *Renderer) ?*Session {
        return renderer_handle.attached_session;
    }

    export fn ghostty_renderer_is_owner(renderer_handle: *const Renderer) bool {
        return renderer_handle.isOwner();
    }

    export fn ghostty_terminal_snapshot_free(snapshot: *Snapshot) void {
        snapshot.deinit();
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.enums.fromInt(apprt.ColorScheme, scheme_raw) orelse return;
        surface.colorSchemeCallback(scheme);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        const flags = surface.core_surface.keyEventIsBinding(
            core_event,
        ) orelse return false;
        if (c_flags) |ptr| ptr.* = flags.cval();
        return true;
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Register a callback for raw PTY output bytes before Ghostty parses them.
    export fn ghostty_surface_set_data_callback(
        surface: *Surface,
        callback: ?SurfaceDataCallback,
        userdata: ?*anyopaque,
    ) void {
        surface.data_callback = callback;
        surface.data_callback_userdata = userdata;
        surface.core_surface.io.setDataCallback(callback, userdata);
    }

    /// Send raw PTY bytes directly to the child process.
    export fn ghostty_surface_send_input_raw(
        surface: *Surface,
        ptr: ?[*]const u8,
        len: usize,
    ) void {
        if (ptr == null or len == 0) return;
        surface.core_surface.sendInputRaw(ptr.?[0..len]) catch |err| {
            log.warn("error sending raw input err={}", .{err});
        };
    }

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn ghostty_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.enums.fromInt(input.MousePressureStage, stage_raw) orelse return;
        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(
        surface: *Surface,
        x: *f64,
        y: *f64,
        width: *f64,
        height: *f64,
    ) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            surface.queueRendererMessageFromAnyThread(.{ .macos_display_id = display_id });
        }

        export fn ghostty_session_set_display_id(session: *Session, display_id: u32) void {
            ghostty_surface_set_display_id(session.surface, display_id);
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // A headless surface has no renderer to read the font grid from,
            // and nothing to QuickLook in.
            if (ptr.core_surface.headless) return null;

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockSharedUncancelable(global.io());
            defer grid.lock.unlockShared(global.io());

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            result: *Text,
        ) bool {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lockUncancelable(global.io());
            defer surface.renderer_state.mutex.unlock(global.io());

            // Get our word selection
            const sel = sel: {
                const screen: *terminal.Screen = surface.renderer_state.terminal.screens.active;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return false;
                };
                break :sel surface.io.terminal.screens.active.selectWord(
                    pin,
                    surface.config.selection_word_chars,
                ) orelse return false;
            };

            // Read the selection
            return readTextLocked(ptr, sel, result);
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                .fromId(command_buffer),
                .fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};

// Tests below cover the pure or `*terminal.Screen`-only pieces of the mirror selection model
// (export projection, drag-anchor carry math, frame-selection painting): `shiftVirtualDragAnchor`
// and `projectSelectionForExport` take no state beyond their arguments or a `Screen`, and
// `applyMirrorSelectionFromSnapshot`/`clampedDragPin` only need a `Screen`, so all four are
// testable directly. The orchestration around them in `applySnapshotToSurface` (in-progress-drag
// detection off `Surface.core_surface.mouse`, `Surface.mirror_drag_carry`, and the
// `Surface.refresh()` call) needs a full apprt `Surface`, and this codebase has no test harness
// that constructs one (there is no other `test` block anywhere in this file, or any Surface-level
// test fixture elsewhere in the tree) with a real `App`/window/renderer callback set. Building one
// from scratch was out of scope for this change, and the orchestration was not exercised against a
// running app either; only the pieces it wires together are covered here. That leaves the mode
// selection (drag-in-progress detection) and the carry-state bookkeeping in `applySnapshotToSurface`
// itself as the residual, untested surface of this change.

test "shiftVirtualDragAnchor shifts an on-grid anchor inside a containing rect" {
    const rects = [_]CAPI.SnapshotScrollRect{.{
        .row_start = 0,
        .row_count = 5,
        .column_start = 0,
        .column_count = 10,
        .delta_rows = -2,
        .delta_columns = 0,
    }};
    const result = CAPI.shiftVirtualDragAnchor(3, 4, 10, &rects);
    try std.testing.expectEqual(@as(i32, 3), result.x);
    try std.testing.expectEqual(@as(i32, 2), result.y);
}

test "shiftVirtualDragAnchor leaves an anchor outside every rect's region alone" {
    const rects = [_]CAPI.SnapshotScrollRect{.{
        .row_start = 5,
        .row_count = 2,
        .column_start = 0,
        .column_count = 10,
        .delta_rows = -2,
        .delta_columns = 0,
    }};
    const result = CAPI.shiftVirtualDragAnchor(3, 4, 10, &rects);
    try std.testing.expectEqual(@as(i32, 3), result.x);
    try std.testing.expectEqual(@as(i32, 4), result.y);
}

test "shiftVirtualDragAnchor pushes an already-virtual anchor further up only via full-width row-0 rects" {
    const columns: u16 = 10;

    const full_width = [_]CAPI.SnapshotScrollRect{.{
        .row_start = 0,
        .row_count = 3,
        .column_start = 0,
        .column_count = columns,
        .delta_rows = -1,
        .delta_columns = 0,
    }};
    const moved = CAPI.shiftVirtualDragAnchor(0, -2, columns, &full_width);
    try std.testing.expectEqual(@as(i32, -3), moved.y);

    const partial_width = [_]CAPI.SnapshotScrollRect{.{
        .row_start = 0,
        .row_count = 3,
        .column_start = 2,
        .column_count = 4,
        .delta_rows = -1,
        .delta_columns = 0,
    }};
    const unmoved_by_width = CAPI.shiftVirtualDragAnchor(0, -2, columns, &partial_width);
    try std.testing.expectEqual(@as(i32, -2), unmoved_by_width.y);

    const not_row_zero = [_]CAPI.SnapshotScrollRect{.{
        .row_start = 1,
        .row_count = 3,
        .column_start = 0,
        .column_count = columns,
        .delta_rows = -1,
        .delta_columns = 0,
    }};
    const unmoved_by_row = CAPI.shiftVirtualDragAnchor(0, -2, columns, &not_row_zero);
    try std.testing.expectEqual(@as(i32, -2), unmoved_by_row.y);
}

test "clampedDragPin clamps a virtual position to row 0 / column 0 and to the grid extent" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 10,
        .rows = 5,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();

    const negative_pin = CAPI.clampedDragPin(&s, -3, -7, 10, 5);
    const negative = s.pages.pointFromPin(.active, negative_pin).?.coord();
    try std.testing.expectEqual(@as(u16, 0), negative.x);
    try std.testing.expectEqual(@as(u32, 0), negative.y);

    const overflow_pin = CAPI.clampedDragPin(&s, 25, 25, 10, 5);
    const overflow = s.pages.pointFromPin(.active, overflow_pin).?.coord();
    try std.testing.expectEqual(@as(u16, 9), overflow.x);
    try std.testing.expectEqual(@as(u32, 4), overflow.y);
}

test "applyMirrorSelectionFromSnapshot paints an equivalent selection and clears when absent" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    try CAPI.applyMirrorSelectionFromSnapshot(&s, .{
        .selection_flags = CAPI.SelectionFlags.present,
        .selection_start_x = 1,
        .selection_start_y = 0,
        .selection_end_x = 3,
        .selection_end_y = 1,
    });

    {
        const sel = s.selection.?;
        const start = s.pages.pointFromPin(.active, sel.start()).?.coord();
        const end = s.pages.pointFromPin(.active, sel.end()).?.coord();
        try std.testing.expectEqual(@as(u16, 1), start.x);
        try std.testing.expectEqual(@as(u32, 0), start.y);
        try std.testing.expectEqual(@as(u16, 3), end.x);
        try std.testing.expectEqual(@as(u32, 1), end.y);
        try std.testing.expect(!sel.rectangle);
    }

    // A snapshot with no selection flags clears whatever was painted.
    try CAPI.applyMirrorSelectionFromSnapshot(&s, .{});
    try std.testing.expect(s.selection == null);
}

test "applyMirrorSelectionFromSnapshot paints a rectangle selection" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    try CAPI.applyMirrorSelectionFromSnapshot(&s, .{
        .selection_flags = CAPI.SelectionFlags.present | CAPI.SelectionFlags.rectangle,
        .selection_start_x = 1,
        .selection_start_y = 0,
        .selection_end_x = 3,
        .selection_end_y = 1,
    });

    try std.testing.expect(s.selection.?.rectangle);
}

test "projectSelectionForExport returns the selection unclipped when it fits the viewport" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 1 } }).?,
        false,
    ));

    const bar = s.pages.scrollbar();
    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 3, 5);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.present != 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_above == 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_below == 0);
    try std.testing.expectEqual(@as(u16, 1), result.start_x);
    try std.testing.expectEqual(@as(u16, 0), result.start_y);
    try std.testing.expectEqual(@as(u16, 3), result.end_x);
    try std.testing.expectEqual(@as(u16, 1), result.end_y);
}

test "projectSelectionForExport clips a selection extending above the viewport" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCC\n4DDDD\n5EEEE\n6FFFF");

    // Screen space: 6 rows total (0..5), a 3-row viewport defaults to the bottom (3..5).
    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
        false,
    ));

    const bar = s.pages.scrollbar();
    try std.testing.expectEqual(@as(usize, 3), bar.offset);

    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 3, 5);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.present != 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_above != 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_below == 0);
    try std.testing.expectEqual(@as(u16, 0), result.start_x);
    try std.testing.expectEqual(@as(u16, 0), result.start_y);
    try std.testing.expectEqual(@as(u16, 3), result.end_x);
    try std.testing.expectEqual(@as(u16, 1), result.end_y);
}

test "projectSelectionForExport clips a selection extending below the viewport" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCC\n4DDDD\n5EEEE\n6FFFF");
    s.scroll(.top); // Viewport moves to the top 3 rows (0..2).

    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
        false,
    ));

    const bar = s.pages.scrollbar();
    try std.testing.expectEqual(@as(usize, 0), bar.offset);

    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 3, 5);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.present != 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_above == 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_below != 0);
    try std.testing.expectEqual(@as(u16, 1), result.start_x);
    try std.testing.expectEqual(@as(u16, 1), result.start_y);
    try std.testing.expectEqual(@as(u16, 4), result.end_x);
    try std.testing.expectEqual(@as(u16, 2), result.end_y);
}

test "projectSelectionForExport keeps rectangle columns as-is and clips only rows" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCC\n4DDDD\n5EEEE\n6FFFF");

    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
        true, // rectangle
    ));

    const bar = s.pages.scrollbar();
    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 3, 5);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.rectangle != 0);
    try std.testing.expect(result.flags & CAPI.SelectionFlags.extends_above != 0);
    // A clipped rectangle selection keeps its own columns instead of snapping to 0/last_column.
    try std.testing.expectEqual(@as(u16, 1), result.start_x);
    try std.testing.expectEqual(@as(u16, 0), result.start_y);
    try std.testing.expectEqual(@as(u16, 3), result.end_x);
    try std.testing.expectEqual(@as(u16, 1), result.end_y);
}

test "projectSelectionForExport returns absent when the selection does not intersect the viewport" {
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCC\n4DDDD\n5EEEE\n6FFFF");
    s.scroll(.top); // Viewport is rows 0..2; select rows 4..5, entirely below it.

    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 4 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 4, .y = 5 } }).?,
        false,
    ));

    const bar = s.pages.scrollbar();
    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 3, 5);
    try std.testing.expectEqual(@as(u8, 0), result.flags);
}

test "projectSelectionForExport returns absent for a selection pruned out of scrollback" {
    // A small max_size forces PageList.Limits.enforce to evict whole historical pages once the
    // budget is exceeded, marking any tracked pin on an evicted page garbage (PageList.zig
    // Limits.enforce). This mirrors "PageList grow prune scrollback" in PageList.zig's own test
    // suite, adapted to select through the page that gets evicted.
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 65536,
    });
    defer s.deinit();

    // Fill the first page to capacity so the next grow() allocates a second page.
    const page1_node = s.pages.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try std.testing.expect(try s.pages.grow() == null);
    }

    // Select the top-left of the first (about to become historical) page.
    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{} }).?,
        s.pages.pin(.{ .screen = .{} }).?,
        false,
    ));
    try std.testing.expect(!s.selection.?.start().garbage);

    // Keep growing (each grow can allocate a new page and enforce the byte budget) until the
    // first page has been evicted and our selection's pins were marked garbage. Bounded so a
    // regression that stops pruning from happening fails the test instead of hanging it.
    var grew: usize = 0;
    while (!s.selection.?.start().garbage and grew < 10_000) : (grew += 1) {
        _ = try s.pages.grow();
    }
    try std.testing.expect(s.selection.?.start().garbage);

    const bar = s.pages.scrollbar();
    const result = CAPI.projectSelectionForExport(&s, @intCast(bar.offset), 24, 80);
    try std.testing.expectEqual(@as(u8, 0), result.flags);
}

test "selectionGarbageAfterPrune detects a selection pruned out of scrollback" {
    // Same eviction recipe as "projectSelectionForExport returns absent for a selection pruned
    // out of scrollback" above: force PageList.Limits.enforce to evict the page the selection is
    // pinned to, which marks its tracked pins garbage and remaps them to (0, 0) rather than
    // leaving them dangling.
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 65536,
    });
    defer s.deinit();

    const page1_node = s.pages.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try std.testing.expect(try s.pages.grow() == null);
    }

    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{} }).?,
        s.pages.pin(.{ .screen = .{} }).?,
        false,
    ));
    try std.testing.expect(!CAPI.selectionGarbageAfterPrune(&s));

    var grew: usize = 0;
    while (!s.selection.?.start().garbage and grew < 10_000) : (grew += 1) {
        _ = try s.pages.grow();
    }
    try std.testing.expect(CAPI.selectionGarbageAfterPrune(&s));

    // This is the detection half of `exportSnapshotFromSurface`'s fix: once
    // `selectionGarbageAfterPrune` is true, it clears the selection through
    // `Surface.setRemoteSelection(null)`, which (via `Surface.setSelection`) reduces to
    // `screen.select(null)` plus the `selection_changed` notification. `setRemoteSelection`
    // needs a full apprt `Surface` to call (see the file-level test doc comment above for why
    // that is not built here), so only its effect on the screen is asserted directly: once the
    // garbaged selection is cleared, detection reports it gone, matching what
    // `ghostty_surface_has_selection` should report afterward.
    try s.select(null);
    try std.testing.expect(!CAPI.selectionGarbageAfterPrune(&s));
    try std.testing.expect(s.selection == null);
}

test "absolute screen-space selection tracks its text across new output (ghostty_surface_set_selection_absolute's recipe)" {
    // Exercises the clamp-then-pin-then-select recipe ghostty_surface_set_selection_absolute
    // uses, directly against a Screen: the C function itself needs a full apprt Surface (see the
    // file-level test doc comment above for why that is not built here).
    var s = try terminal.Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 4096,
    });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    const bar_before = s.pages.scrollbar();
    const max_row: u32 = @intCast(bar_before.total - 1);
    const max_col: terminal.size.CellCountInt = s.pages.cols - 1;
    const start_pin = s.pages.pin(.{ .screen = .{
        .x = @min(@as(u16, 1), max_col),
        .y = @min(@as(u32, 1), max_row),
    } }).?;
    const end_pin = s.pages.pin(.{ .screen = .{
        .x = @min(@as(u16, 3), max_col),
        .y = @min(@as(u32, 1), max_row),
    } }).?;
    try s.select(terminal.Selection.init(start_pin, end_pin, false));

    // More output pushes the selected row ("2EFGH") into scrollback and out of the viewport.
    try s.testWriteString("\n4MNOP\n5QRST");

    {
        const sel = s.selection.?;
        const start = s.pages.pointFromPin(.screen, sel.start()).?.coord();
        const end = s.pages.pointFromPin(.screen, sel.end()).?.coord();
        try std.testing.expectEqual(@as(u16, 1), start.x);
        try std.testing.expectEqual(@as(u32, 1), start.y);
        try std.testing.expectEqual(@as(u16, 3), end.x);
        try std.testing.expectEqual(@as(u32, 1), end.y);
    }

    // The selection is still anchored to "2EFGH" (unmoved in screen space) even though it is now
    // above the viewport: the export projection reflects that as extends_above.
    const bar_after = s.pages.scrollbar();
    const projected = CAPI.projectSelectionForExport(&s, @intCast(bar_after.offset), 3, 5);
    try std.testing.expect(projected.flags & CAPI.SelectionFlags.present != 0);
    try std.testing.expect(projected.flags & CAPI.SelectionFlags.extends_above != 0);
}
