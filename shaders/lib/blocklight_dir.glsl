#ifndef BLOCKLIGHT_DIR_GLSL
#define BLOCKLIGHT_DIR_GLSL

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

// 8-direction symmetric compass for Stage 1 gradient & close-range detection
const vec2 COMPASS_DIRS[8] = vec2[8](
    vec2( 1.0000,  0.0000),
    vec2( 0.7071,  0.7071),
    vec2( 0.0000,  1.0000),
    vec2(-0.7071,  0.7071),
    vec2(-1.0000,  0.0000),
    vec2(-0.7071, -0.7071),
    vec2( 0.0000, -1.0000),
    vec2( 0.7071, -0.7071)
);

struct BlocklightResult {
    vec3 diffuse;
    vec3 specular;
    vec3 lightColor;
    vec3 lightDirView;
    float directionalOcclusion;
};

// Helper to inspect a screen-space UV sample for emissive blocks & stained glass transmission
// Uses a smooth radial disk window + 3D distance window + midpoint occlusion so zero square patches ever appear!
void accumulateSampleColor(
    vec2 centerUV,
    vec2 sampleUV,
    float diskWindow,
    vec3 viewPos,
    float rawBlockLight,
    sampler2D colortex0,
    sampler2D colortex1,
    sampler2D colortex2,
    sampler2D colortex6,
    sampler2D colortex7,
    sampler2D depthTex0,
    sampler2D depthTex1,
    mat4 projInv,
    inout vec3 emitterColorAccum,
    inout float emitterWeight,
    inout vec3 stainedGlassColorAccum,
    inout float stainedGlassWeight,
    inout bool hasFlameSource,
    inout bool foundExplicitEmitter
) {
    if (sampleUV.x <= 0.002 || sampleUV.x >= 0.998 ||
        sampleUV.y <= 0.002 || sampleUV.y >= 0.998) {
        return;
    }

    float nDepth = texture(depthTex0, sampleUV).r;
    if (nDepth >= 0.9999) return;

    vec3 nViewPos = screenToView(sampleUV, nDepth, projInv);
    vec3 deltaPos = nViewPos - viewPos;
    float dist3D  = length(deltaPos);

    if (dist3D <= 0.015 || dist3D >= 4.0) return;

    // Smooth continuous 3D distance falloff bounded strictly to [0.0, 1.0]
    float distWindow = smoothstep(4.0, 0.35, dist3D) * smoothstep(4.0, 1.10, dist3D);

    // Smooth 3D line-of-sight midpoint depth check prevents bleeding through solid walls
    vec2 midUV = mix(centerUV, sampleUV, 0.5);
    float midOpaqueDepth = texture(depthTex1, midUV).r;
    float losWeight = 1.0;
    if (midOpaqueDepth < 0.9999) {
        vec3 midViewPos = screenToView(midUV, midOpaqueDepth, projInv);
        float expectedMidZ = 0.5 * (viewPos.z + nViewPos.z);
        float zProtrusion = midViewPos.z - expectedMidZ;
        losWeight = smoothstep(0.42, 0.06, zProtrusion);
    }

    // Strictly bound each tap to <= 1/16 so a single tap NEVER creates a step silhouette
    float tapW = clamp(distWindow * losWeight * diskWindow, 0.0, 1.0) * (1.0 / 16.0);
    if (tapW <= 0.0001) return;

    vec4 nData   = texture(colortex1, sampleUV);
    float nLight = nData.b;
    vec4 nMatSpec = texture(colortex2, sampleUV);
    float nEmit  = nMatSpec.b;
    float nMat   = nMatSpec.a;
    vec4 nOpaque = texture(colortex7, sampleUV);
    float nOpaqueMat = nOpaque.a;

    // Case 1: Stained Glass (either covering an emitter in colortex7, or strongly lit by an adjacent emitter)
    if (isMaterial(nMat, MAT_STAINED_GLASS)) {
        vec3 pureGlassLinear = toLinear(texture(colortex6, sampleUV).rgb);
        bool emitterBehindGlass = isEmissiveMaterial(nOpaqueMat);

        if (emitterBehindGlass) {
            foundExplicitEmitter = true;
            stainedGlassColorAccum += pureGlassLinear * tapW;
            stainedGlassWeight += tapW;
        } else if (nLight > 0.45) {
            float gW = smoothstep(0.45, 0.92, nLight) * tapW * 0.75;
            stainedGlassColorAccum += pureGlassLinear * gW;
            stainedGlassWeight += gW;
        }
    }
    // Case 2: Colored specialty emitters (Soul Fire, Redstone, End Rod);
    // Bare white/warm blocks (Sea Lantern, Glowstone, Torch) use the 100% uniform lightmap curve so grass under Sea Lanterns never turns neon green!
    else if (isEmissiveMaterial(nMat)) {
        foundExplicitEmitter = true;
        if (isMaterial(nMat, MAT_EMISSIVE_WARM) || isMaterial(nMat, MAT_EMISSIVE_SOUL) || isMaterial(nMat, MAT_EMISSIVE_LAVA)) {
            hasFlameSource = true;
        }
        if (isMaterial(nMat, MAT_EMISSIVE_SOUL) || isMaterial(nMat, MAT_EMISSIVE_RED) || isMaterial(nMat, MAT_EMISSIVE_END)) {
            vec3 nTexLinear = toLinear(texture(colortex0, sampleUV).rgb);
            vec3 eCol = getEmissiveColorFromMatAndTex(nMat, nTexLinear, 1.0);
            float emitSoft = smoothstep(0.05, 0.75, nEmit) * 0.75 + 0.25;
            float w = tapW * emitSoft;
            emitterColorAccum += eCol * w;
            emitterWeight += w;
        }
    }
}

