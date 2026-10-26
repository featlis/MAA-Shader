#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"
#include "/lib/shadow_filter.glsl"
#include "/lib/blocklight_dir.glsl"

/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA16F;
const int colortex2Format = RGBA8;
const int colortex3Format = RGBA16F;
const int colortex4Format = RGBA16F;
const int colortex5Format = RGBA16F;
const int colortex6Format = RGBA16F;
const int colortex7Format = RGBA16F;
const bool colortex5Clear = false;
*/

const int shadowMapResolution = 2048; // [1024 1536 2048 3072 4096]
const float shadowDistance = 128.0; // [64.0 96.0 128.0 160.0 192.0 256.0]
const float sunPathRotation = -25.0;
const float shadowIntervalSize = 2.0;
const bool generateShadowMipmap = false;
const bool shadowHardwareFiltering = false;

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex5;
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
uniform float frameTime;
uniform int frameCounter;
uniform int heldItemId;
uniform int heldItemId2;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

in vec2 vTexCoord;

/* DRAWBUFFERS:35 */

void main() {
    // 1. Update Smooth Handheld Dynamic Light State (Temporal Exponential Smoothing)
    int rawHeld1 = max(heldBlockLightValue, 0);
    int rawHeld2 = max(heldBlockLightValue2, 0);
    float targetHeldIntensity = clamp(float(max(rawHeld1, rawHeld2)) / 15.0, 0.0, 1.0);
    int activeItemId = (rawHeld1 >= rawHeld2) ? heldItemId : heldItemId2;
    vec3 targetHeldColor = getHeldItemLightColor(activeItemId);

    vec4 prevState = texture(colortex5, vec2(0.25, 0.25));
    float prevIntensity = prevState.r;
    vec3 prevColor = prevState.gba;

    if (isnan(prevIntensity) || isinf(prevIntensity) || prevIntensity < 0.0 || prevIntensity > 2.0) {
        prevIntensity = targetHeldIntensity;
        prevColor = targetHeldColor;
    }
    if (dot(prevColor, prevColor) < 0.001) {
        prevColor = targetHeldColor;
    }

    float dt = clamp(frameTime, 0.001, 0.1);
    float lerpFactor = clamp(1.0 - exp(-dt * HANDLIGHT_SMOOTH_SPEED), 0.01, 1.0);
    float smoothHeldIntensity = mix(prevIntensity, targetHeldIntensity, lerpFactor);
    vec3 smoothHeldColor = mix(prevColor, targetHeldColor, lerpFactor);

    gl_FragData[1] = vec4(smoothHeldIntensity, smoothHeldColor);

    // 2. Sample G-Buffers
    vec4 c0 = texture(colortex0, vTexCoord);
    vec4 c1 = texture(colortex1, vTexCoord);
    vec4 c2 = texture(colortex2, vTexCoord);
    float depth = texture(depthtex0, vTexCoord).r;

    vec3 albedoLinear = toLinear(c0.rgb);
    float matId = c2.a;

    // Sky pass-through
    if (depth >= 0.9999) {
        gl_FragData[0] = vec4(albedoLinear, 1.0);
        return;
    }

    vec3 viewNormal  = decodeNormal(c1.rg);
    float blockLight = c1.b;
    float skyLight   = c1.a;

    float smoothness = c2.r;
    float f0         = c2.g;
    float emission   = c2.b;

    vec3 viewPos   = screenToView(vTexCoord, depth, gbufferProjectionInverse);
    vec3 playerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);

    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));
    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    // 3. Direct Celestial Lighting (Sun / Moon) + Contact-Hardening Shadows
    vec3 lightDirView = normalize(shadowLightPosition);
    float rawNoL = dot(viewNormal, lightDirView);
    float NoL = max(rawNoL, 0.0);

    float subsurface = 0.0;
    if (isMaterial(matId, MAT_FOLIAGE)) {
        subsurface = max(-rawNoL, 0.0) * 0.55 + 0.20;
        NoL = max(NoL, 0.25);
    }

    vec3 sunShadow = vec3(0.0);
    if ((NoL > 0.001 || subsurface > 0.001) && skyLight > 0.01) {
        if (isMaterial(matId, MAT_HAND)) {
            sunShadow = vec3(smoothstep(0.1, 0.6, skyLight));
        } else {
            sunShadow = sampleDirectionalShadow(
                playerPos, worldNormal, max(NoL, 0.15), dither,
                shadowtex0, shadowtex1, shadowcolor0,
                shadowModelView, shadowProjection
            );
            sunShadow *= smoothstep(0.02, 0.35, skyLight);
        }
    }

    sunShadow = mix(sunShadow, vec3(0.45), rainStrength * 0.75);

    vec3 directDiffuse = atm.directLight * sunShadow * (NoL + subsurface * vec3(0.95, 1.05, 0.65));

    // Direct Sun/Moon Specular Reflection
    vec3 V = normalize(-viewPos);
    vec3 H = normalize(lightDirView + V);
    float NoH = max(dot(viewNormal, H), 0.0);
    float VoH = max(dot(V, H), 0.0);
    float specPower = exp2(4.5 + smoothness * 8.0);
    float sunSpecTerm = ((specPower + 2.0) * 0.125) * pow(NoH, specPower) * fresnelSchlickScalar(VoH, f0);
    vec3 directSpecular = atm.directLight * sunShadow * sunSpecTerm * NoL * smoothness * SPECULAR_STRENGTH;

    // 4. Directional Blocklight & Tube Occlusion
    BlocklightResult blk = computeDirectionalBlocklight(
        viewPos, viewNormal, vTexCoord, blockLight, smoothness, f0, dither,
        colortex2, colortex1, depthtex0, gbufferProjection, gbufferProjectionInverse
    );

    // 5. Smooth Handheld Dynamic Light (Point + Spotlight Cone)
    vec3 handDiffuse = vec3(0.0);
    vec3 handSpecular = vec3(0.0);
    computeHandheldLight(
        viewPos, viewNormal, smoothHeldIntensity, smoothHeldColor, smoothness, f0, dither,
        depthtex0, gbufferProjection, gbufferProjectionInverse,
        handDiffuse, handSpecular
    );

    // 6. Emissive Surface Radiance
    vec3 emissiveRadiance = vec3(0.0);
    if (emission > 0.01) {
        vec3 eTint = getEmissiveColorFromMat(matId, 1.0);
        emissiveRadiance = mix(albedoLinear, albedoLinear * eTint * 1.4, 0.65) * emission * 3.2;
    }

    vec3 specTint = isMaterial(matId, MAT_METALLIC) ? mix(vec3(1.0), albedoLinear * 1.35, 0.75) : vec3(1.0);

    vec3 totalDirect = albedoLinear * (directDiffuse + blk.diffuse + handDiffuse)
                     + (directSpecular + blk.specular + handSpecular) * specTint
                     + emissiveRadiance;

    gl_FragData[0] = vec4(max(totalDirect, vec3(0.0)), blk.directionalOcclusion);
}
