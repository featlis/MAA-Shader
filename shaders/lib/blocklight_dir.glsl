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
void accumulateSampleColorAndGrad(
    vec2 sampleUV,
    vec3 viewPos,
    float rawBlockLight,
    sampler2D colortex0,
    sampler2D colortex1,
    sampler2D colortex2,
    sampler2D colortex6,
    sampler2D colortex7,
    sampler2D depthTex0,
    mat4 projInv,
    inout vec3 gradAccum3D,
    inout vec2 gradAccum2D,
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

    vec4 nData   = texture(colortex1, sampleUV);
    float nLight = nData.b;
    float nMat   = texture(colortex2, sampleUV).a;
    vec4 nOpaque = texture(colortex7, sampleUV);
    float nOpaqueMat = nOpaque.a;

    vec3 nViewPos = screenToView(sampleUV, nDepth, projInv);
    vec3 deltaPos = nViewPos - viewPos;
    float dist3D  = length(deltaPos);

    if (dist3D <= 0.015 || dist3D >= 16.0) return;

    vec3 dir3D = deltaPos / dist3D;
    float lightDiff = nLight - rawBlockLight;
    float spatialW = 1.0 / (0.20 + dist3D * 0.45);

    // Case 1: Stained Glass (either covering an emitter in colortex7, or illuminated by a nearby emitter)
    if (isMaterial(nMat, MAT_STAINED_GLASS)) {
        vec3 pureGlassLinear = toLinear(texture(colortex6, sampleUV).rgb);
        bool emitterBehindGlass = isEmissiveMaterial(nOpaqueMat);

        if (emitterBehindGlass) {
            foundExplicitEmitter = true;
            lightDiff = max(lightDiff, 0.65);
            vec3 bgEmitCol = getEmissiveColorFromMatAndTex(nOpaqueMat, toLinear(nOpaque.rgb), 1.0);
            vec3 tintedEmit = tintLightByStainedGlass(bgEmitCol, pureGlassLinear, 0.94);
            float w = 8.0 * spatialW;
            emitterColorAccum += tintedEmit * w;
            emitterWeight += w;
            stainedGlassColorAccum += pureGlassLinear * (w * 1.5);
            stainedGlassWeight += (w * 1.5);
        } else if (nLight > 0.30 && nLight >= rawBlockLight - 0.15) {
            lightDiff = max(lightDiff, 0.25 * nLight);
            float gW = pow(nLight, 1.2) * 5.5 * spatialW;
            stainedGlassColorAccum += pureGlassLinear * gW;
            stainedGlassWeight += gW;
        }
    }
    // Case 2: Direct unobstructed emissive block
    else if (isEmissiveMaterial(nMat)) {
        foundExplicitEmitter = true;
        lightDiff = max(lightDiff, 0.65);
        vec3 nTexLinear = toLinear(texture(colortex0, sampleUV).rgb);
        vec3 eCol = getEmissiveColorFromMatAndTex(nMat, nTexLinear, 1.0);
        float w = 6.0 * spatialW;
        emitterColorAccum += eCol * w;
        emitterWeight += w;

        if (isMaterial(nMat, MAT_EMISSIVE_WARM) || isMaterial(nMat, MAT_EMISSIVE_SOUL) || isMaterial(nMat, MAT_EMISSIVE_LAVA)) {
            hasFlameSource = true;
        }
    }

    float gradWeight = lightDiff / (0.20 + dist3D * 0.40);
    gradAccum3D += dir3D * gradWeight;
}

