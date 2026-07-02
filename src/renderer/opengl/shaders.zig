const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const math = @import("../../math.zig");

/// True when targeting Android, in which case we render with OpenGL ES 3.1
/// and must transform the desktop GLSL sources into GLSL ES at load time.
const gles = @import("builtin").target.abi.isAndroid();

const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.opengl);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_color.f.glsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_bg.f.glsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("../shaders/glsl/cell_text.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/cell_text.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("../shaders/glsl/image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("../shaders/glsl/bg_image.v.glsl"),
            .fragment_fn = loadShaderCode("../shaders/glsl/bg_image.f.glsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline();
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            post_shaders,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    // test {
    //     // Minimizing the size of this struct is important,
    //     // so we test it in order to be aware of any changes.
    //     try std.testing.expectEqual(32, @sizeOf(CellText));
    // }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Initialize our custom shader pipelines. The shaders argument is a
/// set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    shaders: []const [:0]const u8,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(source);
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(data: [:0]const u8) !Pipeline {
    return try Pipeline.init(null, .{
        .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        .fragment_fn = data,
    });
}

/// Load shader code from the target path, processing `#include` directives.
///
/// Comptime only for now, this code is really sloppy and makes a bunch of
/// assumptions about things being well formed and file names not containing
/// quote marks. If we ever want to process `#include`s for custom shaders
/// then we need to write something better than this for it.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    const src = comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
    // Desktop OpenGL uses the sources verbatim. Android (GLES) needs the
    // sources rewritten to GLSL ES 3.10, which we do at comptime so the
    // desktop path is byte-for-byte unchanged.
    if (!gles) return src;
    return comptime glesifyShader(src);
}

/// Rewrite a desktop GLSL shader source (core 3.30/4.30) into GLSL ES 3.10
/// so it compiles on an OpenGL ES 3.1 context. This is a purely textual
/// transform performed at comptime; it is only reached on Android builds.
///
/// The transforms:
///  - Replace the `#version ... core` directive with `#version 310 es`
///    plus default precision qualifiers (required in ES).
///  - `sampler2DRect` -> `sampler2D` (rectangle textures don't exist in ES).
///  - Atlas fetches `texture(atlas_*, coord)` -> `texelFetch(atlas_*,
///    ivec2(coord), 0)` since the atlas is sampled in texel space.
///  - `layout(origin_upper_left) in vec4 gl_FragCoord;` is invalid in ES and
///    ES has no equivalent: gl_FragCoord is always bottom-left origin. Shaders
///    that declared it index cells/textures top-down from gl_FragCoord, so
///    every `gl_FragCoord.xy` use is rewritten to flip Y via `screen_size`
///    (from the Globals UBO; the render target is always screen_size-sized).
fn glesifyShader(comptime src: [:0]const u8) [:0]const u8 {
    comptime {
        // The std.mem.replace passes below are branch-heavy over multi-KB
        // sources, and this runs for every pipeline in one comptime unit, so
        // the quota needs generous headroom.
        @setEvalBranchQuota(100_000_000);

        // NOTE: No `usampler2D`/`usampler2DRect` is present in any of these
        //       shaders (verified), so we don't emit a usampler precision.
        // GL_EXT_shader_io_blocks brings in/out interface blocks (used by the
        // cell_text pipeline) to GLSL ES 3.10; they're otherwise core only in
        // ES 3.20. #extension must appear after #version and before any code.
        const es_header =
            \\#version 310 es
            \\#extension GL_EXT_shader_io_blocks : require
            \\precision highp float;
            \\precision highp int;
            \\precision highp sampler2D;
            \\
        ;

        var out: []const u8 = src;
        out = replaceAllComptime(out, "#version 430 core\n", es_header);
        out = replaceAllComptime(out, "#version 330 core\n", es_header);
        out = replaceAllComptime(out, "sampler2DRect", "sampler2D");
        out = replaceAtlasFetch(out, "atlas_grayscale");
        out = replaceAtlasFetch(out, "atlas_color");
        const origin_decl = "layout(origin_upper_left) in vec4 gl_FragCoord;";
        if (std.mem.indexOf(u8, out, origin_decl) != null) {
            out = replaceAllComptime(
                out,
                origin_decl,
                "// GLES: no origin_upper_left; gl_FragCoord.xy uses are Y-flipped below",
            );
            // The flip only rewrites `.xy` swizzles; any other access to
            // gl_FragCoord would silently keep the wrong origin.
            if (std.mem.count(u8, out, "gl_FragCoord") !=
                std.mem.count(u8, out, "gl_FragCoord.xy"))
                @compileError("origin_upper_left shader accesses gl_FragCoord other than via .xy; extend the GLES flip");
            out = replaceAllComptime(
                out,
                "gl_FragCoord.xy",
                "vec2(gl_FragCoord.x, screen_size.y - gl_FragCoord.y)",
            );
        }

        // Re-materialize as a sentinel-terminated slice for the driver.
        return std.fmt.comptimePrint("{s}", .{out});
    }
}

/// Comptime `std.mem.replace` that returns a fresh slice.
fn replaceAllComptime(
    comptime input: []const u8,
    comptime needle: []const u8,
    comptime replacement: []const u8,
) []const u8 {
    comptime {
        const size = std.mem.replacementSize(u8, input, needle, replacement);
        var buf: [size]u8 = undefined;
        _ = std.mem.replace(u8, input, needle, replacement, &buf);
        const final = buf;
        return &final;
    }
}

/// Rewrite every `texture(<sampler>, <expr>)` call for the given atlas sampler
/// into `texelFetch(<sampler>, ivec2(<expr>), 0)`. Matches the closing paren
/// of the call so arbitrary (even nested) expressions are handled.
fn replaceAtlasFetch(
    comptime input: []const u8,
    comptime sampler: []const u8,
) []const u8 {
    comptime {
        const prefix = "texture(" ++ sampler ++ ",";
        const idx = std.mem.indexOf(u8, input, prefix) orelse return input;

        const expr_start = idx + prefix.len;
        var i: usize = expr_start;
        var depth: usize = 1;
        while (i < input.len) : (i += 1) {
            switch (input[i]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }

        const expr = input[expr_start..i];
        const rebuilt = input[0..idx] ++
            "texelFetch(" ++ sampler ++ ", ivec2(" ++ expr ++ "), 0)" ++
            input[i + 1 ..];

        // Handle any further occurrences of the same sampler.
        return replaceAtlasFetch(rebuilt, sampler);
    }
}

/// Used by loadShaderCode
fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}
