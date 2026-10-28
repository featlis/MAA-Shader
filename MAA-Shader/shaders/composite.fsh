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
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

uniform vec3 cameraPosition;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;
uniform float frameTime;
uniform float frameTimeCounter;
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
    vec4 opaqueBg = texture(colortex7, vTexCoord);
    float depth = texture(depthtex0, vTexCoord).r;

    vec3 albedoLinear = toLinear(c0.rgb);
    float matId = c2.a;
    float opaqueMatId = opaqueBg.a;

    // Sky pass-through (preserve subtle star emission stored in c2.b)
    if (depth >= 0.9999) {
        vec3 skyHDR = albedoLinear * (1.0 + c2.b * 0.55);
        gl_FragData[0] = vec4(skyHDR, 1.0);
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
    vec3 worldPos  = playerPos + cameraPosition;
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);

    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));
    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    // 3. Direct Celestial Lighting (Sun / Moon) + Contact-Hardening & Stained Glass Shadows
    vec3 lightDirView = normalize(shadowLightPosition);
    float rawNoL = dot(viewNormal, lightDirView);
    float NoL = max(rawNoL, 0.0);

    bool isTranslucent = isMaterial(matId, MAT_STAINED_GLASS) ||
                         isMaterial(matId, MAT_GLASS) ||
                         isMaterial(matId, MAT_WATER);

    float subsurface = 0.0;
    if (isMaterial(matId, MAT_FOLIAGE)) {
        subsurface = max(-rawNoL, 0.0) * 0.55 + 0.18;
        NoL = max(NoL, 0.22);
    } else if (isTranslucent) {
        // Translucent glass/water is lit from both front and back
        NoL = max(abs(rawNoL), 0.35);
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
            sunShadow *= smoothstep(0.02, 0.32, skyLight);
        }
    }

    sunShadow = mix(sunShadow, vec3(0.45), rainStrength * 0.75);

    // Evaluate Physically-Based Cook-Torrance GGX + Oren-Nayar BRDF for Sun/Moon
    vec3 V = normalize(-viewPos);
    vec3 sunDiffuseBRDF = vec3(0.0);
    vec3 sunSpecularBRDF = vec3(0.0);
    evaluatePBRSurface(
        viewNormal, V, lightDirView, albedoLinear,
        smoothness, f0, matId,
        sunDiffuseBRDF, sunSpecularBRDF
    );
    if (isTranslucent) {
        sunDiffuseBRDF = max(sunDiffuseBRDF, vec3(NoL * 0.65));
    }

    vec3 directDiffuse  = atm.directLight * sunShadow * (sunDiffuseBRDF + subsurface * vec3(0.95, 1.05, 0.65));
    vec3 directSpecular = atm.directLight * sunShadow * sunSpecularBRDF;

    // 4. Directional Blocklight, Tube Occlusion & Stained Glass Transmission
    BlocklightResult blk = computeDirectionalBlocklight(
        viewPos, worldPos, viewNormal, vTexCoord, albedoLinear,
        blockLight, smoothness, f0, matId, frameTimeCounter, dither,
        colortex0, colortex1, colortex2, colortex6, colortex7, depthtex0, depthtex1,
        gbufferProjection, gbufferProjectionInverse
    );

    // 5. Smooth Handheld Dynamic Light (Point + Spotlight Cone + Stained Glass Transmission)
    vec3 handDiffuse = vec3(0.0);
    vec3 handSpecular = vec3(0.0);
    computeHandheldLight(
        viewPos, viewNormal, albedoLinear, smoothHeldIntensity, smoothHeldColor,
        smoothness, f0, matId,
        depthtex0, depthtex1, colortex2, colortex6,
        gbufferProjection, gbufferProjectionInverse,
        handDiffuse, handSpecular
    );

    // 6. Emissive Surface Radiance (Directly on Emitter OR Transmitted Through Translucent Glass!)
    float viewDist = length(viewPos);
    float nightJewelBoost = 1.0 + smoothstep(8.0, 58.0, viewDist) * (0.52 + atm.nightFactor * 0.85);

    vec3 emissiveRadiance = vec3(0.0);
    if (emission > 0.01) {
        vec3 eTint = getEmissiveColorFromMatAndTex(matId, albedoLinear, 1.0);
        bool isFlame = isMaterial(matId, MAT_EMISSIVE_WARM) ||
                       isMaterial(matId, MAT_EMISSIVE_SOUL) ||
                       isMaterial(matId, MAT_EMISSIVE_LAVA);
        float emitterShimmer = computeLightShimmer(worldPos, viewDist, frameTimeCounter, isFlame);
        float coreSparkle = 1.0 + pow(emission, 2.4) * 0.45;
        emissiveRadiance = mix(albedoLinear, albedoLinear * eTint * 1.35, 0.65) * emission * 2.95 * coreSparkle * emitterShimmer * nightJewelBoost;
    } else if (isTranslucent && isEmissiveMaterial(opaqueMatId)) {
        // An emissive light block (e.g. Sea Lantern, Glowstone, Flame) is directly behind Stained/Clear Glass:
        // Preserve the background emitter's inner texture & dark border frame while optically tinting by the glass!
        vec3 bgAlbedoLinear = toLinear(opaqueBg.rgb);
        float bgLuma = getLuminance(bgAlbedoLinear);
        float bgEmitMask = clamp(smoothstep(0.24, 0.80, bgLuma) * 0.88 + 0.08, 0.08, 1.0);
        vec3 bgEmitTint = getEmissiveColorFromMatAndTex(opaqueMatId, bgAlbedoLinear, 1.0);
        float emitterShimmer = computeLightShimmer(worldPos, viewDist, frameTimeCounter, false);
        vec3 rawBgGlow = mix(bgAlbedoLinear, bgAlbedoLinear * bgEmitTint * 1.25, 0.58) * bgEmitMask;

        if (isMaterial(matId, MAT_STAINED_GLASS)) {
            vec4 glassData = texture(colortex6, vTexCoord);
            vec3 pureGlassLinear = toLinear(glassData.rgb);
            float glassAlpha = glassData.a;
            vec3 tintedGlow = tintLightByStainedGlass(rawBgGlow, pureGlassLinear, 0.82) * bgEmitMask;
            // Attenuate along the stained glass frame so both the glass frame and the Sea Lantern panels stay crisp
            emissiveRadiance = mix(rawBgGlow * pureGlassLinear, tintedGlow, 0.65) * (1.0 - glassAlpha * 0.48) * 1.35 * emitterShimmer;
        } else {
            emissiveRadiance = rawBgGlow * 2.10 * emitterShimmer;
        }
    }

    // Lush Foliage Grazing Rim Glow (backlit grass, flowers & leaves catch light around their edges)
    vec3 foliageRim = vec3(0.0);
    if (isMaterial(matId, MAT_FOLIAGE)) {
        float rimFactor = pow(clamp(1.0 - max(dot(viewNormal, V), 0.0), 0.0, 1.0), 2.6);
        foliageRim = albedoLinear * (atm.directLight * sunShadow * 0.35 + blk.diffuse * 0.42) * rimFactor;
    }

    vec3 totalDirect = albedoLinear * (directDiffuse + blk.diffuse + handDiffuse)
                     + (directSpecular + blk.specular + handSpecular)
                     + foliageRim
                     + emissiveRadiance;

    // Store emissiveFlag in alpha so SSGI never re-bounces direct HDR emitters into 4-ray blobs on grass
    float emissiveFlag = (emission > 0.01 || (isTranslucent && isEmissiveMaterial(opaqueMatId))) ? 1.0 : 0.0;
    gl_FragData[0] = vec4(max(totalDirect, vec3(0.0)), emissiveFlag);
}
