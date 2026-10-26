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

// Screen-space raymarch towards the inferred light source to occlude light behind tube walls
float traceTubeWallOcclusion(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 lightDirView,
    float searchDist,
    float dither,
    sampler2D depthTex,
    sampler2D colortex0,
    mat4 proj,
    mat4 projInv
) {
    int steps = BLOCKLIGHT_OCCLUSION_STEPS;
    vec3 startPos = viewPos + viewNormal * 0.06;
    vec3 stepVec = lightDirView * (searchDist / float(steps));

    float visibility = 1.0;

    for (int i = 0; i < steps; i++) {
        float t = float(i) + 0.35 + 0.65 * dither;
        vec3 rayPos = startPos + stepVec * t;

        vec3 screenPos = viewToScreen(rayPos, proj);
        if (screenPos.x < 0.002 || screenPos.x > 0.998 ||
            screenPos.y < 0.002 || screenPos.y > 0.998) {
            break;
        }

        float sampleDepth = texture(depthTex, screenPos.xy).r;
        if (sampleDepth >= 0.9999) continue;

        vec3 geomViewPos = screenToView(screenPos.xy, sampleDepth, projInv);
        float sampleMat = texture(colortex0, screenPos.xy).a;

        // If we hit the emissive light block itself, the path to the light is clear!
        if (isEmissiveMaterial(sampleMat)) {
            visibility = min(visibility * 1.15, 1.0);
            break;
        }

        // In view space, Z is negative. geomViewPos.z > rayPos.z means geometry is closer to camera than the ray.
        float depthDelta = geomViewPos.z - rayPos.z;
        // Solid block thickness check (0.06m to 1.45m wall thickness for 1-block tube walls)
        if (depthDelta > 0.055 && depthDelta < 1.45) {
            // Tube wall or obstacle stands between surface and light direction
            visibility *= mix(1.0, 0.22, TUBE_OCCLUSION_STRENGTH);
        }
    }

    return clamp(visibility, 0.08, 1.0);
}

