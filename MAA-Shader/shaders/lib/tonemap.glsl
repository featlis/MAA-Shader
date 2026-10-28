#ifndef TONEMAP_GLSL
#define TONEMAP_GLSL

#include "/lib/common.glsl"

// ============================================================================
// Contiguous Depth-Occluded HDR Bloom & Pinpoint Micro-Glint
// (Zero floating dots, zero lines bleeding through foreground blocks!)
// ============================================================================
const vec2 BLOOM_DIRS[8] = vec2[8](
    vec2( 1.0000,  0.0000),
    vec2( 0.7071,  0.7071),
    vec2( 0.0000,  1.0000),
    vec2(-0.7071,  0.7071),
    vec2(-1.0000,  0.0000),
    vec2(-0.7071, -0.7071),
    vec2( 0.0000, -1.0000),
    vec2( 0.7071, -0.7071)
);

// Extracts only genuine HDR emitters & bright specular glints (zero haze on normal terrain!)
vec3 extractHDRBrightPass(vec3 hdrColor, float emission) {
    float luma = getLuminance(hdrColor);
    float excess = max(luma - 0.85, 0.0) + max(emission - 0.12, 0.0) * 0.75;
    if (excess <= 0.001) return vec3(0.0);

    float softKnee = (excess * excess) / (0.65 + excess * excess);
    vec3 saturated = max(mix(vec3(luma), hdrColor, 1.25), vec3(0.0));
    vec3 compressed = saturated / (1.0 + luma * 0.32);
    return compressed * softKnee;
}

// Scale-invariant 3D depth occlusion check:
// In perspective projection, (1.0 - depth) is proportional to (1.0 / linearDistance).
// Returns true if sampleDepth is in the sky behind a foreground block, OR > 22% farther in 3D distance than centerDepth!
bool isSampleOccludedByForeground(float centerDepth, float sampleDepth, bool centerIsForeground) {
    if (!centerIsForeground) return false;
    if (sampleDepth >= 0.9999) return true;
    return (1.0 - centerDepth) > (1.0 - sampleDepth) * 1.22;
}

vec3 computeHDRBloomAndSparkle(
    sampler2D hdrTex,
    sampler2D matSpecTex,
    sampler2D depthTex,
    vec2 uv,
    vec2 texelSize,
    float time
) {
    #ifndef ENABLE_BLOOM_AND_SPARKLE
    return vec3(0.0);
    #endif

    float centerDepth = texture(depthTex, uv).r;
    bool centerIsForeground = (centerDepth < 0.9999);

    // 1. Contiguous 3-Ring Depth-Occluded Gaussian Bloom (1.15px, 2.30px & 3.55px, zero floating dots!)
    vec3 bloomAccum = vec3(0.0);
    float bloomWeightSum = 0.001;

    if (BLOOM_INTENSITY > 0.001) {
        vec3 centerCol = texture(hdrTex, uv).rgb;
        float centerEmit = texture(matSpecTex, uv).b;
        bloomAccum += extractHDRBrightPass(centerCol, centerEmit) * 0.26;
        bloomWeightSum += 0.26;

        for (int i = 0; i < 8; i++) {
            vec2 dir = BLOOM_DIRS[i] * texelSize;

            // Ring 1 (1.15px)
            vec2 uv1 = clamp(uv + dir * 1.15, vec2(0.002), vec2(0.998));
            float d1 = texture(depthTex, uv1).r;
            bool occ1 = isSampleOccludedByForeground(centerDepth, d1, centerIsForeground);
            if (!occ1) {
                vec3 c1 = texture(hdrTex, uv1).rgb;
                float e1 = texture(matSpecTex, uv1).b;
                bloomAccum += extractHDRBrightPass(c1, e1) * 0.18;
                bloomWeightSum += 0.18;
            }

            // Ring 2 (2.30px)
            vec2 uv2 = clamp(uv + dir * 2.30, vec2(0.002), vec2(0.998));
            float d2 = texture(depthTex, uv2).r;
            bool occ2 = occ1 || isSampleOccludedByForeground(centerDepth, d2, centerIsForeground);
            if (!occ2) {
                vec3 c2 = texture(hdrTex, uv2).rgb;
                float e2 = texture(matSpecTex, uv2).b;
                bloomAccum += extractHDRBrightPass(c2, e2) * 0.10;
                bloomWeightSum += 0.10;
            }

            // Ring 3 (3.55px)
            vec2 uv3 = clamp(uv + dir * 3.55, vec2(0.002), vec2(0.998));
            float d3 = texture(depthTex, uv3).r;
            if (!occ2 && !isSampleOccludedByForeground(centerDepth, d3, centerIsForeground)) {
                vec3 c3 = texture(hdrTex, uv3).rgb;
                float e3 = texture(matSpecTex, uv3).b;
                bloomAccum += extractHDRBrightPass(c3, e3) * 0.05;
                bloomWeightSum += 0.05;
            }
        }
        bloomAccum = (bloomAccum / bloomWeightSum) * (0.28 * BLOOM_INTENSITY);
    }

    // 2. Contiguous 1.12px-Step Depth-Occluded Crystal Glint (up to ~6.7px, zero dotted lines, zero wall bleed!)
    vec3 sparkleAccum = vec3(0.0);
    if (SPARKLE_INTENSITY > 0.001) {
        const vec2 STAR_AXES[4] = vec2[4](
            vec2( 0.9511,  0.3090),
            vec2(-0.9511, -0.3090),
            vec2(-0.3090,  0.9511),
            vec2( 0.3090, -0.9511)
        );

        for (int a = 0; a < 4; a++) {
            vec2 axisDir = STAR_AXES[a] * texelSize;
            vec3 axisSum = vec3(0.0);

            for (int s = 1; s <= 6; s++) {
                float stepPx = float(s) * 1.12;
                vec2 sUV = clamp(uv + axisDir * stepPx, vec2(0.002), vec2(0.998));
                float sDepth = texture(depthTex, sUV).r;

                // Stop immediately if a foreground block occludes the ray (never draw lines through blocks!)
                if (isSampleOccludedByForeground(centerDepth, sDepth, centerIsForeground)) {
                    break;
                }

                vec3 sCol = texture(hdrTex, sUV).rgb;
                float sLuma = getLuminance(sCol);
                float sEmit = texture(matSpecTex, sUV).b;

                float spikeTrigger = max(sLuma - 1.12, 0.0) + max(sEmit - 0.42, 0.0) * 1.10;
                if (spikeTrigger > 0.05) {
                    float spikeMask = (spikeTrigger * spikeTrigger) / (0.85 + spikeTrigger * spikeTrigger);
                    float fs = float(s) / 6.0;
                    float falloff = exp(-fs * 2.15) * (1.0 - fs * 0.35);
                    float spatialSeed = dot(floor(sUV * 320.0), vec2(1.73, 2.91));
                    float rayShimmer = 0.82 + 0.26 * sin(time * 5.2 + spatialSeed + float(a) * 1.57);

                    vec3 clampedSpikeCol = max(mix(vec3(sLuma), sCol, 1.28), vec3(0.0)) / (1.0 + sLuma * 0.32);
                    axisSum += clampedSpikeCol * (spikeMask * falloff * rayShimmer * 0.36);
                }
            }
            sparkleAccum += axisSum;
        }
        sparkleAccum *= (0.30 * SPARKLE_INTENSITY);
        sparkleAccum /= (1.0 + getLuminance(sparkleAccum) * 0.75);
    }

    return bloomAccum + sparkleAccum;
}

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
