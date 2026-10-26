#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/tonemap.glsl"

uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;

uniform float viewWidth;
uniform float viewHeight;
uniform float near;
uniform float far;
uniform float frameTimeCounter;
uniform ivec2 eyeBrightnessSmooth;

in vec2 vTexCoord;

void main() {
    vec2 texelSize = vec2(1.0 / max(viewWidth, 1.0), 1.0 / max(viewHeight, 1.0));
    vec2 sampleUV = vTexCoord;

    // 1. Distant Atmospheric Shimmer & Thermal Heat Haze (Lava / Distant Horizons)
    #ifdef ENABLE_HEAT_HAZE
    float depth = texture(depthtex0, vTexCoord).r;
    if (depth < 0.9999) {
        float linDepth = linearizeDepth(depth, near, far);
        float blockLight = texture(colortex1, vTexCoord).b;
        float matId = texture(colortex2, vTexCoord).a;

        // Thermal shimmer near lava/fire or on distant lit surfaces (> 24m)
        float lavaHeat = isMaterial(matId, MAT_EMISSIVE_LAVA) ? 1.0 : smoothstep(0.78, 0.98, blockLight) * 0.45;
        float distShimmer = smoothstep(24.0, 96.0, linDepth) * (0.35 + blockLight * 0.65);
        float hazeStrength = clamp((lavaHeat * 0.85 + distShimmer * 0.55) * DISTANT_LIGHT_SHIMMER, 0.0, 1.2);

        if (hazeStrength > 0.01) {
            vec2 waveCoord = vTexCoord * vec2(viewWidth, viewHeight) * 0.06;
            float t = frameTimeCounter * 6.5;
            vec2 offset = vec2(
                sin(waveCoord.y * 1.7 + t + cos(waveCoord.x * 1.3 - t * 0.8)),
                cos(waveCoord.x * 1.5 - t * 1.1 + sin(waveCoord.y * 1.9 + t * 0.7))
            ) * texelSize * (0.55 * hazeStrength);

            vec2 candidateUV = clamp(vTexCoord + offset, vec2(0.002), vec2(0.998));
            float candidateDepth = texture(depthtex0, candidateUV).r;
            // Prevent foreground silhouette bleeding
            if (candidateDepth >= depth - 0.0015) {
                sampleUV = candidateUV;
            }
        }
    }
    #endif

    // 2. Sample HDR image with FXAA + CAS sharpening
    vec3 hdrColor = applyFXAAAndCAS(colortex7, sampleUV, texelSize);

    // 3. Dynamic Eye Adaptation (Smooth Auto-Exposure without washing out shadows)
    float exposure = 1.0;
    #ifdef ENABLE_AUTO_EXPOSURE
    vec2 eyeNorm = clamp(vec2(eyeBrightnessSmooth) / 240.0, 0.0, 1.0);
    float envBrightness = max(eyeNorm.x * 0.85, eyeNorm.y);

    float centerLuma = getLuminance(texture(colortex7, vec2(0.50, 0.50)).rgb);
    float q1Luma     = getLuminance(texture(colortex7, vec2(0.30, 0.35)).rgb);
    float q2Luma     = getLuminance(texture(colortex7, vec2(0.70, 0.35)).rgb);
    float q3Luma     = getLuminance(texture(colortex7, vec2(0.30, 0.65)).rgb);
    float q4Luma     = getLuminance(texture(colortex7, vec2(0.70, 0.65)).rgb);
    float avgSceneLuma = clamp((centerLuma * 2.0 + q1Luma + q2Luma + q3Luma + q4Luma) / 6.0, 0.05, 4.0);

    float targetExposure = clamp(0.66 / pow(avgSceneLuma, 0.24), 0.88, 1.42);
    float caveBoost = mix(1.18, 0.96, smoothstep(0.0, 0.75, envBrightness));
    exposure = mix(targetExposure, caveBoost, 0.50);
    #endif

    hdrColor *= exposure;

    // 4. Cinematic-Realistic ACES Tone Mapping (Crisp Blacks, Natural Roll-off)
    vec3 tonemappedLinear = cinematicACESTonemap(hdrColor);

    // 5. Convert to sRGB & Apply Cinematic Color Grading
    vec3 srgbColor = toSRGB(tonemappedLinear);
    srgbColor = applyCinematicGrading(srgbColor);

    // 6. Subtle Cinematic Vignette
    vec2 vigUV = vTexCoord * (1.0 - vTexCoord.yx);
    float vig = clamp(pow(vigUV.x * vigUV.y * 16.0, 0.12), 0.86, 1.0);
    srgbColor *= vig;

    gl_FragData[0] = vec4(srgbColor, 1.0);
}
