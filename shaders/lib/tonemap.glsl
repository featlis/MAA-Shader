#ifndef TONEMAP_GLSL
#define TONEMAP_GLSL

#include "/lib/common.glsl"

// ============================================================================
// Cinematic-Realistic ACES Tone Mapping (Crisp Contrast, Zero Milky Haze)
// ============================================================================
vec3 cinematicACESTonemap(vec3 color) {
    // Micro shadow-toe lift (0.002 default) prevents crushed 0.0 caves while keeping blacks rich and crisp
    vec3 lifted = max(color, vec3(0.0)) + vec3(SHADOW_TOE_LIFT) * (1.0 / (1.0 + color * 24.0));

    // ACES input matrix (sRGB to AP1-like space)
    const mat3 ACESInputMat = mat3(
        0.59719, 0.07600, 0.02840,
        0.35458, 0.90834, 0.13383,
        0.04823, 0.01566, 0.83777
    );

    // ACES output matrix
    const mat3 ACESOutputMat = mat3(
         1.60475, -0.10208, -0.00327,
        -0.53108,  1.10813, -0.07276,
        -0.07367, -0.00605,  1.07602
    );

    vec3 v = ACESInputMat * lifted;

    // Stephen Hill RRT and ODT fit for crisp blacks and natural highlight roll-off
    vec3 a = v * (v + 0.0245786) - 0.000090537;
    vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
    vec3 c = ACESOutputMat * (a / max(b, vec3(1e-5)));

    return clamp(c, 0.0, 1.0);
}

// Cinematic contrast & vibrance grading (crisp shadows, vivid light colors)
vec3 applyCinematicGrading(vec3 srgbColor) {
    // Crisp S-curve contrast centered around mid-grey (0.44)
    vec3 contrasted = clamp((srgbColor - 0.44) * CINEMATIC_CONTRAST + 0.44, 0.0, 1.0);
    srgbColor = mix(srgbColor, contrasted, smoothstep(0.01, 0.18, getLuminance(srgbColor)));

    // Vibrance + Saturation
    float luma = getLuminance(srgbColor);
    float maxChan = max(srgbColor.r, max(srgbColor.g, srgbColor.b));
    float minChan = min(srgbColor.r, min(srgbColor.g, srgbColor.b));
    float sat = maxChan - minChan;

    float vibranceFactor = mix(CINEMATIC_SATURATION, 1.0 + (CINEMATIC_SATURATION - 1.0) * 0.55, sat);
    srgbColor = mix(vec3(luma), srgbColor, vibranceFactor);

    return clamp(srgbColor, 0.0, 1.0);
}

// ============================================================================
// Fast Approximate Anti-Aliasing (FXAA 3.11 Lite) + CAS Sharpening
// ============================================================================
vec3 applyFXAAAndCAS(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec3 rgbM  = texture(tex, uv).rgb;

    #ifndef ENABLE_FXAA
    return rgbM;
    #endif

    vec3 rgbNW = texture(tex, uv + vec2(-1.0, -1.0) * texelSize).rgb;
    vec3 rgbNE = texture(tex, uv + vec2( 1.0, -1.0) * texelSize).rgb;
    vec3 rgbSW = texture(tex, uv + vec2(-1.0,  1.0) * texelSize).rgb;
    vec3 rgbSE = texture(tex, uv + vec2( 1.0,  1.0) * texelSize).rgb;

    float lumaM  = getLuminance(rgbM);
    float lumaNW = getLuminance(rgbNW);
    float lumaNE = getLuminance(rgbNE);
    float lumaSW = getLuminance(rgbSW);
    float lumaSE = getLuminance(rgbSE);

    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
    float lumaRange = lumaMax - lumaMin;

    vec3 result = rgbM;

    if (lumaRange >= max(0.0312, lumaMax * 0.125)) {
        vec2 dir;
        dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
        dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));

        float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * 0.25), 1.0 / 128.0);
        float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
        dir = clamp(dir * rcpDirMin, vec2(-6.0), vec2(6.0)) * texelSize;

        vec3 rgbA = 0.5 * (
            texture(tex, uv + dir * (1.0 / 3.0 - 0.5)).rgb +
            texture(tex, uv + dir * (2.0 / 3.0 - 0.5)).rgb
        );
        vec3 rgbB = rgbA * 0.5 + 0.25 * (
            texture(tex, uv + dir * -0.5).rgb +
            texture(tex, uv + dir *  0.5).rgb
        );

        float lumaB = getLuminance(rgbB);
        if (lumaB < lumaMin || lumaB > lumaMax) {
            result = rgbA;
        } else {
            result = rgbB;
        }
    }

    // Contrast-Adaptive Sharpening (CAS) for crisp block & light edges
    if (CAS_SHARPENING > 0.001) {
        vec3 avgNeighbor = 0.25 * (rgbNW + rgbNE + rgbSW + rgbSE);
        vec3 detail = rgbM - avgNeighbor;
        float edgeMask = clamp(1.0 - lumaRange * 2.2, 0.0, 1.0);
        result = clamp(result + detail * (CAS_SHARPENING * 0.52 * edgeMask), 0.0, 1.0);
    }

    return result;
}

#endif // TONEMAP_GLSL
