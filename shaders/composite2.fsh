#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"
#include "/lib/ssgi_bounce.glsl"
#include "/lib/volumetric.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D depthtex0;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;
uniform float near;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform int isEyeInWater;
uniform int frameCounter;
uniform float nightVision;

in vec2 vTexCoord;

/* RENDERTARGETS: 3 */
layout(location = 0) out vec4 outFinalHDR;

void main() {
    vec4 c0 = texture(colortex0, vTexCoord);
    vec4 c1 = texture(colortex1, vTexCoord);
    vec4 c2 = texture(colortex2, vTexCoord);
    vec4 directData = texture(colortex3, vTexCoord);
    vec4 temporalState = texture(colortex5, vec2(0.25, 0.25));
    float depth = texture(depthtex0, vTexCoord).r;

    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));
    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);
    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    vec3 viewPos   = screenToView(vTexCoord, depth, gbufferProjectionInverse);
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 lightVecView = normalize(shadowLightPosition);

    float smoothHeldIntensity = temporalState.r;
    vec3 smoothHeldColor = temporalState.gba;

    // Sky pixels: apply volumetric light shafts directly to sky
    if (depth >= 0.9999) {
        vec3 skyVol = applyVolumetricFogAndLightShafts(
            directData.rgb, viewPos, playerPos, lightVecView,
            0.0, 1.0, COLOR_TORCH_WARM, smoothHeldIntensity, smoothHeldColor,
            rainStrength, isEyeInWater, dither, atm,
            shadowtex0, shadowtex1, shadowcolor0, shadowModelView, shadowProjection
        );
        outFinalHDR = vec4(skyVol, 1.0);
        return;
    }

    vec3 albedoLinear = toLinear(c0.rgb);
    float matId       = c0.a;
    vec3 viewNormal   = decodeNormal(c1.rg);
    float blockLight  = c1.b;
    float skyLight    = c1.a;
    float vanillaAO   = c2.a;

    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);
    float linDepth   = linearizeDepth(depth, near, far);
    vec2 texelSize   = vec2(1.0 / max(viewWidth, 1.0), 1.0 / max(viewHeight, 1.0));

    // 1. Cross-Bilateral Denoised SSGI Indirect Bounce & Ambient Occlusion
    vec4 ssgiFiltered = sampleBilateralSSGI(
        vTexCoord, viewNormal, linDepth, texelSize,
        colortex4, colortex1, depthtex0, near, far
    );
    vec3 indirectBounce = ssgiFiltered.rgb;
    float ssao = ssgiFiltered.a;
    float combinedAO = ssao * vanillaAO;

    // 2. Non-Crushing Hemispherical Skylight + Ground Bounce + Cave Minimum Floor
    float hemiUp = worldNormal.y * 0.5 + 0.5;
    vec3 skyHemisphere = mix(
        atm.groundBounce * GROUND_BOUNCE_STRENGTH,
        atm.skyZenith * 0.62 + atm.skyHorizon * 0.42,
        hemiUp
    ) * SKY_AMBIENT_INTENSITY;

    float outdoorSkyFactor = pow(skyLight, 1.45);
    vec3 outdoorAmbient = skyHemisphere * outdoorSkyFactor;

    // Atmospheric minimum cave ambient (prevents pitch-black shadows while preserving 3D form)
    float directionalForm = 0.72 + 0.28 * hemiUp;
    vec3 caveFloorAmbient = vec3(0.76, 0.85, 1.00) * MIN_CAVE_BRIGHTNESS * directionalForm;
    if (nightVision > 0.01) {
        caveFloorAmbient += vec3(0.22, 0.28, 0.24) * nightVision;
    }

    vec3 totalAmbient = max(outdoorAmbient, caveFloorAmbient) * combinedAO;

    // 3. Screen-Space Reflections (SSR)
    vec4 ssr = texture(colortex6, vTexCoord);

    // Combine Direct + Indirect SSGI Bounce + Hemispheric Ambient + SSR
    vec3 surfaceColor = directData.rgb * mix(1.0, ssao, 0.45)
                      + albedoLinear * (totalAmbient + indirectBounce * combinedAO)
                      + ssr.rgb;

    // 4. Local Blocklight Color for Colored Fog Tinting
    // Estimate local light tint from SSGI bounce + blocklight temperature
    vec3 localFogLightColor = getEmissiveColorFromMat(matId, blockLight);
    if (dot(indirectBounce, indirectBounce) > 0.001) {
        vec3 bounceChroma = indirectBounce / max(getLuminance(indirectBounce), 0.01);
        localFogLightColor = mix(localFogLightColor, clamp(bounceChroma, vec3(0.1), vec3(1.5)), 0.55);
    }

    // 5. Apply Colored Volumetric Fog & Sunlight Shafts
    vec3 finalHDR = applyVolumetricFogAndLightShafts(
        surfaceColor, viewPos, playerPos, lightVecView,
        blockLight, skyLight, localFogLightColor,
        smoothHeldIntensity, smoothHeldColor,
        rainStrength, isEyeInWater, dither, atm,
        shadowtex0, shadowtex1, shadowcolor0, shadowModelView, shadowProjection
    );

    outFinalHDR = vec4(max(finalHDR, vec3(0.0)), 1.0);
}

