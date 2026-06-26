const std = @import("std");
const rl = @import("raylib");

const W = 600;
const H = 800;

const PIPE_INTERVAL: f32 = 200.0;
const BASE_SPEED: f32 = 2.5;
const BIRD_FRAMES = 3;
const ANIM_RATE = 8; // frames por troca de sprite

const Bird = struct {
    x: f32 = 60.0,
    y: f32 = H / 2.0 - 20.0,
    vy: f32 = 0.0,
    angle: f32 = 0.0,
    frame: usize = 0,
    frame_timer: usize = 0,
};

const Pipe = struct {
    x: f32,
    gap_y: f32,
    scored: bool = false,
};

const GameState = enum { menu, waiting, playing, dead };

const Theme = enum {
    day,
    night,
};

const Difficulty = enum {
    easy,
    medium,
    hard,
};

const MenuItem = enum { start, difficulty, theme, volume, exit };

const Physics = struct {
    gravity: f32,
    flap_force: f32,
    pipe_speed: f32,
    pipe_gap: f32,
};

fn physics(diff: Difficulty) Physics {
    return switch (diff) {
        .easy => .{
            .gravity = 0.34,
            .flap_force = -7.5,
            .pipe_speed = 2.2,
            .pipe_gap = 145,
        },
        .medium => .{
            .gravity = 0.40,
            .flap_force = -8.0,
            .pipe_speed = 2.5,
            .pipe_gap = 120,
        },
        .hard => .{
            .gravity = 0.48,
            .flap_force = -8.5,
            .pipe_speed = 3.2,
            .pipe_gap = 100,
        },
    };
}

fn loadSpriteAsset(cwd: []const u8, file: []const u8) !rl.Texture2D {
    const zig_out = std.fs.path.dirname(cwd).?;
    const project = std.fs.path.dirname(zig_out).?;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &buf,
        "{s}/src/assets/sprites/{s}",
        .{ project, file },
    );

    std.debug.print("Loading: {s}\n", .{path});

    return rl.loadTexture(path);
}

fn loadAudioAsset(cwd: []const u8, file: []const u8) !rl.Sound {
    const zig_out = std.fs.path.dirname(cwd).?;
    const project = std.fs.path.dirname(zig_out).?;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &buf,
        "{s}/src/assets/audio/{s}",
        .{ project, file },
    );

    return rl.loadSound(path);
}

fn loadMusicAsset(cwd: []const u8, file: []const u8) !rl.Music {
    const zig_out = std.fs.path.dirname(cwd).?;
    const project = std.fs.path.dirname(zig_out).?;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &buf,
        "{s}/src/assets/audio/{s}",
        .{ project, file },
    );

    return rl.loadMusicStream(path);
}