// Deterministic 3D screen-space raymarch towards the inferred light source:
// - Coplanar walls never self-occlude (fixes dark bands in corridors)
// - Foreground overhangs never stamp ghost silhouettes onto background floors
// - Translucent stained glass (MAT_STAINED_GLASS) tints transmitted light using pure glass color (colortex6)
vec4 traceTubeWallAndGlassOcclusion(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 lightDirView,
    float searchDist,
    sampler2D depthTex0,
    sampler2D depthTex1,
    sampler2D colortex1,
    sampler2D colortex2,
    sampler2D colortex6,
    sampler2D colortex7,
    mat4 proj,
    mat4 projInv
) {
    int steps = BLOCKLIGHT_OCCLUSION_STEPS;
    vec3 startPos = viewPos + viewNormal * 0.06;
    vec3 stepVec = lightDirView * (searchDist / float(steps));

    float visibility = 1.0;
    vec3 glassColorAccum = vec3(0.0);
    float glassHitWeight = 0.0;

    for (int i = 0; i < steps; i++) {
        float t = float(i) + 0.55;
        vec3 rayPos = startPos + stepVec * t;

        vec3 screenPos = viewToScreen(rayPos, proj);
        if (screenPos.x < 0.002 || screenPos.x > 0.998 ||
            screenPos.y < 0.002 || screenPos.y > 0.998) {
            break;
        }

        float allDepth = texture(depthTex0, screenPos.xy).r;
        if (allDepth >= 0.9999) continue;

        float opaqueDepth = texture(depthTex1, screenPos.xy).r;
        float sampleMat = texture(colortex2, screenPos.xy).a;
        float opaqueMat = texture(colortex7, screenPos.xy).a;

        if (isMaterial(sampleMat, MAT_STAINED_GLASS)) {
            vec3 glassViewPos = screenToView(screenPos.xy, allDepth, projInv);
            float glassDepthDiff = abs(glassViewPos.z - rayPos.z);
            float glass3DDist = length(glassViewPos - rayPos);
            if (glassDepthDiff < 0.45 && glass3DDist < 1.25) {
                vec3 pureGlass = toLinear(texture(colortex6, screenPos.xy).rgb);
                glassColorAccum += pureGlass;
                glassHitWeight += 1.0;
            }
            if (isEmissiveMaterial(opaqueMat)) {
                visibility = min(visibility * 1.15, 1.0);
                break;
            }
            continue;
        }

        if (isEmissiveMaterial(sampleMat)) {
            visibility = min(visibility * 1.18, 1.0);
            break;
        }

        if (!isMaterial(sampleMat, MAT_GLASS) && !isMaterial(sampleMat, MAT_WATER) && opaqueDepth < 0.9999) {
            vec3 opaqueViewPos = screenToView(screenPos.xy, opaqueDepth, projInv);
            float depthDelta = opaqueViewPos.z - rayPos.z;

            if (depthDelta > 0.04 && depthDelta < 0.55) {
                float planeProtrusion = dot(opaqueViewPos - viewPos, viewNormal);
                vec3 sampleNormal = decodeNormal(texture(colortex1, screenPos.xy).rg);
                float normalDiff = 1.0 - max(dot(sampleNormal, viewNormal), 0.0);

                if (planeProtrusion > 0.16 && normalDiff > 0.18) {
                    float blockFactor = clamp(planeProtrusion * 2.2, 0.25, 1.0);
                    visibility *= mix(1.0, 0.22, TUBE_OCCLUSION_STRENGTH * blockFactor);
                }
            }
        }
    }

    vec3 outGlass = (glassHitWeight > 0.0) ? (glassColorAccum / glassHitWeight) : vec3(-1.0);
    return vec4(outGlass, clamp(visibility, 0.08, 1.0));
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
    vec2 gradAccum2D = vec2(0.0);
    vec3 emitterColorAccum = vec3(0.0);
    float emitterWeight = 0.0;
    vec3 stainedGlassColorAccum = vec3(0.0);
    float stainedGlassWeight = 0.0;
    bool hasFlameSource = false;
    bool foundExplicitEmitter = false;

    float viewDist = max(length(viewPos), 1.0);
    float radiusScale = 1.0 / clamp(viewDist * 0.08, 0.40, 2.2);
    vec2 aspectVec = vec2(1.0, 1.77);

    // Stage 1: 8-Direction Symmetric Compass (Close + Medium ring) to find exact 2D & 3D light gradient
    for (int i = 0; i < 8; i++) {
        vec2 dir2D = COMPASS_DIRS[i];
        float rUV = ((i % 2 == 0) ? 0.018 : 0.058) * radiusScale;
        vec2 sampleUV = clamp(texCoord + dir2D * aspectVec * rUV, vec2(0.002), vec2(0.998));

        float nLight = texture(colortex1, sampleUV).b;
        float nMat   = texture(colortex2, sampleUV).a;
        float nOpaqueMat = texture(colortex7, sampleUV).a;
        float lDiff  = nLight - rawBlockLight;
        if (isEmissiveMaterial(nMat) || (isMaterial(nMat, MAT_STAINED_GLASS) && isEmissiveMaterial(nOpaqueMat))) {
            lDiff += 0.65;
        }
        gradAccum2D += dir2D * lDiff;

        accumulateSampleColorAndGrad(
            sampleUV, viewPos, rawBlockLight,
            colortex0, colortex1, colortex2, colortex6, colortex7, depthTex0, projInv,
            gradAccum3D, gradAccum2D, emitterColorAccum, emitterWeight,
            stainedGlassColorAccum, stainedGlassWeight, hasFlameSource, foundExplicitEmitter
        );
    }

    // Stage 2: Focused 6-Step Cone March directly along the 2D light gradient (0.04 to 0.42 UV)
    // Guarantees that 1-block windows & emitters are never missed at any distance!
    float grad2DLen = length(gradAccum2D);
    vec2 marchDir2D = (grad2DLen > 0.001) ? (gradAccum2D / grad2DLen) : vec2(0.0, 1.0);
    vec2 perpDir2D  = vec2(-marchDir2D.y, marchDir2D.x);

    for (int s = 1; s <= 6; s++) {
        float fs = float(s) / 6.0;
        float marchUVDist = mix(0.035, 0.42, fs * fs * 0.55 + fs * 0.45) * radiusScale;
        float fanSide = ((s % 2 == 0) ? 1.0 : -1.0) * 0.14 * marchUVDist;
        vec2 rayUV = texCoord + (marchDir2D * marchUVDist + perpDir2D * fanSide) * aspectVec;

        accumulateSampleColorAndGrad(
            rayUV, viewPos, rawBlockLight,
            colortex0, colortex1, colortex2, colortex6, colortex7, depthTex0, projInv,
            gradAccum3D, gradAccum2D, emitterColorAccum, emitterWeight,
            stainedGlassColorAccum, stainedGlassWeight, hasFlameSource, foundExplicitEmitter
        );
    }

    // Resolve base emitter light color
    if (emitterWeight > 0.001) {
        res.lightColor = emitterColorAccum / emitterWeight;
    } else {
        res.lightColor = getEmissiveColorFromMat(MAT_EMISSIVE_WARM, rawBlockLight);
    }

    // Apply stained glass color tint if stained glass is near/in front of the light source
    if (stainedGlassWeight > 0.001) {
        vec3 avgGlassLinear = stainedGlassColorAccum / stainedGlassWeight;
        float glassInfluence = clamp(stainedGlassWeight / (stainedGlassWeight + emitterWeight * 0.25 + 0.25), 0.0, 0.94);
        res.lightColor = tintLightByStainedGlass(res.lightColor, avgGlassLinear, glassInfluence);
    }

    // If the receiver itself is stained glass, tint its own transmitted blocklight by its pure glass color
    if (isMaterial(matId, MAT_STAINED_GLASS)) {
        vec3 selfGlassLinear = toLinear(texture(colortex6, texCoord).rgb);
        res.lightColor = tintLightByStainedGlass(res.lightColor, selfGlassLinear, 0.92);
    }

    // Distant atmospheric light scintillation & natural flame flicker
    float shimmer = computeLightShimmer(worldPos, viewDist, frameTimeCounter, hasFlameSource || !foundExplicitEmitter);
    physicalAtten *= shimmer;

    #ifdef DIRECTIONAL_BLOCKLIGHT
    float gradMag = length(gradAccum3D);
    if (gradMag > 0.006 && !isReceiverTranslucent) {
        vec3 inferredDir = gradAccum3D / gradMag;
        float directionality = clamp(gradMag * 2.8, 0.0, 0.85);
        res.lightDirView = normalize(mix(viewNormal, inferredDir, directionality));

        float searchDist = clamp((1.0 - rawBlockLight) * 5.5 + 0.60, 0.60, 4.2);
        vec4 traceRes = traceTubeWallAndGlassOcclusion(
            viewPos, viewNormal, res.lightDirView, searchDist,
            depthTex0, depthTex1, colortex1, colortex2, colortex6, colortex7, proj, projInv
        );

        if (traceRes.r >= 0.0) {
            res.lightColor = tintLightByStainedGlass(res.lightColor, traceRes.rgb, 0.90);
        }

        float wallVis = traceRes.a;
        float NoL = dot(viewNormal, res.lightDirView);
        // Voxel light blocks have 1x1x1 volume extending 0.5m above flush floors/walls:
        // Do not darken coplanar floors/walls (NoL ~ 0.0); only attenuate back-facing surfaces (NoL < -0.1)
        float directTerm = smoothstep(-0.65, 0.05, NoL) * 0.92 + 0.18;

        float tubeBeamBoost = mix(1.0, 1.35, clamp(gradMag * 1.8, 0.0, 1.0) * smoothstep(0.65, 1.0, wallVis));
        res.directionalOcclusion = mix(1.0, directTerm * wallVis * tubeBeamBoost, directionality * TUBE_OCCLUSION_STRENGTH);
    }
    #endif

    // Translucent glass/water transmits blocklight isotropically from both sides
    if (isReceiverTranslucent) {
        res.directionalOcclusion = 1.0;
        res.diffuse = res.lightColor * physicalAtten * 0.90;
        vec3 V = normalize(-viewPos);
        vec3 H = normalize(res.lightDirView + V);
        float VoH = max(dot(V, H), 0.0);
        res.specular = res.lightColor * physicalAtten * fresnelSchlickScalar(VoH, f0) * 0.40 * SPECULAR_STRENGTH;
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
                if (abs(gPosAll.z - rayPos.z) < 0.45) {
                    vec3 pureG = toLinear(texture(colortex6, sc.xy).rgb);
                    activeLightColor = tintLightByStainedGlass(activeLightColor, pureG, 0.88);
                }
            } else if (!isMaterial(sMat, MAT_GLASS) && !isReceiverTranslucent) {
                float dOpaque = texture(depthTex1, sc.xy).r;
                vec3 gPos = screenToView(sc.xy, dOpaque, projInv);
                float diff = gPos.z - rayPos.z;
                if (diff > 0.04 && diff < 0.55 && dot(gPos - viewPos, viewNormal) > 0.12) {
                    contactShadow *= 0.45;
                }
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
