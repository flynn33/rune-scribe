// RuneScrib/Metal/Shaders.metal
// Norse-inspired animated background shader + a stitchable rune-glow layer effect.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Vertex Stage

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Full-screen quad vertex shader.
/// Draws 2 triangles covering clip space [-1,1] × [-1,1].
vertex VertexOut vertex_fullscreen(uint vid [[vertex_id]]) {
    // Triangle strip: 4 vertices forming a quad
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// MARK: - Fragment Stage

struct FragmentUniforms {
    float time;
    float2 resolution;
};

/// Animated Norse-inspired background.
/// Palette: deep navy base, electric blue mid-tones, gold runic highlights.
fragment float4 fragment_rune_background(
    VertexOut        in         [[stage_in]],
    constant FragmentUniforms& uniforms [[buffer(0)]]
) {
    float2 uv = in.uv;
    float t   = uniforms.time;

    // ── Layer 1: Base gradient (deep navy → midnight purple) ────────────────
    float3 colorA = float3(0.03, 0.04, 0.12);   // deep navy
    float3 colorB = float3(0.08, 0.03, 0.18);   // midnight purple
    float3 base   = mix(colorA, colorB, uv.y);

    // ── Layer 2: Diagonal scan lines (rune-band effect) ─────────────────────
    float bands = sin((uv.x - uv.y) * 18.0 + t * 0.25);
    bands = smoothstep(0.85, 1.0, bands);
    float3 bandColor = float3(0.06, 0.08, 0.22);
    base = mix(base, base + bandColor, bands * 0.4);

    // ── Layer 3: Vertical energy columns ────────────────────────────────────
    float cols = abs(sin(uv.x * 9.0 + t * 0.15));
    cols = pow(cols, 6.0);
    float3 colColor = float3(0.1, 0.3, 0.6);    // electric blue
    base += colColor * cols * 0.12;

    // ── Layer 4: Gold runic glow pulses ─────────────────────────────────────
    float pulse1 = sin(uv.x * 24.0 + t * 0.6) * cos(uv.y * 16.0 - t * 0.4);
    float pulse2 = sin(uv.x * 11.0 - t * 0.3) * sin(uv.y * 19.0 + t * 0.5);
    float rune   = abs(pulse1 * pulse2);
    rune = pow(rune, 7.0);                       // sharp highlights only

    float3 goldColor = float3(0.82, 0.60, 0.08); // Norse gold
    base += goldColor * rune * 0.9;

    // ── Layer 5: Vignette (darken edges) ────────────────────────────────────
    float2 center = uv - 0.5;
    float vignette = 1.0 - dot(center, center) * 1.8;
    vignette = saturate(vignette);
    base *= vignette;

    // ── Layer 6: Subtle shimmer ──────────────────────────────────────────────
    float shimmer = sin(t * 2.1 + uv.x * 40.0) * 0.012;
    base += float3(shimmer);

    return float4(saturate(base), 1.0);
}

// MARK: - Rune Glow (SwiftUI layer effect)

/// A faint coloured halo around rune glyphs. Used via SwiftUI's
/// `.layerEffect(ShaderLibrary.runeGlow(...))`. For each pixel it samples the
/// glyph coverage (alpha) on two concentric rings and blooms a soft, tinted glow
/// into the surrounding transparent area, leaving the glyph itself unchanged.
///
/// Arguments (after the implicit `position` + `layer`):
///   glowColor — halo tint, straight (non-premultiplied) alpha; its alpha caps the
///               halo opacity (pass a SwiftUI `Color`)
///   radius    — glow reach in points (must be ≤ the modifier's maxSampleOffset)
///   intensity — overall halo strength
///
/// `layer.sample` returns premultiplied colour, and the return value must also be
/// premultiplied, so the tint is premultiplied by its alpha before compositing.
[[ stitchable ]] half4 runeGlow(float2 position,
                                SwiftUI::Layer layer,
                                half4 glowColor,
                                float radius,
                                float intensity) {
    half4 src = layer.sample(position);

    // Accumulate glyph coverage on two rings around this pixel.
    const int kSamples = 12;
    float coverage = 0.0;
    for (int i = 0; i < kSamples; ++i) {
        float angle = (float(i) + 0.5) / float(kSamples) * 6.28318530718;
        float2 dir = float2(cos(angle), sin(angle));
        coverage += float(layer.sample(position + dir * radius).a);
        coverage += float(layer.sample(position + dir * (radius * 0.5)).a);
    }
    coverage /= float(kSamples * 2);

    half halo = half(saturate(coverage * intensity));

    // The halo only shows where the glyph itself is (semi-)transparent. RGB and
    // alpha are scaled together so the premultiplied invariant holds.
    half spill = halo * (1.0h - src.a);
    half3 tint = glowColor.rgb * glowColor.a;          // premultiply the tint
    half3 outRGB = src.rgb + tint * spill;
    half outA = max(src.a, glowColor.a * halo);
    return half4(outRGB, outA);
}
