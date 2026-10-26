#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/tonemap.glsl"

uniform sampler2D colortex3;
uniform float viewWidth;
uniform float viewHeight;
uniform ivec2 eyeBrightnessSmooth;

in vec2 vTexCoord;

out vec4 outScreenColor;

void main() {
    vec2 texelSize = vec2(1.0 / max(viewWidth, 1.0), 1.0 / max(viewHeight, 1.0));

    // 1. Sample HDR image with FXAA + CAS sharpening
    vec3 hdrColor = applyFXAAAndCAS(colortex3, vTexCoord, texelSize);

    // 2. Dynamic Eye Adaptation (Smooth Auto-Exposure)
    float exposure = 1.0;
    #ifdef ENABLE_AUTO_EXPOSURE
    // eyeBrightnessSmooth is in [0..240] for (blockLight, skyLight) at player's eyes
    vec2 eyeNorm = clamp(vec2(eyeBrightnessSmooth) / 240.0, 0.0, 1.0);
    float envBrightness = max(eyeNorm.x * 0.85, eyeNorm.y);

    // Sample 5-point anchor luminance across screen
    float centerLuma = getLuminance(texture(colortex3, vec2(0.50, 0.50)).rgb);
    float q1Luma     = getLuminance(texture(colortex3, vec2(0.30, 0.35)).rgb);
    float q2Luma     = getLuminance(texture(colortex3, vec2(0.70, 0.35)).rgb);
    float q3Luma     = getLuminance(texture(colortex3, vec2(0.30, 0.65)).rgb);
    float q4Luma     = getLuminance(texture(colortex3, vec2(0.70, 0.65)).rgb);
    float avgSceneLuma = clamp((centerLuma * 2.0 + q1Luma + q2Luma + q3Luma + q4Luma) / 6.0, 0.04, 4.0);

    // Raise exposure smoothly in dark caves/night (up to 1.65x), slightly compress bright noon glare (0.92x)
    float targetExposure = clamp(0.68 / pow(avgSceneLuma, 0.28), 0.88, 1.68);
    float caveBoost = mix(1.38, 0.96, smoothstep(0.0, 0.75, envBrightness));
    exposure = mix(targetExposure, caveBoost, 0.55);
    #endif

    hdrColor *= exposure;

    // 3. Cinematic-Realistic ACES Tone Mapping with Lifted Shadow Toe
    vec3 tonemappedLinear = cinematicACESTonemap(hdrColor);

    // 4. Convert to sRGB & Apply Cinematic Color Grading
    vec3 srgbColor = toSRGB(tonemappedLinear);
    srgbColor = applyCinematicGrading(srgbColor);

    // 5. Subtle Cinematic Vignette
    vec2 vigUV = vTexCoord * (1.0 - vTexCoord.yx);
    float vig = clamp(pow(vigUV.x * vigUV.y * 16.0, 0.14), 0.82, 1.0);
    srgbColor *= vig;

    outScreenColor = vec4(srgbColor, 1.0);
}

