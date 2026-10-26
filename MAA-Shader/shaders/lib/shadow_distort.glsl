#ifndef SHADOW_DISTORT_GLSL
#define SHADOW_DISTORT_GLSL

#include "/lib/settings.glsl"

// ============================================================================
// Shadow Map Coordinate Distortion
// Concentrates shadow map resolution near player for sharp contact shadows
// while covering large render distances at low GPU cost.
// ============================================================================

float getShadowDistortFactor(vec2 clipXY) {
    // Euclidean-cubic hybrid length to prevent axial seam artifacts
    vec2 p2 = clipXY * clipXY;
    float dist = sqrt(p2.x + p2.y);
    return mix(1.0, dist, SHADOW_DISTORTION);
}

vec3 distortShadowClipPos(vec3 clipPos) {
    float factor = getShadowDistortFactor(clipPos.xy);
    clipPos.xy /= max(factor, 0.0001);
    clipPos.z *= 0.5; // Compress Z range to prevent tall mountain clipping
    return clipPos;
}

vec3 worldToShadowScreen(vec3 playerPos, vec3 worldNormal, float NoL, mat4 shadowMV, mat4 shadowProj) {
    // Estimate distortion factor first to scale normal bias accurately
    vec4 rawClip = shadowProj * (shadowMV * vec4(playerPos, 1.0));
    float factor = getShadowDistortFactor(rawClip.xy);

    // Adaptive normal offset bias: tiny near player, larger at far distorted edges
    float slopeBias = clamp(1.0 - NoL, 0.05, 1.0);
    float normalBias = (0.025 + 0.06 * slopeBias) * factor * (2048.0 / float(SHADOW_MAP_RESOLUTION));
    vec3 biasedPos = playerPos + worldNormal * normalBias;

    vec4 shadowView = shadowMV * vec4(biasedPos, 1.0);
    vec4 shadowClip = shadowProj * shadowView;
    shadowClip.xyz /= shadowClip.w;

    shadowClip.xyz = distortShadowClipPos(shadowClip.xyz);
    return shadowClip.xyz * 0.5 + 0.5;
}

#endif // SHADOW_DISTORT_GLSL

