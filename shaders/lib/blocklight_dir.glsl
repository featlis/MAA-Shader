#ifndef BLOCKLIGHT_DIR_GLSL
#define BLOCKLIGHT_DIR_GLSL

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

// 8-direction unit circle offsets for multi-scale gradient & aperture analysis
const vec2 GRAD_DIRS[8] = vec2[8](
    vec2( 1.000,  0.000),
    vec2( 0.707,  0.707),
    vec2( 0.000,  1.000),
    vec2(-0.707,  0.707),
    vec2(-1.000,  0.000),
    vec2(-0.707, -0.707),
    vec2( 0.000, -1.000),
    vec2( 0.707, -0.707)
);

struct BlocklightResult {
    vec3 diffuse;
    vec3 specular;
    vec3 lightColor;
    vec3 lightDirView;
    float directionalOcclusion;
};

// Screen-space raymarch towards the inferred light source:
// - Opaque walls (depthtex1) occlude light behind tube walls
// - Translucent stained glass (depthtex0 / MAT_STAINED_GLASS) transmits colored light & colored shadow
// Returns: rgb = stained glass color filter, a = scalar visibility [0..1]
vec4 traceTubeWallAndGlassOcclusion(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 lightDirView,
    float searchDist,
    float dither,
    sampler2D depthTex0,
    sampler2D depthTex1,
    sampler2D colortex0,
    sampler2D colortex2,
    mat4 proj,
    mat4 projInv
) {
    int steps = BLOCKLIGHT_OCCLUSION_STEPS;
    vec3 startPos = viewPos + viewNormal * 0.05;
    vec3 stepVec = lightDirView * (searchDist / float(steps));

    float visibility = 1.0;
    vec3 glassFilter = vec3(1.0);

    for (int i = 0; i < steps; i++) {
        float t = float(i) + 0.30 + 0.70 * dither;
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

        // If we hit the emissive light block itself, the path to the light is unobstructed!
        if (isEmissiveMaterial(sampleMat)) {
            visibility = min(visibility * 1.20, 1.0);
            break;
        }

        // Check if stained glass lies along the ray path
        if (isMaterial(sampleMat, MAT_STAINED_GLASS)) {
            vec3 glassViewPos = screenToView(screenPos.xy, allDepth, projInv);
            float glassDelta = glassViewPos.z - rayPos.z;
            if (glassDelta > -0.25 && glassDelta < 1.85) {
                vec3 glassLinear = toLinear(texture(colortex0, screenPos.xy).rgb);
                glassFilter *= getStainedGlassTransmission(glassLinear, 0.75);
                visibility *= 0.88; // Slight glass attenuation (colored shadow)
            }
        } else if (!isMaterial(sampleMat, MAT_GLASS) && opaqueDepth < 0.9999) {
            // Check solid opaque block occlusion (depthtex1)
            vec3 opaqueViewPos = screenToView(screenPos.xy, opaqueDepth, projInv);
            float depthDelta = opaqueViewPos.z - rayPos.z;
            // Solid 1-block tube wall thickness check (0.05m to 1.50m)
            if (depthDelta > 0.05 && depthDelta < 1.50) {
                visibility *= mix(1.0, 0.14, TUBE_OCCLUSION_STRENGTH);
            }
        }
    }

    return vec4(glassFilter, clamp(visibility, 0.05, 1.0));
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

    // Crisp, physically accurate inverse-square attenuation + high-definition core near emitter
    float distMeters = (1.0 - rawBlockLight) * 15.0;
    float invSquare = 1.0 / (1.0 + 0.22 * distMeters * distMeters);
    float rangeWindow = smoothstep(0.0, 0.18, rawBlockLight) * pow(rawBlockLight, BLOCKLIGHT_DISTANCE_FALLOFF * 0.62);
    float coreDefinition = 1.0 + smoothstep(0.60, 0.96, rawBlockLight) * 0.95;
    float physicalAtten = invSquare * rangeWindow * coreDefinition * BLOCKLIGHT_INTENSITY * 1.42;

    // Multi-scale screen-space neighborhood scan to reconstruct:
    // 1. 3D light gradient vector (direction of light propagation)
    // 2. Exact nearby emissive block color (from both material ID and block texture chroma)
    // 3. Stained glass color transmission between emitter and receiving surface
    vec3 gradAccum = vec3(0.0);
    vec3 colorAccum = res.lightColor * 0.25;
    float colorWeight = 0.25;
    vec3 neighborGlassTint = vec3(1.0);
    bool hasFlameSource = true;

    float viewDist = max(length(viewPos), 1.0);
    vec2 shortRadius = vec2(0.0045, 0.0045 * 1.77) / clamp(viewDist * 0.14, 0.45, 3.0);
    vec2 wideRadius  = vec2(0.030,  0.030  * 1.77) / clamp(viewDist * 0.11, 0.40, 2.5);

    float rotAngle = dither * PI * 0.5;
    float s = sin(rotAngle);
    float c = cos(rotAngle);
    mat2 rot = mat2(c, -s, s, c);

    for (int i = 0; i < 8; i++) {
        vec2 dir2D = rot * GRAD_DIRS[i];
        vec2 sampleUV = texCoord + dir2D * ((i % 2 == 0) ? shortRadius : wideRadius);
        sampleUV = clamp(sampleUV, vec2(0.002), vec2(0.998));

        vec4 nData  = texture(colortex1, sampleUV);
        float nLight = nData.b;
        float nMat   = texture(colortex2, sampleUV).a;
        float nDepth = texture(depthTex0, sampleUV).r;

        if (nDepth >= 0.9999) continue;

        vec3 nViewPos = screenToView(sampleUV, nDepth, projInv);
        vec3 deltaPos = nViewPos - viewPos;
        float dist3D  = length(deltaPos);

        if (dist3D > 0.02 && dist3D < 14.0) {
            vec3 dir3D = deltaPos / dist3D;
            float lightDiff = nLight - rawBlockLight;

            if (isEmissiveMaterial(nMat)) {
                lightDiff += 0.65;
                vec3 nTexLinear = toLinear(texture(colortex0, sampleUV).rgb);
                vec3 eCol = getEmissiveColorFromMatAndTex(nMat, nTexLinear, 1.0);
                float w = 4.5 / (0.35 + dist3D);
                colorAccum += eCol * w;
                colorWeight += w;

                if (isMaterial(nMat, MAT_EMISSIVE_AQUA) || isMaterial(nMat, MAT_EMISSIVE_END) ||
                    isMaterial(nMat, MAT_EMISSIVE_RED)  || isMaterial(nMat, MAT_EMISSIVE_GOLD)) {
                    hasFlameSource = false;
                }
            } else if (isMaterial(nMat, MAT_STAINED_GLASS) && nLight >= rawBlockLight - 0.05) {
                // Stained glass sits towards the brighter light direction!
                vec3 gLinear = toLinear(texture(colortex0, sampleUV).rgb);
                vec3 gFilter = getStainedGlassTransmission(gLinear, 0.78);
                neighborGlassTint = mix(neighborGlassTint, gFilter, clamp(1.2 / (0.5 + dist3D), 0.2, 0.85));
            } else if (nLight > rawBlockLight + 0.015) {
                float w = (nLight - rawBlockLight) * 1.4 / (0.6 + dist3D * 0.45);
                colorAccum += getEmissiveColorFromMat(MAT_EMISSIVE_WARM, nLight) * w;
                colorWeight += w;
            }

            float gradWeight = lightDiff / (0.20 + dist3D * 0.40);
            gradAccum += dir3D * gradWeight;
        }
    }

    res.lightColor = (colorAccum / max(colorWeight, 0.001)) * neighborGlassTint;

    // Distant atmospheric light scintillation & natural flame flicker
    float shimmer = computeLightShimmer(worldPos, viewDist, frameTimeCounter, hasFlameSource);
    physicalAtten *= shimmer;

    #ifdef DIRECTIONAL_BLOCKLIGHT
    float gradMag = length(gradAccum);
    if (gradMag > 0.006) {
        vec3 inferredDir = gradAccum / gradMag;
        float directionality = clamp(gradMag * 3.6, 0.0, 0.92);
        res.lightDirView = normalize(mix(viewNormal, inferredDir, directionality));

        float searchDist = clamp((1.0 - rawBlockLight) * 6.8 + 0.65, 0.65, 4.8);
        vec4 traceRes = traceTubeWallAndGlassOcclusion(
            viewPos, viewNormal, res.lightDirView, searchDist,
            dither, depthTex0, depthTex1, colortex0, colortex2, proj, projInv
        );

        res.lightColor *= traceRes.rgb;
        float wallVis = traceRes.a;

        float NoL = dot(viewNormal, res.lightDirView);
        float directTerm = clamp((NoL + 0.22) / 1.22, 0.04, 1.32);

        // Focused beam boost along unobstructed opening of a 4-walled tube
        float tubeBeamBoost = mix(1.0, 1.42, clamp(gradMag * 2.2, 0.0, 1.0) * smoothstep(0.6, 1.0, wallVis));
        res.directionalOcclusion = mix(1.0, directTerm * wallVis * tubeBeamBoost, directionality * TUBE_OCCLUSION_STRENGTH);
    }
    #endif

    // Evaluate Physically-Based Oren-Nayar Diffuse + Cook-Torrance GGX Specular
    vec3 V = normalize(-viewPos);
    vec3 pbrDiffuse = vec3(0.0);
    vec3 pbrSpecular = vec3(0.0);

    // Blend between directional PBR L and hemisphere-wrapped L based on inferred directionality
    vec3 effectiveL = normalize(mix(viewNormal, res.lightDirView, 0.78));
    evaluatePBRSurface(
        viewNormal, V, effectiveL, surfaceAlbedoLinear,
        smoothness, f0, matId,
        pbrDiffuse, pbrSpecular
    );

    vec3 radiance = res.lightColor * physicalAtten * res.directionalOcclusion;
    res.diffuse  = radiance * max(pbrDiffuse, vec3(0.12 * (1.0 - f0)));
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
    float dither,
    sampler2D depthTex0,
    sampler2D depthTex1,
    sampler2D colortex0,
    sampler2D colortex2,
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
    float rawNoL = dot(viewNormal, L);
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

    // 4-step screen-space contact shadow & stained glass transmission from hand position
    float contactShadow = 1.0;
    vec3 glassFilter = vec3(1.0);
    vec3 rayStep = L * min(dist * 0.22, 0.45);
    vec3 rayPos = viewPos + viewNormal * 0.04;
    for (int i = 0; i < 4; i++) {
        rayPos += rayStep * (0.55 + 0.65 * dither);
        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x > 0.002 && sc.x < 0.998 && sc.y > 0.002 && sc.y < 0.998) {
            float sMat = texture(colortex2, sc.xy).a;
            if (isMaterial(sMat, MAT_STAINED_GLASS)) {
                float dAll = texture(depthTex0, sc.xy).r;
                vec3 gPosAll = screenToView(sc.xy, dAll, projInv);
                float diffAll = gPosAll.z - rayPos.z;
                if (diffAll > -0.15 && diffAll < 1.10) {
                    vec3 gCol = toLinear(texture(colortex0, sc.xy).rgb);
                    glassFilter *= getStainedGlassTransmission(gCol, 0.78);
                    contactShadow *= 0.88;
                }
            } else if (!isMaterial(sMat, MAT_GLASS)) {
                float dOpaque = texture(depthTex1, sc.xy).r;
                vec3 gPos = screenToView(sc.xy, dOpaque, projInv);
                float diff = gPos.z - rayPos.z;
                if (diff > 0.035 && diff < 0.85) {
                    contactShadow *= 0.36;
                }
            }
        }
    }

    vec3 V = normalize(-viewPos);
    vec3 effectiveL = normalize(mix(viewNormal, L, 0.78));
    vec3 pbrDiffuse = vec3(0.0);
    vec3 pbrSpecular = vec3(0.0);
    evaluatePBRSurface(
        viewNormal, V, effectiveL, surfaceAlbedoLinear,
        smoothness, f0, matId,
        pbrDiffuse, pbrSpecular
    );

    vec3 handRadiance = heldLightColor * glassFilter * (smoothHeldIntensity * HANDLIGHT_INTENSITY * angularAtten * contactShadow * wrappedNoL);
    outDiffuse  = handRadiance * pbrDiffuse;
    outSpecular = handRadiance * pbrSpecular * max(rawNoL, 0.0);
}

#endif // BLOCKLIGHT_DIR_GLSL
