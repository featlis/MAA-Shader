#ifndef TONEMAP_GLSL
#define TONEMAP_GLSL

#include "/lib/common.glsl"

// ============================================================================
// Nightscape HDR Bloom & 4-Point Optical Cross-Star Sparkle Glare
// ============================================================================
const vec2 BLOOM_SPIRAL[12] = vec2[12](
    vec2( 1.0000,  0.0000),
    vec2(-0.7374,  0.6755),
    vec2( 0.0874, -0.9962),
    vec2( 0.6068,  0.7949),
    vec2(-0.9646, -0.2636),
    vec2( 0.8899, -0.4562),
    vec2(-0.3525,  0.9358),
    vec2(-0.3717, -0.9284),
    vec2( 0.8996,  0.4367),
    vec2(-0.9587,  0.2845),
    vec2( 0.5904, -0.8071),
    vec2( 0.1080,  0.9942)
);

// Extracts only genuine HDR emitters & bright specular glints (zero haze on normal terrain!)
vec3 extractHDRBrightPass(vec3 hdrColor, float emission) {
    float luma = getLuminance(hdrColor);
    float excess = max(luma - 0.82, 0.0) + emission * 0.75;
    if (excess <= 0.001) return vec3(0.0);

    float softKnee = (excess * excess) / (0.60 + excess * excess);
    // Enrich chroma of blooming light while preventing firefly blowouts
    vec3 saturated = max(mix(vec3(luma), hdrColor, 1.32), vec3(0.0));
    vec3 compressed = saturated / (1.0 + luma * 0.22);
    return compressed * softKnee;
}

vec3 computeHDRBloomAndSparkle(
    sampler2D hdrTex,
    sampler2D matSpecTex,
    vec2 uv,
    vec2 texelSize,
    float time
) {
    #ifndef ENABLE_BLOOM_AND_SPARKLE
    return vec3(0.0);
    #endif

    // 1. Multi-Radius Golden-Spiral Colored HDR Bloom (12 taps, 2.5px to 22px)
    vec3 bloomAccum = vec3(0.0);
    float bloomWeightSum = 0.0;

    if (BLOOM_INTENSITY > 0.001) {
        for (int i = 0; i < 12; i++) {
            float fi = (float(i) + 0.5) / 12.0;
            float radiusPx = mix(2.5, 22.0, fi * fi * 0.65 + fi * 0.35);
            vec2 sampleUV = clamp(uv + BLOOM_SPIRAL[i] * texelSize * radiusPx, vec2(0.002), vec2(0.998));

            vec3 sColor = texture(hdrTex, sampleUV).rgb;
            float sEmit = texture(matSpecTex, sampleUV).b;
            vec3 bright = extractHDRBrightPass(sColor, sEmit);

            float w = exp(-fi * 2.1);
            bloomAccum += bright * w;
            bloomWeightSum += w;
        }
        bloomAccum = (bloomAccum / max(bloomWeightSum, 0.001)) * (0.28 * BLOOM_INTENSITY);
    }

    // 2. 4-Point Optical Cross-Star Sparkle Glare (Night Lights, Stars, Water & Metal Glints)
    vec3 sparkleAccum = vec3(0.0);
    if (SPARKLE_INTENSITY > 0.001) {
        // Classic 18-degree tilted cinema cross-star axes
        const vec2 STAR_AXES[4] = vec2[4](
            vec2( 0.9511,  0.3090),
            vec2(-0.9511, -0.3090),
            vec2(-0.3090,  0.9511),
            vec2( 0.3090, -0.9511)
        );

        for (int a = 0; a < 4; a++) {
            vec2 axisDir = STAR_AXES[a] * texelSize;
            vec3 axisPeak = vec3(0.0);
            vec3 axisSum  = vec3(0.0);

            for (int s = 1; s <= 5; s++) {
                float fs = float(s) / 5.0;
                float stepPx = mix(1.8, 28.0, fs * fs * 0.55 + fs * 0.45);
                vec2 sUV = clamp(uv + axisDir * stepPx, vec2(0.002), vec2(0.998));

                vec3 sCol = texture(hdrTex, sUV).rgb;
                float sLuma = getLuminance(sCol);
                float sEmit = texture(matSpecTex, sUV).b;

                // Trigger diffraction spikes on bright point lights, stars, and intense specular glints
                float spikeTrigger = max(sLuma - 1.05, 0.0) + sEmit * 1.10;
                if (spikeTrigger > 0.05) {
                    float spikeMask = (spikeTrigger * spikeTrigger) / (0.75 + spikeTrigger * spikeTrigger);
                    // Subtle optical chromatic dispersion & temporal twinkling along the spike ray
                    vec3 dispersionTint = mix(vec3(1.10, 0.98, 0.88), vec3(0.84, 0.96, 1.16), fs);
                    float spatialSeed = dot(floor(sUV * 320.0), vec2(1.73, 2.91));
                    float rayShimmer = 0.78 + 0.34 * sin(time * 5.8 + spatialSeed + float(a) * 1.57);

                    vec3 clampedSpikeCol = max(mix(vec3(sLuma), sCol, 1.38), vec3(0.0)) / (1.0 + sLuma * 0.22);
                    float falloff = exp(-fs * 2.15);
                    vec3 sampleRay = clampedSpikeCol * dispersionTint * (spikeMask * falloff * rayShimmer);

                    axisPeak = max(axisPeak, sampleRay);
                    axisSum += sampleRay * 0.25;
                }
            }
            sparkleAccum += (axisPeak * 0.75 + axisSum * 0.25);
        }
        sparkleAccum *= (0.24 * SPARKLE_INTENSITY);
        sparkleAccum /= (1.0 + getLuminance(sparkleAccum) * 0.65);
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
