#include "common.glsl"

layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;

in CellTextVertexOut {
    flat uint atlas;
    flat vec4 color;
    flat uvec2 grid_coord;
    flat uint glyph_flags;
    vec2 tex_coord;
} in_data;

// Values `atlas` can take.
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_flags` interpolant.
const uint NO_MIN_CONTRAST = 1u;
const uint IS_CURSOR_GLYPH = 2u;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint bg_colors[];
};

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

// The bg color of this glyph's cell, blended with the global bg color.
vec4 cell_bg_color() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint packed_bg = bg_colors[in_data.grid_coord.y * grid_size.x + in_data.grid_coord.x];
    vec4 bg = load_color(unpack4u8(packed_bg), true);
    vec4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    return bg + global_bg * vec4(1.0 - bg.a);
}

// The glyph's final linear fg color: the cursor color wins over the cell's own
// color, otherwise minimum contrast is enforced against `bg`.
vec4 resolve_fg_color(vec4 bg, bool use_linear_blending) {
    uvec2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0u;

    bool is_cursor_pos =
        ((in_data.grid_coord.x == cursor_pos.x) ||
            (cursor_wide && (in_data.grid_coord.x == (cursor_pos.x + 1u)))) &&
        (in_data.grid_coord.y == cursor_pos.y);

    if ((in_data.glyph_flags & IS_CURSOR_GLYPH) == 0u && is_cursor_pos) {
        return load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    if (min_contrast > 1.0f && (in_data.glyph_flags & NO_MIN_CONTRAST) == 0u) {
        return contrasted_color(min_contrast, in_data.color, bg);
    }

    return in_data.color;
}

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0u;

    switch (in_data.atlas) {
        default:
        case ATLAS_GRAYSCALE:
        {
            // Our input color is always linear.
            vec4 bg_color = cell_bg_color();
            vec4 color = resolve_fg_color(bg_color, use_linear_blending);

            // If we're not doing linear blending, then we need to
            // re-apply the gamma encoding to our color manually.
            //
            // Since the alpha is premultiplied, we need to divide
            // it out before unlinearizing and re-multiply it after.
            if (!use_linear_blending) {
                color.rgb /= vec3(color.a);
                color = unlinearize(color);
                color.rgb *= vec3(color.a);
            }

            // Fetch our alpha mask for this pixel.
            float a = texture(atlas_grayscale, in_data.tex_coord).r;

            // Linear blending weight correction corrects the alpha value to
            // produce blending results which match gamma-incorrect blending.
            if (use_linear_correction) {
                // Short explanation of how this works:
                //
                // We get the luminances of the foreground and background colors,
                // and then unlinearize them and perform blending on them. This
                // gives us our desired luminance, which we derive our new alpha
                // value from by mapping the range [bg_l, fg_l] to [0, 1], since
                // our final blend will be a linear interpolation from bg to fg.
                //
                // This yields virtually identical results for grayscale blending,
                // and very similar but non-identical results for color blending.
                vec4 bg = bg_color;
                float fg_l = luminance(color.rgb);
                float bg_l = luminance(bg.rgb);
                // To avoid numbers going haywire, we don't apply correction
                // when the bg and fg luminances are within 0.001 of each other.
                if (abs(fg_l - bg_l) > 0.001) {
                    float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                    a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
                }
            }

            // Multiply our whole color by the alpha mask.
            // Since we use premultiplied alpha, this is
            // the correct way to apply the mask.
            color *= a;

            out_FragColor = color;
            return;
        }

        case ATLAS_COLOR:
        {
            // For now, we assume that color glyphs
            // are already premultiplied linear colors.
            vec4 color = texture(atlas_color, in_data.tex_coord);

            // If we are doing linear blending, we can return this right away.
            if (use_linear_blending) {
                out_FragColor = color;
                return;
            }

            // Otherwise we need to unlinearize the color. Since the alpha is
            // premultiplied, we need to divide it out before unlinearizing.
            color.rgb /= vec3(color.a);
            color = unlinearize(color);
            color.rgb *= vec3(color.a);

            out_FragColor = color;
            return;
        }
    }
}