BlocklightResult computeDirectionalBlocklight(
    vec3 viewPos,
    vec3 worldPos,
    vec3 viewNormal,
    vec2 texCoord,
    vec3 surfaceAlbedoLinear,
    float rawBlockLight,
    float smoothness,
    float f0,
    float matId,
    float frameTimeCounter,
    float dither,
    sampler2D colortex0,
    sampler2D colortex1,
    sampler2D colortex2,
    sampler2D colortex6,
    sampler2D colortex7,
    sampler2D depthTex0,
    sampler2D depthTex1,
    mat4 proj,
    mat4 projInv
) {
    BlocklightResult res;
    res.diffuse = vec3(0.0);
    res.specular = vec3(0.0);
    res.lightColor = getEmissiveColorFromMat(MAT_EMISSIVE_WARM, rawBlockLight);
    res.lightDirView = viewNormal;
    res.directionalOcclusion = 1.0;

    if (rawBlockLight <= 0.004) {
        return res;
    }

    bool isReceiverTranslucent = isMaterial(matId, MAT_STAINED_GLASS) ||
                                 isMaterial(matId, MAT_GLASS) ||
                                 isMaterial(matId, MAT_WATER);

    float distMeters = (1.0 - rawBlockLight) * 15.0;
    float invSquare = 1.0 / (1.0 + 0.20 * distMeters * distMeters);
    float rangeWindow = smoothstep(0.0, 0.16, rawBlockLight) * pow(rawBlockLight, BLOCKLIGHT_DISTANCE_FALLOFF * 0.60);
    float coreDefinition = 1.0 + smoothstep(0.58, 0.96, rawBlockLight) * 0.90;
    float physicalAtten = invSquare * rangeWindow * coreDefinition * BLOCKLIGHT_INTENSITY * 1.45;

    vec3 gradAccum3D = vec3(0.0);
    vec3 emitterColorAccum = vec3(0.0);
    float emitterWeight = 0.0;
    vec3 stainedGlassColorAccum = vec3(0.0);
    float stainedGlassWeight = 0.0;
    bool hasFlameSource = false;
    bool foundExplicitEmitter = false;

    float viewDist = max(length(viewPos), 1.0);
    float radiusScale = 1.0 / clamp(viewDist * 0.09, 0.45, 2.2);
    vec2 aspectVec = vec2(1.0, 1.77);

    // 1. Compute smooth coplanar 3D tangent gradient purely from coplanar neighbors
    // (Strictly ignores elevated blocks, foliage, and cliffs so block silhouettes NEVER appear in NoL!)
    for (int i = 0; i < 8; i++) {
        vec2 dir2D = COMPASS_DIRS[i] * aspectVec;
        vec2 gUV = clamp(texCoord + dir2D * (0.010 * radiusScale), vec2(0.002), vec2(0.998));
        float gDepth = texture(depthTex0, gUV).r;
        if (gDepth < 0.9999) {
            vec3 gViewPos = screenToView(gUV, gDepth, projInv);
            vec3 dPos = gViewPos - viewPos;
            float d3D = length(dPos);
            if (d3D > 0.01 && d3D < 1.5) {
                vec4 gData = texture(colortex1, gUV);
                vec3 gNormal = decodeNormal(gData.rg);
                float gLight = gData.b;
                float coplanarW = smoothstep(0.08, 0.01, abs(dot(dPos, viewNormal))) *
                                  smoothstep(0.85, 0.98, dot(gNormal, viewNormal));
                float lDiff = gLight - rawBlockLight;
                gradAccum3D += (dPos / d3D) * (lDiff * coplanarW);
            }
        }
    }
    // Project strictly into surface tangent plane so NoL is 100% invariant on flat floors/walls
    gradAccum3D -= viewNormal * dot(gradAccum3D, viewNormal);

    // 2. Stratified 16-Tap Golden-Ratio Vogel Disk with Full 2D Jitter & Cubic Window
    float radialJitter = fract(dither * 1.6180339887);
    float diskAngleJitter = dither * (2.0 * PI);
    float maxDiskRadius = 0.095 * radiusScale;
    for (int k = 0; k < 16; k++) {
        float fk = (float(k) + radialJitter) / 16.0;
        float r = sqrt(fk) * maxDiskRadius;
        float theta = float(k) * 2.39996323 + diskAngleJitter;
        vec2 offset2D = vec2(cos(theta), sin(theta)) * aspectVec * r;
        float oneMinusFk = 1.0 - fk;
        float diskWindow = oneMinusFk * oneMinusFk * oneMinusFk;

        accumulateSampleColor(
            texCoord, texCoord + offset2D, diskWindow, viewPos, rawBlockLight,
            colortex0, colortex1, colortex2, colortex6, colortex7, depthTex0, depthTex1, projInv,
            emitterColorAccum, emitterWeight,
            stainedGlassColorAccum, stainedGlassWeight, hasFlameSource, foundExplicitEmitter
        );
    }

    // Resolve base emitter light color with smooth regularization
    vec3 defaultWarmColor = getEmissiveColorFromMat(MAT_EMISSIVE_WARM, rawBlockLight);
    vec3 targetColor = defaultWarmColor;
    if (emitterWeight > 0.0005) {
        vec3 avgEmitterColor = emitterColorAccum / emitterWeight;
        float emitterConfidence = smoothstep(0.0, 0.18, emitterWeight);
        targetColor = mix(defaultWarmColor, avgEmitterColor, emitterConfidence);
    }

    // Smoothly apply stained glass color tint if stained glass is near/in front of the light source
    if (stainedGlassWeight > 0.0005) {
        vec3 avgGlassLinear = stainedGlassColorAccum / stainedGlassWeight;
        float glassInfluence = smoothstep(0.0, 0.16, stainedGlassWeight) * 0.88;
        targetColor = tintLightByStainedGlass(targetColor, avgGlassLinear, glassInfluence);
    }

    // If the receiver itself is stained glass, tint its own transmitted blocklight by its pure glass color
    if (isMaterial(matId, MAT_STAINED_GLASS)) {
        vec3 selfGlassLinear = toLinear(texture(colortex6, texCoord).rgb);
        targetColor = tintLightByStainedGlass(targetColor, selfGlassLinear, 0.88);
    }

    // Distant atmospheric light scintillation & natural flame flicker
    float shimmer = computeLightShimmer(worldPos, viewDist, frameTimeCounter, hasFlameSource || !foundExplicitEmitter);
    physicalAtten *= shimmer;

    #ifdef DIRECTIONAL_BLOCKLIGHT
    float gradMag = length(gradAccum3D);
    if (gradMag > 0.002 && !isReceiverTranslucent) {
        vec3 tangentDir = gradAccum3D / gradMag;
        float tangentBlend = smoothstep(0.002, 0.045, gradMag) * 0.62;
        res.lightDirView = normalize(mix(viewNormal, normalize(viewNormal * 0.72 + tangentDir * 0.69), tangentBlend));
    }
    #endif

    // Preserve continuous reflected surface luminance so emitter/glass detection NEVER stamps
    // bright green or dark polygonal patches onto grass/terrain under light sources!
    vec3 safeAlbedo = max(surfaceAlbedoLinear, vec3(0.06));
    float baseReflectedLuma   = getLuminance(safeAlbedo * defaultWarmColor);
    float targetReflectedLuma = max(getLuminance(safeAlbedo * targetColor), 0.001);
    float lumaScale = clamp(baseReflectedLuma / targetReflectedLuma, 0.42, 2.10);
    res.lightColor = targetColor * mix(1.0, lumaScale, isReceiverTranslucent ? 0.0 : 0.90);

    // Translucent glass/water: keep pane interior crystal-clear and see-through (never an opaque pink block!)
    if (isReceiverTranslucent) {
        res.directionalOcclusion = 1.0;
        float glassAlpha = isMaterial(matId, MAT_STAINED_GLASS) ? texture(colortex6, texCoord).a : 0.20;
        float glassScatter = 0.08 + glassAlpha * 0.24;
        res.diffuse = res.lightColor * physicalAtten * glassScatter;

        vec3 V = normalize(-viewPos);
        vec3 specL = normalize(mix(viewNormal, res.lightDirView, 0.65));
        vec3 dummyDiff = vec3(0.0);
        vec3 glassSpec = vec3(0.0);
        evaluatePBRSurface(
            viewNormal, V, specL, surfaceAlbedoLinear,
            smoothness, f0, matId,
            dummyDiff, glassSpec
        );
        res.specular = res.lightColor * physicalAtten * glassSpec * 0.45;
        return res;
    }

    vec3 V = normalize(-viewPos);
    vec3 pbrDiffuse = vec3(0.0);
    vec3 pbrSpecular = vec3(0.0);

    // Bias diffuse light vector toward surface normal to account for 1m^3 voxel emitter height on floors/walls
    vec3 diffuseL = normalize(mix(viewNormal, res.lightDirView, 0.38));
    vec3 specL    = normalize(mix(viewNormal, res.lightDirView, 0.72));
    evaluatePBRSurface(
        viewNormal, V, diffuseL, surfaceAlbedoLinear,
        smoothness, f0, matId,
        pbrDiffuse, pbrSpecular
    );
    vec3 dummyDiff = vec3(0.0);
    evaluatePBRSurface(
        viewNormal, V, specL, surfaceAlbedoLinear,
        smoothness, f0, matId,
        dummyDiff, pbrSpecular
    );

    vec3 radiance = res.lightColor * physicalAtten * res.directionalOcclusion;
    res.diffuse  = radiance * max(pbrDiffuse, vec3(0.32 * (1.0 - f0)));
    res.specular = radiance * pbrSpecular;

    return res;
}