BlocklightResult computeDirectionalBlocklight(
    vec3 viewPos,
    vec3 viewNormal,
    vec2 texCoord,
    float rawBlockLight,
    float smoothness,
    float f0,
    float dither,
    sampler2D colortex0,
    sampler2D colortex1,
    sampler2D depthTex,
    mat4 proj,
    mat4 projInv
) {
    BlocklightResult res;
    res.diffuse = vec3(0.0);
    res.specular = vec3(0.0);
    res.lightColor = getEmissiveColorFromMat(MAT_EMISSIVE_WARM, rawBlockLight);
    res.lightDirView = viewNormal;
    res.directionalOcclusion = 1.0;

    if (rawBlockLight <= 0.005) {
        return res;
    }

    // Physical non-linear attenuation curve from vanilla [0..1] lightmap
    // Preserves bright core near source while creating natural inverse-square falloff
    float distRatio = 1.0 - rawBlockLight;
    float physicalAtten = pow(rawBlockLight, BLOCKLIGHT_DISTANCE_FALLOFF) / (1.0 + 2.2 * distRatio * distRatio);
    physicalAtten *= BLOCKLIGHT_INTENSITY;

    // Multi-scale screen-space neighborhood scan to reconstruct:
    // 1. 3D light gradient vector (direction of light propagation)
    // 2. Nearby emissive block color (Soul Cyan, Redstone Red, Lava Orange, etc.)
    // 3. Local enclosure / tube aperture
    vec3 gradAccum = vec3(0.0);
    vec3 colorAccum = res.lightColor * 0.35;
    float colorWeight = 0.35;
    float enclosureCount = 0.0;

    float viewDist = max(length(viewPos), 1.0);
    vec2 shortRadius = vec2(0.004, 0.004 * 1.77) / clamp(viewDist * 0.15, 0.5, 3.0);
    vec2 wideRadius  = vec2(0.028, 0.028 * 1.77) / clamp(viewDist * 0.12, 0.4, 2.5);

    float rotAngle = dither * PI * 0.5;
    float s = sin(rotAngle);
    float c = cos(rotAngle);
    mat2 rot = mat2(c, -s, s, c);

    for (int i = 0; i < 8; i++) {
        vec2 dir2D = rot * GRAD_DIRS[i];
        // Alternate between close gradient samples and wide light-finder samples
        vec2 sampleUV = texCoord + dir2D * ((i % 2 == 0) ? shortRadius : wideRadius);
        sampleUV = clamp(sampleUV, vec2(0.002), vec2(0.998));

        vec4 nData = texture(colortex1, sampleUV);
        float nLight = nData.b;
        float nMat   = texture(colortex0, sampleUV).a;
        float nDepth = texture(depthTex, sampleUV).r;

        if (nDepth >= 0.9999) continue;

        vec3 nViewPos = screenToView(sampleUV, nDepth, projInv);
        vec3 deltaPos = nViewPos - viewPos;
        float dist3D  = length(deltaPos);

        if (dist3D > 0.02 && dist3D < 14.0) {
            vec3 dir3D = deltaPos / dist3D;
            float lightDiff = nLight - rawBlockLight;

            // Detect if neighbor is an emissive block (e.g. inside tube or visible torch)
            if (isEmissiveMaterial(nMat)) {
                lightDiff += 0.55;
                vec3 eCol = getEmissiveColorFromMat(nMat, 1.0);
                float w = 3.5 / (0.5 + dist3D);
                colorAccum += eCol * w;
                colorWeight += w;
            } else if (nLight > rawBlockLight + 0.02) {
                // High-light region (such as an illuminated tube opening!) acts as virtual emitter
                float w = (nLight - rawBlockLight) * 1.5 / (0.8 + dist3D * 0.5);
                colorAccum += getEmissiveColorFromMat(MAT_EMISSIVE_WARM, nLight) * w;
                colorWeight += w;
            }

            // Accumulate 3D gradient pointing toward brighter blocklight / tube opening
            float gradWeight = lightDiff / (0.25 + dist3D * 0.45);
            gradAccum += dir3D * gradWeight;

            // Check if surrounding geometry forms an enclosing wall/tube
            if (dot(viewNormal, dir3D) > 0.25 && dist3D < 2.5 && lightDiff < -0.02) {
                enclosureCount += 1.0;
            }
        }
    }

    res.lightColor = colorAccum / max(colorWeight, 0.001);

    #ifdef DIRECTIONAL_BLOCKLIGHT
    float gradMag = length(gradAccum);
    if (gradMag > 0.008) {
        vec3 inferredDir = gradAccum / gradMag;
        // Blend between surface normal (isotropic) and inferred 3D light direction
        // Stronger gradient = stronger directional beam (e.g. exiting a 4-walled tube)
        float directionality = clamp(gradMag * 3.2, 0.0, 0.88);
        res.lightDirView = normalize(mix(viewNormal, inferredDir, directionality));

        // Compute Lambertian incidence angle
        float NoL = dot(viewNormal, res.lightDirView);
        // Wrapped diffuse so open lights still wrap gently, while perpendicular/away walls dim
        float directTerm = clamp((NoL + 0.30) / 1.30, 0.08, 1.25);

        // Trace 4-step screen-space ray to check if a tube wall blocks line-of-sight
        float searchDist = clamp((1.0 - rawBlockLight) * 6.5 + 0.6, 0.6, 4.5);
        float wallVis = traceTubeWallOcclusion(
            viewPos, viewNormal, res.lightDirView, searchDist,
            dither, depthTex, colortex0, proj, projInv
        );

        // If light is enclosed on sides, boost beam along open axis and suppress blocked sides
        float tubeBeamBoost = mix(1.0, 1.28, clamp(gradMag * 2.0, 0.0, 1.0) * wallVis);
        res.directionalOcclusion = mix(1.0, directTerm * wallVis * tubeBeamBoost, directionality * TUBE_OCCLUSION_STRENGTH);
    }
    #endif

    res.diffuse = res.lightColor * physicalAtten * res.directionalOcclusion;

    // Colored Specular Reflection from Blocklight
    vec3 V = normalize(-viewPos);
    vec3 H = normalize(res.lightDirView + V);
    float NoH = max(dot(viewNormal, H), 0.0);
    float VoH = max(dot(V, H), 0.0);
    float specPower = exp2(4.0 + smoothness * 7.5);
    float normFactor = (specPower + 2.0) * 0.125;
    float specTerm = normFactor * pow(NoH, specPower) * fresnelSchlickScalar(VoH, f0);

    res.specular = res.lightColor * specTerm * physicalAtten * res.directionalOcclusion * smoothness * SPECULAR_STRENGTH;
    return res;
}