fn setVolume(volume: f32, sounds: []const rl.Sound) void {
    for (sounds) |s| {
        rl.setSoundVolume(s, volume);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    rl.initWindow(W, H, "Flappy Bird");
    defer rl.closeWindow();

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    rl.setTargetFPS(60);

    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(cwd);

    std.debug.print("PWD: {s}\n", .{cwd});

    const tex_bg_day = try loadSpriteAsset(cwd, "background-day.png");
    const tex_bg_night = try loadSpriteAsset(cwd, "background-night.png");

    const tex_base = try loadSpriteAsset(cwd, "base.png");
    const tex_pipe = try loadSpriteAsset(cwd, "pipe-green.png");
    const tex_over = try loadSpriteAsset(cwd, "gameover.png");
    const tex_msg = try loadSpriteAsset(cwd, "message.png");

    const bird_texs = [BIRD_FRAMES]rl.Texture2D{
        try loadSpriteAsset(cwd, "yellowbird-upflap.png"),
        try loadSpriteAsset(cwd, "yellowbird-midflap.png"),
        try loadSpriteAsset(cwd, "yellowbird-downflap.png"),
    };
    defer for (bird_texs) |t| rl.unloadTexture(t);

    // dígitos 0-9
    var digit_texs: [10]rl.Texture2D = undefined;

    for (0..10) |i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buf, "{d}.png", .{i});

        digit_texs[i] = try loadSpriteAsset(cwd, name);
    }
    defer for (digit_texs) |t| rl.unloadTexture(t);

    const music_menu = try loadMusicAsset(cwd, "menu.ogg");

    const snd_die = try loadAudioAsset(cwd, "die.ogg");
    const snd_hit = try loadAudioAsset(cwd, "hit.ogg");
    const snd_point = try loadAudioAsset(cwd, "point.ogg");
    const snd_swoosh = try loadAudioAsset(cwd, "swoosh.ogg");
    const snd_wing = try loadAudioAsset(cwd, "wing.ogg");

    defer rl.unloadMusicStream(music_menu);

    defer rl.unloadSound(snd_die);
    defer rl.unloadSound(snd_hit);
    defer rl.unloadSound(snd_point);
    defer rl.unloadSound(snd_swoosh);
    defer rl.unloadSound(snd_wing);

    // --- estado ---
    var pipes: std.ArrayList(Pipe) = .empty;
    defer pipes.deinit(allocator);

    var bird = Bird{};
    var state = GameState.menu;
    var score: u32 = 0;
    var next_pipe_x: f32 = W + 80.0;
    var base_offset: f32 = 0.0;
    var difficulty = Difficulty.easy;
    var volume: f32 = 1.0;
    var theme = Theme.night;

    var menu_item = MenuItem.start;

    setVolume(volume, &.{
        snd_die,
        snd_hit,
        snd_point,
        snd_swoosh,
        snd_wing,
    });

    rl.setMusicVolume(music_menu, volume);
    rl.playMusicStream(music_menu);

    const BASE_H: i32 = tex_base.height;
    const FLOOR_Y: f32 = H - @as(f32, @floatFromInt(BASE_H));

    while (!rl.windowShouldClose()) {
        rl.updateMusicStream(music_menu);

        const cfg = physics(difficulty);

        const flap = rl.isKeyPressed(.space) or rl.isMouseButtonPressed(.left);

        const up = rl.isKeyPressed(.up);
        const down = rl.isKeyPressed(.down);
        const left = rl.isKeyPressed(.left);
        const right = rl.isKeyPressed(.right);
        const enter = rl.isKeyPressed(.enter);

        switch (state) {
            .menu => {
                bird.y = H / 2.0 - 20.0 + @sin(@as(f32, @floatCast(rl.getTime() * 2.0))) * 8.0;

                animBird(&bird);

                if (up) {
                    menu_item = switch (menu_item) {
                        .start => .start,
                        .difficulty => .start,
                        .theme => .difficulty,
                        .volume => .theme,
                        .exit => .volume,
                    };
                }

                if (down) {
                    menu_item = switch (menu_item) {
                        .start => .difficulty,
                        .difficulty => .theme,
                        .theme => .volume,
                        .volume => .exit,
                        .exit => .exit,
                    };
                }

                if (left) {
                    switch (menu_item) {
                        .difficulty => {
                            difficulty = switch (difficulty) {
                                .easy => if (right) .medium else .easy,
                                .medium => if (right) .hard else .easy,
                                .hard => if (left) .medium else .hard,
                            };
                        },

                        .theme => theme = if (theme == .day) .night else .day,

                        .volume => {
                            volume = @max(0.0, volume - 0.25);

                            setVolume(volume, &.{
                                snd_die,
                                snd_hit,
                                snd_point,
                                snd_swoosh,
                                snd_wing,
                            });
                            rl.setMusicVolume(music_menu, volume);
                        },

                        else => {},
                    }
                }

                if (right) {
                    switch (menu_item) {
                        .difficulty => {
                            difficulty = switch (difficulty) {
                                .easy => if (right) .medium else .easy,
                                .medium => if (right) .hard else .easy,
                                .hard => if (left) .medium else .hard,
                            };
                        },

                        .theme => theme = if (theme == .day) .night else .day,

                        .volume => {
                            volume = @min(1.0, volume + 0.25);

                            setVolume(volume, &.{
                                snd_die,
                                snd_hit,
                                snd_point,
                                snd_swoosh,
                                snd_wing,
                            });

                            rl.setMusicVolume(music_menu, volume);
                        },

                        else => {},
                    }
                }

                if (enter) {
                    switch (menu_item) {
                        .start => {
                            var seed: u32 = undefined;

                            const bytes = std.os.linux.getrandom(
                                std.mem.asBytes(&seed).ptr,
                                @sizeOf(u32),
                                0,
                            );

                            if (bytes != @sizeOf(u32)) {
                                return error.GetRandomFailed;
                            }

                            rl.setRandomSeed(seed);

                            bird = Bird{};
                            pipes.clearRetainingCapacity();
                            score = 0;
                            next_pipe_x = W + 80.0;

                            rl.playSound(snd_swoosh);
                            state = .waiting;
                        },

                        .exit => {
                            break;
                        },

                        else => {},
                    }
                }
            },
            .waiting => {
                bird.y = H / 2.0 - 20.0 +
                    @sin(@as(f32, @floatCast(rl.getTime() * 2.0))) * 8.0;

                animBird(&bird);

                if (flap) {
                    rl.playSound(snd_wing);
                    bird.vy = cfg.flap_force;
                    state = .playing;
                }
            },
            .playing => {
                if (flap) {
                    bird.vy = cfg.flap_force;
                    rl.playSound(snd_wing);
                }

                bird.vy += cfg.gravity;
                bird.y += bird.vy;
                bird.angle = std.math.clamp(bird.vy * 4.0, -25.0, 90.0);
                animBird(&bird);

                // chão e teto
                if (bird.y + 10.0 >= FLOOR_Y or bird.y - 10.0 <= 0.0) {
                    if (state != .dead) {
                        rl.playSound(snd_hit);
                        rl.playSound(snd_die);
                        state = .dead;
                    }
                }

                // gera canos
                next_pipe_x -= cfg.pipe_speed;
                if (next_pipe_x <= W) {
                    const gap_y: f32 = @as(f32, @floatFromInt(
                        rl.getRandomValue(
                            @intFromFloat(cfg.pipe_gap / 2.0 + 40.0),
                            @intFromFloat(FLOOR_Y - cfg.pipe_gap / 2.0 - 40.0),
                        ),
                    ));
                    try pipes.append(allocator, .{ .x = W + 10.0, .gap_y = gap_y });
                    next_pipe_x = W + 10.0 + PIPE_INTERVAL;
                }

                // move canos
                var i: usize = 0;
                while (i < pipes.items.len) {
                    const p = &pipes.items[i];
                    p.x -= cfg.pipe_speed;

                    // pontua
                    if (!p.scored and p.x + @as(f32, @floatFromInt(tex_pipe.width)) < bird.x) {
                        p.scored = true;
                        score += 1;
                        rl.playSound(snd_point);
                    }

                    // colisão
                    const pw: f32 = @floatFromInt(tex_pipe.width);

                    if (bird.x + 10.0 > p.x and
                        bird.x - 10.0 < p.x + pw)
                    {
                        if (bird.y - 10.0 < p.gap_y - cfg.pipe_gap / 2.0 or
                            bird.y + 10.0 > p.gap_y + cfg.pipe_gap / 2.0)
                        {
                            if (state != .dead) {
                                rl.playSound(snd_hit);
                                rl.playSound(snd_die);
                                state = .dead;
                            }
                        }
                    }

                    if (p.x + pw < 0) {
                        _ = pipes.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }

                // anima chão
                base_offset -= BASE_SPEED;
                if (base_offset <= -@as(f32, @floatFromInt(tex_base.width)) / 2.0) {
                    base_offset = 0.0;
                }
            },
            .dead => {
                // pássaro cai
                bird.vy += cfg.gravity;
                bird.y += bird.vy;
                bird.angle = 90.0;
                if (flap) {
                    state = .menu;
                    bird = Bird{};
                }
            },
        }

        // ── draw ───────────────────────────────────────────────────
        rl.beginDrawing();
        defer rl.endDrawing();

        const tex_bg = switch (theme) {
            .day => tex_bg_day,
            .night => tex_bg_night,
        };

        // background
        rl.drawTexturePro(
            tex_bg,
            rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(tex_bg.width),
                .height = @floatFromInt(tex_bg.height),
            },
            rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(W),
                .height = @floatFromInt(H),
            },
            rl.Vector2{ .x = 0, .y = 0 },
            0.0,
            rl.Color.white,
        );

        // canos
        for (pipes.items) |p| {
            const pw = tex_pipe.width;
            const ph = tex_pipe.height;
            const top_h: f32 = p.gap_y - cfg.pipe_gap / 2.0;

            // cano superior (espelhado verticalmente)
            rl.drawTexturePro(
                tex_pipe,
                rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(pw), .height = @floatFromInt(-ph) },
                rl.Rectangle{ .x = p.x, .y = 0, .width = @floatFromInt(pw), .height = top_h },
                rl.Vector2{ .x = 0, .y = 0 },
                0.0,
                rl.Color.white,
            );

            // cano inferior
            rl.drawTexturePro(
                tex_pipe,
                rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(pw), .height = @floatFromInt(ph) },
                rl.Rectangle{ .x = p.x, .y = p.gap_y + cfg.pipe_gap / 2.0, .width = @floatFromInt(pw), .height = FLOOR_Y - (p.gap_y + cfg.pipe_gap / 2.0) },
                rl.Vector2{ .x = 0, .y = 0 },
                0.0,
                rl.Color.white,
            );
        }

        // chão (tile animado)
        rl.drawTexture(tex_base, @intFromFloat(base_offset), @intFromFloat(FLOOR_Y), rl.Color.white);
        rl.drawTexture(tex_base, @intFromFloat(base_offset + @as(f32, @floatFromInt(tex_base.width))), @intFromFloat(FLOOR_Y), rl.Color.white);
        rl.drawTexture(tex_base, @intFromFloat(base_offset + 2 * @as(f32, @floatFromInt(tex_base.width))), @intFromFloat(FLOOR_Y), rl.Color.white);

        // pássaro
        const btex = bird_texs[bird.frame];
        const bw: f32 = @floatFromInt(btex.width);
        const bh: f32 = @floatFromInt(btex.height);
        rl.drawTexturePro(
            btex,
            rl.Rectangle{ .x = 0, .y = 0, .width = bw, .height = bh },
            rl.Rectangle{ .x = bird.x, .y = bird.y, .width = bw, .height = bh },
            rl.Vector2{ .x = bw / 2.0, .y = bh / 2.0 },
            bird.angle,
            rl.Color.white,
        );

        // HUD
        switch (state) {
            .menu => {
                drawMainMenu(menu_item, difficulty, theme, volume);
            },
            .waiting => {
                const mw: f32 = @floatFromInt(tex_msg.width);
                const mh: f32 = @floatFromInt(tex_msg.height);

                rl.drawTexture(
                    tex_msg,
                    @intFromFloat(W / 2.0 - mw / 2.0),
                    @intFromFloat(H / 2.0 - mh / 2.0 - 40.0),
                    rl.Color.white,
                );
            },
            .playing => drawScore(score, &digit_texs, W),
            .dead => {
                drawScore(score, &digit_texs, W);
                const ow: f32 = @floatFromInt(tex_over.width);
                rl.drawTexture(
                    tex_over,
                    @intFromFloat(W / 2.0 - ow / 2.0),
                    @intFromFloat(H / 2.0 - 60.0),
                    rl.Color.white,
                );
            },
        }
    }
}