// ============================================================================
// Smooth Handheld Dynamic Light (Point Light + Spotlight Cone + Contact Shadow)
// ============================================================================
void computeHandheldLight(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 surfaceAlbedoLinear,
    float smoothHeldIntensity,
    vec3 heldLightColor,
    float smoothness,
    float f0,
    float matId,
    sampler2D depthTex0,
    sampler2D depthTex1,
    sampler2D colortex2,
    sampler2D colortex6,
    mat4 proj,
    mat4 projInv,
    out vec3 outDiffuse,
    out vec3 outSpecular
) {
    outDiffuse = vec3(0.0);
    outSpecular = vec3(0.0);

    if (smoothHeldIntensity <= 0.002 || HANDLIGHT_INTENSITY <= 0.001) {
        return;
    }

    vec3 handPosView = vec3(0.16, -0.14, -0.15);
    vec3 toLight = handPosView - viewPos;
    float dist = length(toLight);

    if (dist >= HANDLIGHT_RANGE || dist < 0.001) {
        return;
    }

    vec3 L = toLight / dist;
    bool isReceiverTranslucent = isMaterial(matId, MAT_STAINED_GLASS) ||
                                 isMaterial(matId, MAT_GLASS) ||
                                 isMaterial(matId, MAT_WATER);
    float rawNoL = isReceiverTranslucent ? abs(dot(viewNormal, L)) : dot(viewNormal, L);
    float wrappedNoL = clamp((rawNoL + 0.32) / 1.32, 0.0, 1.0);
    if (wrappedNoL <= 0.001) {
        return;
    }

    float distNorm = clamp(dist / HANDLIGHT_RANGE, 0.0, 1.0);
    float window = clamp(1.0 - distNorm * distNorm * distNorm * distNorm, 0.0, 1.0);
    window *= window;

    vec3 lightToSurface = -L;
    float spotCos = dot(lightToSurface, vec3(0.0, 0.0, -1.0));
    float spotCone = smoothstep(SPOTLIGHT_OUTER_COS, SPOTLIGHT_INNER_COS, spotCos);
    float spotProfile = pow(spotCone, 1.25) * 2.05;

    float pointAtten = (1.75 / (1.0 + 0.30 * dist * dist)) * window;
    float spotAtten  = (2.65 / (1.0 + 0.13 * dist * dist)) * window * spotProfile;

    float angularAtten;
    #if HANDLIGHT_MODE == 1
        angularAtten = pointAtten;
    #elif HANDLIGHT_MODE == 2
        angularAtten = spotAtten + pointAtten * 0.10;
    #else
        angularAtten = mix(pointAtten * 0.72, spotAtten, 0.58);
    #endif

    float contactShadow = 1.0;
    vec3 activeLightColor = heldLightColor;
    vec3 rayStep = L * min(dist * 0.22, 0.45);
    vec3 rayPos = viewPos + viewNormal * 0.04;
    for (int i = 0; i < 4; i++) {
        rayPos += rayStep * 0.85;
        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x > 0.002 && sc.x < 0.998 && sc.y > 0.002 && sc.y < 0.998) {
            float sMat = texture(colortex2, sc.xy).a;
            if (isMaterial(sMat, MAT_STAINED_GLASS)) {
                float dAll = texture(depthTex0, sc.xy).r;
                vec3 gPosAll = screenToView(sc.xy, dAll, projInv);
                float gWin = smoothstep(0.48, 0.08, abs(gPosAll.z - rayPos.z));
                if (gWin > 0.001) {
                    vec3 pureG = toLinear(texture(colortex6, sc.xy).rgb);
                    activeLightColor = tintLightByStainedGlass(activeLightColor, pureG, 0.78 * gWin);
                }
            } else if (!isMaterial(sMat, MAT_GLASS) && !isReceiverTranslucent) {
                float dOpaque = texture(depthTex1, sc.xy).r;
                vec3 gPos = screenToView(sc.xy, dOpaque, projInv);
                float diff = gPos.z - rayPos.z;
                float prot = dot(gPos - viewPos, viewNormal);
                float cWin = smoothstep(0.03, 0.12, diff) * smoothstep(0.58, 0.25, diff) * smoothstep(0.08, 0.26, prot);
                contactShadow *= mix(1.0, 0.55, cWin);
            }
        }
    }

    vec3 V = normalize(-viewPos);
    vec3 effectiveL = normalize(mix(viewNormal, L, 0.75));
    vec3 pbrDiffuse = vec3(0.0);
    vec3 pbrSpecular = vec3(0.0);
    evaluatePBRSurface(
        viewNormal, V, effectiveL, surfaceAlbedoLinear,
        smoothness, f0, matId,
        pbrDiffuse, pbrSpecular
    );

    vec3 handRadiance = activeLightColor * (smoothHeldIntensity * HANDLIGHT_INTENSITY * angularAtten * contactShadow * wrappedNoL);
    outDiffuse  = handRadiance * pbrDiffuse;
    outSpecular = handRadiance * pbrSpecular * max(rawNoL, 0.0);
}

#endif // BLOCKLIGHT_DIR_GLSL
