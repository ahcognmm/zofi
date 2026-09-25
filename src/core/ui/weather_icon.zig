//! Small hand-drawn weather pictograms -- z2d has no image pattern to
//! fill a shape with, and pulling in bitmap icon assets for half a dozen
//! glyphs isn't worth a new dependency (see `image.zig` for the same
//! reasoning applied to real freedesktop icons).
const std = @import("std");
const z2d = @import("z2d");
const weather_mod = @import("../weather.zig");

pub const WeatherIcon = struct {
    kind: weather_mod.Icon,
    accent: z2d.Pixel,
    dim: z2d.Pixel,
    faint: z2d.Pixel,

    pub fn draw(self: WeatherIcon, ctx: *z2d.Context, x: f64, y: f64, size: f64, scale: f64) !void {
        const cx = x + size / 2;
        const cy = y + size / 2;

        switch (self.kind) {
            .sun => {
                ctx.setSourceToPixel(self.accent);
                const r = size * 0.28;
                try ctx.arc(cx, cy, r, 0, std.math.pi * 2);
                try ctx.closePath();
                try ctx.fill();
                ctx.resetPath();
                ctx.setLineWidth(@max(1.0, 1.2 * scale));
                var ray: usize = 0;
                while (ray < 8) : (ray += 1) {
                    const a = @as(f64, @floatFromInt(ray)) * (std.math.pi / 4.0);
                    const x0 = cx + @cos(a) * r * 1.4;
                    const y0 = cy + @sin(a) * r * 1.4;
                    const x1 = cx + @cos(a) * r * 1.9;
                    const y1 = cy + @sin(a) * r * 1.9;
                    try ctx.moveTo(x0, y0);
                    try ctx.lineTo(x1, y1);
                    try ctx.stroke();
                    ctx.resetPath();
                }
            },
            .cloud, .part_cloud, .fog, .rain, .snow, .thunder => {
                if (self.kind == .part_cloud) {
                    ctx.setSourceToPixel(self.accent);
                    const r = size * 0.22;
                    try ctx.arc(cx - size * 0.18, cy - size * 0.18, r, 0, std.math.pi * 2);
                    try ctx.closePath();
                    try ctx.fill();
                    ctx.resetPath();
                }
                ctx.setSourceToPixel(self.dim);
                const body_y = cy + size * 0.08;
                try ctx.arc(cx - size * 0.16, body_y, size * 0.2, std.math.pi * 0.5, std.math.pi * 1.75);
                try ctx.arc(cx + size * 0.08, body_y - size * 0.1, size * 0.24, std.math.pi * 1.15, std.math.pi * 2.15);
                try ctx.lineTo(cx + size * 0.34, body_y + size * 0.22);
                try ctx.lineTo(cx - size * 0.16, body_y + size * 0.22);
                try ctx.closePath();
                try ctx.fill();
                ctx.resetPath();

                switch (self.kind) {
                    .rain => {
                        ctx.setSourceToPixel(self.faint);
                        ctx.setLineWidth(@max(1.0, 1.2 * scale));
                        var d: usize = 0;
                        while (d < 3) : (d += 1) {
                            const dx = cx - size * 0.12 + @as(f64, @floatFromInt(d)) * size * 0.16;
                            try ctx.moveTo(dx, body_y + size * 0.3);
                            try ctx.lineTo(dx - size * 0.05, body_y + size * 0.46);
                            try ctx.stroke();
                            ctx.resetPath();
                        }
                    },
                    .snow => {
                        ctx.setSourceToPixel(self.faint);
                        var d: usize = 0;
                        while (d < 3) : (d += 1) {
                            const dx = cx - size * 0.12 + @as(f64, @floatFromInt(d)) * size * 0.16;
                            const dy = body_y + size * 0.38;
                            try ctx.arc(dx, dy, @max(0.8 * scale, size * 0.03), 0, std.math.pi * 2);
                            try ctx.closePath();
                            try ctx.fill();
                            ctx.resetPath();
                        }
                    },
                    .fog => {
                        ctx.setSourceToPixel(self.faint);
                        ctx.setLineWidth(@max(1.0, 1.2 * scale));
                        var d: usize = 0;
                        while (d < 2) : (d += 1) {
                            const dy = body_y + size * 0.3 + @as(f64, @floatFromInt(d)) * size * 0.14;
                            try ctx.moveTo(cx - size * 0.22, dy);
                            try ctx.lineTo(cx + size * 0.22, dy);
                            try ctx.stroke();
                            ctx.resetPath();
                        }
                    },
                    .thunder => {
                        ctx.setSourceToPixel(self.accent);
                        try ctx.moveTo(cx + size * 0.02, body_y + size * 0.24);
                        try ctx.lineTo(cx - size * 0.1, body_y + size * 0.46);
                        try ctx.lineTo(cx + size * 0.02, body_y + size * 0.46);
                        try ctx.lineTo(cx - size * 0.08, body_y + size * 0.68);
                        try ctx.lineTo(cx + size * 0.16, body_y + size * 0.4);
                        try ctx.lineTo(cx + size * 0.04, body_y + size * 0.4);
                        try ctx.closePath();
                        try ctx.fill();
                        ctx.resetPath();
                    },
                    else => {},
                }
            },
        }
    }
};

test "draw executes for every icon kind without error" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 40, 40);
    defer surface.deinit(std.testing.allocator);
    var ctx = z2d.Context.init(threaded.io(), std.testing.allocator, &surface);
    defer ctx.deinit();

    const colors: struct { accent: z2d.Pixel, dim: z2d.Pixel, faint: z2d.Pixel } = .{
        .accent = .{ .argb = .{ .a = 255, .r = 1, .g = 1, .b = 1 } },
        .dim = .{ .argb = .{ .a = 255, .r = 2, .g = 2, .b = 2 } },
        .faint = .{ .argb = .{ .a = 255, .r = 3, .g = 3, .b = 3 } },
    };
    inline for (@typeInfo(weather_mod.Icon).@"enum".fields) |f| {
        const icon: WeatherIcon = .{ .kind = @enumFromInt(f.value), .accent = colors.accent, .dim = colors.dim, .faint = colors.faint };
        try icon.draw(&ctx, 0, 0, 20, 1.0);
    }
}