fn drawCentered(text: [:0]const u8, y: i32, size: i32, color: rl.Color) void {
    const w = rl.measureText(text, size);
    rl.drawText(text, W / 2 - @divTrunc(w, 2), y, size, color);
}

fn drawMainMenu(
    selected: MenuItem,
    difficulty: Difficulty,
    theme: Theme,
    volume: f32,
) void {
    const line_h = 48;
    const start_y = H / 2 - 120;
    //const center = W / 2;

    drawCentered("FLAPPY BIRD", start_y - 100, 48, rl.Color.yellow);

    drawCentered(
        "START",
        start_y,
        30,
        if (selected == .start) rl.Color.yellow else rl.Color.white,
    );

    drawCentered(
        switch (difficulty) {
            .easy => "DIFFICULTY: EASY",
            .medium => "DIFFICULTY: MEDIUM",
            .hard => "DIFFICULTY: HARD",
        },
        start_y + line_h,
        30,
        if (selected == .difficulty) rl.Color.yellow else rl.Color.white,
    );

    drawCentered(
        if (theme == .day)
            "THEME: DAY"
        else
            "THEME: NIGHT",
        start_y + line_h * 2,
        30,
        if (selected == .theme) rl.Color.yellow else rl.Color.white,
    );

    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrintZ(
        &buf,
        "VOLUME: {d}%",
        .{@as(i32, @intFromFloat(volume * 100.0))},
    ) catch unreachable;

    drawCentered(
        txt,
        start_y + line_h * 3,
        30,
        if (selected == .volume) rl.Color.yellow else rl.Color.white,
    );

    drawCentered(
        "EXIT",
        start_y + line_h * 4,
        30,
        if (selected == .exit) rl.Color.yellow else rl.Color.white,
    );

    drawCentered("UP/DOWN = SELECT", start_y + 280, 20, rl.Color.light_gray);
    drawCentered("LEFT/RIGHT = CHANGE", start_y + 305, 20, rl.Color.light_gray);
    drawCentered("ENTER = CONFIRM", start_y + 330, 20, rl.Color.light_gray);
}

fn animBird(bird: *@import("main.zig").Bird) void {
    bird.frame_timer += 1;
    if (bird.frame_timer >= ANIM_RATE) {
        bird.frame_timer = 0;
        bird.frame = (bird.frame + 1) % BIRD_FRAMES;
    }
}

fn drawScore(score: u32, digits: *const [10]rl.Texture2D, w: comptime_int) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{score}) catch return;
    const dw = digits[0].width;
    const total_w = @as(i32, @intCast(s.len)) * (dw + 2);
    var x: i32 = w / 2 - @divTrunc(total_w, 2);
    for (s) |c| {
        const d: usize = c - '0';
        rl.drawTexture(digits[d], x, 30, rl.Color.white);
        x += dw + 2;
    }
}
