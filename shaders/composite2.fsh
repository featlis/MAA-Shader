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

/* DRAWBUFFERS:7 */

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
        gl_FragData[0] = vec4(skyVol, 1.0);
        return;
    }

    vec3 albedoLinear = toLinear(c0.rgb);
    float smoothness  = c2.r;
    float f0          = c2.g;
    float matId       = c2.a;
    vec3 viewNormal   = decodeNormal(c1.rg);
    float blockLight  = c1.b;
    float skyLight    = c1.a;

    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);
    float linDepth   = linearizeDepth(depth, near, far);
    vec2 texelSize   = vec2(1.0 / max(viewWidth, 1.0), 1.0 / max(viewHeight, 1.0));

    // 1. Cross-Bilateral Denoised SSGI Indirect Bounce & Ambient Occlusion
    // Uses roughness-aware filter radius (soft diffuse blur on stone, crisp on glossy blocks)
    vec4 ssgiFiltered = sampleBilateralSSGI(
        vTexCoord, viewNormal, linDepth, smoothness, texelSize,
        colortex4, colortex1, depthtex0, near, far
    );
    vec3 indirectBounce = ssgiFiltered.rgb;
    float ssao = ssgiFiltered.a;
    if (isMaterial(matId, MAT_STAINED_GLASS) || isMaterial(matId, MAT_GLASS) || isMaterial(matId, MAT_WATER)) {
        ssao = 1.0;
    }

    // 2. Hemispherical Skylight + Ground Bounce + Crisp Cave Floor
    float hemiUp = worldNormal.y * 0.5 + 0.5;
    vec3 skyHemisphere = mix(
        atm.groundBounce * GROUND_BOUNCE_STRENGTH,
        atm.skyZenith * 0.58 + atm.skyHorizon * 0.38,
        hemiUp
    ) * SKY_AMBIENT_INTENSITY;

    float outdoorSkyFactor = pow(skyLight, 1.55);
    vec3 outdoorAmbient = skyHemisphere * outdoorSkyFactor;

    float directionalForm = 0.68 + 0.32 * hemiUp;
    vec3 caveFloorAmbient = vec3(0.74, 0.84, 1.00) * MIN_CAVE_BRIGHTNESS * directionalForm;
    if (nightVision > 0.01) {
        caveFloorAmbient += vec3(0.20, 0.26, 0.22) * nightVision;
    }

    vec3 totalAmbient = max(outdoorAmbient, caveFloorAmbient) * ssao;

    // 3. Screen-Space Reflections (SSR) with Energy Conservation
    vec4 ssr = texture(colortex6, vTexCoord);
    float kD_env = clamp(1.0 - ssr.a * 0.55, 0.25, 1.0);

    // Combine Direct + Material-Weighted Indirect SSGI Bounce + Hemispheric Ambient + SSR
    vec3 surfaceColor = directData.rgb * mix(1.0, ssao, 0.40)
                      + albedoLinear * (totalAmbient + indirectBounce * ssao) * kD_env
                      + ssr.rgb;

    // 4. Local Blocklight Color for Colored Fog Tinting (never tint fog with terrain/smoke albedo)
    vec3 localFogLightColor = getEmissiveColorFromMat(matId, blockLight);
    float bounceLuma = getLuminance(indirectBounce);
    if (bounceLuma > 0.04) {
        vec3 bounceChroma = indirectBounce / bounceLuma;
        float chromaBlend = smoothstep(0.04, 0.25, bounceLuma) * 0.45;
        localFogLightColor = mix(localFogLightColor, clamp(bounceChroma, vec3(0.15), vec3(1.35)), chromaBlend);
    }

    // 5. Apply Colored Volumetric Fog & Sunlight Shafts
    vec3 finalHDR = applyVolumetricFogAndLightShafts(
        surfaceColor, viewPos, playerPos, lightVecView,
        blockLight, skyLight, localFogLightColor,
        smoothHeldIntensity, smoothHeldColor,
        rainStrength, isEyeInWater, dither, atm,
        shadowtex0, shadowtex1, shadowcolor0, shadowModelView, shadowProjection
    );

    gl_FragData[0] = vec4(max(finalHDR, vec3(0.0)), 1.0);
}