// ============================================================================
// Smooth Handheld Dynamic Light (Point Light + Spotlight Cone + Contact Shadow)
// ============================================================================
void computeHandheldLight(
    vec3 viewPos,
    vec3 viewNormal,
    float smoothHeldIntensity,
    vec3 heldLightColor,
    float smoothness,
    float f0,
    float dither,
    sampler2D depthTex,
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

    // Virtual hand position in view space (slightly right and below camera eye)
    vec3 handPosView = vec3(0.16, -0.14, -0.15);
    vec3 toLight = handPosView - viewPos;
    float dist = length(toLight);

    if (dist >= HANDLIGHT_RANGE || dist < 0.001) {
        return;
    }

    vec3 L = toLight / dist;
    float NoL = max(dot(viewNormal, L), 0.0);

    // Physical inverse-square attenuation with smooth range window
    float distNorm = clamp(dist / HANDLIGHT_RANGE, 0.0, 1.0);
    float window = clamp(1.0 - distNorm * distNorm * distNorm * distNorm, 0.0, 1.0);
    window *= window;

    // Shape attenuation based on light mode (Point vs Spotlight vs Hybrid)
    // Camera forward in view space is vec3(0.0, 0.0, -1.0)
    vec3 lightToSurface = -L;
    float spotCos = dot(lightToSurface, vec3(0.0, 0.0, -1.0));
    float spotCone = smoothstep(SPOTLIGHT_OUTER_COS, SPOTLIGHT_INNER_COS, spotCos);
    // Crisp beam profile with soft outer halo
    float spotProfile = pow(spotCone, 1.35) * 1.85;

    float pointAtten = (1.6 / (1.0 + 0.32 * dist * dist)) * window;
    float spotAtten  = (2.4 / (1.0 + 0.14 * dist * dist)) * window * spotProfile;

    float angularAtten;
    #if HANDLIGHT_MODE == 1
        // Omni-directional Point Light
        angularAtten = pointAtten;
    #elif HANDLIGHT_MODE == 2
        // Directional Spotlight Cone + subtle ambient spill near hand
        angularAtten = spotAtten + pointAtten * 0.12;
    #else
        // Adaptive Hybrid: Warm point light near player + focused spotlight beam ahead
        angularAtten = mix(pointAtten * 0.75, spotAtten, 0.55);
    #endif

    // 4-step screen-space contact shadow from hand position
    float contactShadow = 1.0;
    vec3 rayStep = L * min(dist * 0.22, 0.45);
    vec3 rayPos = viewPos + viewNormal * 0.04;
    for (int i = 0; i < 4; i++) {
        rayPos += rayStep * (0.6 + 0.6 * dither);
        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x > 0.0 && sc.x < 1.0 && sc.y > 0.0 && sc.y < 1.0) {
            float d = texture(depthTex, sc.xy).r;
            vec3 gPos = screenToView(sc.xy, d, projInv);
            float diff = gPos.z - rayPos.z;
            if (diff > 0.04 && diff < 0.85) {
                contactShadow *= 0.45;
            }
        }
    }

    float totalLight = smoothHeldIntensity * HANDLIGHT_INTENSITY * angularAtten * contactShadow;
    outDiffuse = heldLightColor * totalLight * (NoL * 0.85 + 0.15);

    // Specular highlight from handheld light
    vec3 V = normalize(-viewPos);
    vec3 H = normalize(L + V);
    float NoH = max(dot(viewNormal, H), 0.0);
    float VoH = max(dot(V, H), 0.0);
    float specPower = exp2(4.5 + smoothness * 8.0);
    float spec = ((specPower + 2.0) * 0.125) * pow(NoH, specPower) * fresnelSchlickScalar(VoH, f0);
    outSpecular = heldLightColor * totalLight * spec * NoL * smoothness * SPECULAR_STRENGTH;
}

#endif // BLOCKLIGHT_DIR_GLSL

