//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

const std = @import("std");

/// Default fonts that we prefer for Ghostty.
pub const variable = @embedFile("jetbrains_mono_variable");
pub const variable_italic = @embedFile("jetbrains_mono_variable_italic");

/// Symbols-only nerd font.
pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");

/// Families resolvable by name via `family` on builds without font
/// discovery (Android). Only referenced there, so other builds don't
/// embed the extra fonts.
pub const fira_code = @embedFile("res/FiraCode-Regular.ttf");
pub const hack = @embedFile("res/Hack-Regular.ttf");

/// Full Noto Sans Symbols 2, used as a fallback on Android where the
/// system only ships subsetted symbol fonts (missing e.g. the U+23Ex/23Fx
/// media-control symbols common in terminal UIs).
pub const symbols2 = @embedFile("res/NotoSansSymbols2-Regular.ttf");

/// Resolve a `font-family` name against the embedded faces. Used when the
/// build has no font discovery, where a configured family would otherwise
/// be silently ignored.
pub fn family(name: []const u8) ?[:0]const u8 {
    const map: []const struct { []const u8, [:0]const u8 } = &.{
        .{ "JetBrains Mono", variable },
        .{ "Fira Code", fira_code },
        .{ "Hack", hack },
        .{ "Geist Mono", geist_mono },
    };
    for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    }
    return null;
}

/// Static jetbrains mono faces, currently unused.
pub const regular = @embedFile("jetbrains_mono_regular");
pub const bold = @embedFile("jetbrains_mono_bold");
pub const italic = @embedFile("jetbrains_mono_italic");
pub const bold_italic = @embedFile("jetbrains_mono_bold_italic");

/// Emoji fonts
pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");

// Fonts below are ONLY used for testing.

/// Fonts with general properties
pub const arabic = @embedFile("res/KawkabMono-Regular.ttf");

/// A font for testing which is patched with nerd font symbols.
pub const test_nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");

/// Specific font families below:
pub const code_new_roman = @embedFile("res/CodeNewRoman-Regular.otf");
pub const inconsolata = @embedFile("res/Inconsolata-Regular.ttf");
pub const geist_mono = @embedFile("res/GeistMono-Regular.ttf");
pub const jetbrains_mono = @embedFile("res/JetBrainsMonoNoNF-Regular.ttf");
pub const julia_mono = @embedFile("res/JuliaMono-Regular.ttf");

/// Cozette is a unique font because it embeds some emoji characters
/// but has a text presentation.
pub const cozette = @embedFile("res/CozetteVector.ttf");

/// Monaspace has weird ligature behaviors we want to test in our shapers
/// so we embed it here.
pub const monaspace_neon = @embedFile("res/MonaspaceNeon-Regular.otf");

/// Terminus TTF is a scalable font with bitmap glyphs at various sizes.
pub const terminus_ttf = @embedFile("res/TerminusTTF-Regular.ttf");

/// Spleen is a monospaced bitmap font available in multiple formats.
/// Used for testing bitmap font support across different file formats.
pub const spleen_bdf = @embedFile("res/spleen-8x16.bdf");
pub const spleen_pcf = @embedFile("res/spleen-8x16.pcf");
pub const spleen_otb = @embedFile("res/spleen-8x16.otb");
