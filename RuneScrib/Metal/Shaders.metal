#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_fullscreen(uint vid [[vertex_id]]) {
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

struct FragmentUniforms {
    float4 timeAndResolution;
    float4 baseColorA;
    float4 baseColorB;
    float4 bandParameters;
    float4 bandColorAndStrength;
    float4 columnParameters;
    float4 columnColor;
    float4 highlightColorAndStrength;
    float4 highlightAndVignette;
    float4 shimmerParameters;
};

fragment float4 fragment_rune_background(
    VertexOut        in         [[stage_in]],
    constant FragmentUniforms& uniforms [[buffer(0)]]
) {
    float2 uv = in.uv;
    float t = uniforms.timeAndResolution.x;
    float3 base = mix(
        uniforms.baseColorA.rgb,
        uniforms.baseColorB.rgb,
        uv.y
    );

    float bands = sin(
        (uv.x - uv.y) * uniforms.bandParameters.x
        + t * uniforms.bandParameters.y
    );
    bands = smoothstep(
        uniforms.bandParameters.z,
        uniforms.bandParameters.w,
        bands
    );
    base = mix(
        base,
        base + uniforms.bandColorAndStrength.rgb,
        bands * uniforms.bandColorAndStrength.w
    );

    float columns = abs(sin(
        uv.x * uniforms.columnParameters.x
        + t * uniforms.columnParameters.y
    ));
    columns = pow(columns, uniforms.columnParameters.z);
    base += uniforms.columnColor.rgb
        * columns
        * uniforms.columnParameters.w;

    float pulse1 = sin(uv.x * 24.0 + t * 0.6) * cos(uv.y * 16.0 - t * 0.4);
    float pulse2 = sin(uv.x * 11.0 - t * 0.3) * sin(uv.y * 19.0 + t * 0.5);
    float highlights = abs(pulse1 * pulse2);
    highlights = pow(highlights, uniforms.highlightAndVignette.x);
    base += uniforms.highlightColorAndStrength.rgb
        * highlights
        * uniforms.highlightColorAndStrength.w;

    float2 center = uv - 0.5;
    float vignette = 1.0
        - dot(center, center) * uniforms.highlightAndVignette.y;
    vignette = saturate(vignette);
    base *= vignette;

    float shimmer = sin(
        t * uniforms.shimmerParameters.x
        + uv.x * uniforms.shimmerParameters.y
    ) * uniforms.shimmerParameters.z;
    base += float3(shimmer);

    return float4(saturate(base), 1.0);
}
