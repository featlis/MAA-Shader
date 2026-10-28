#ifndef SSR_REFLECTION_GLSL
#define SSR_REFLECTION_GLSL

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

vec4 computeScreenSpaceReflection(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 worldNormal,
    vec3 albedoLinear,
    float smoothness,
    float f0,
    float matId,
    float skyLight,
    float dither,
    AtmosphereColors atm,
    sampler2D directLitTex,
    sampler2D depthTex,
    mat4 proj,
    mat4 projInv
) {
    #ifndef ENABLE_SSR
    return vec4(0.0);
    #endif

    // Rough materials (stone, dirt, wood: smoothness < 0.35) do not produce mirror reflections
    if (smoothness < 0.35) {
        return vec4(0.0);
    }

    vec3 V = normalize(-viewPos);
    float NoV = max(dot(viewNormal, V), 0.001);
    float roughness = clamp(1.0 - smoothness, 0.02, 1.0);

    bool isMetal = isMaterial(matId, MAT_METALLIC);
    vec3 F0 = isMetal ? mix(vec3(f0), albedoLinear * 1.15, 0.82) : vec3(f0);

    // Physical roughness-attenuated Schlick Fresnel:
    // Dielectrics (glass, ice, water) reflect strongly at grazing angles and subtly at normal incidence;
    // Metals (iron, gold, copper, diamond) reflect strongly at all angles!
    float glossMask = smoothstep(0.35, 0.85, smoothness);
    vec3 fresnelVec = fresnelSchlickRoughness(NoV, F0, roughness) * glossMask;
    float fresnelScalar = max(fresnelVec.r, max(fresnelVec.g, fresnelVec.b));

    if (fresnelScalar < 0.012) {
        return vec4(0.0);
    }

    // Deterministic reflection ray (zero per-pixel stipple noise)
    vec3 reflectDir = reflect(-V, viewNormal);

    // Fallback sky reflection (scaled by skylight so indoor/caves don't reflect outdoor sky)
    float upDot = clamp(worldNormal.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyFallback = mix(atm.skyHorizon, atm.skyZenith, upDot) * (skyLight * skyLight * skyLight);

    // Raymarch in view space with fine, jitter-smoothed steps to prevent floating ghost stickers
    int steps = SSR_STEPS;
    float stepLength = 0.22;
    vec3 rayPos = viewPos + viewNormal * 0.06 + reflectDir * (stepLength * (0.25 + 0.50 * dither));

    vec2 hitUV = vec2(-1.0);
    float hitConfidence = 0.0;
    float hitDist3D = 0.0;

    for (int i = 0; i < steps; i++) {
        rayPos += reflectDir * stepLength;
        stepLength *= 1.24;

        if (rayPos.z > -0.1) break;

        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x <= 0.005 || sc.x >= 0.995 || sc.y <= 0.005 || sc.y >= 0.995) {
            break;
        }

        float sceneDepth = texture(depthTex, sc.xy).r;
        if (sceneDepth >= 0.9999) continue;

        vec3 geomPos = screenToView(sc.xy, sceneDepth, projInv);
        float depthDiff = geomPos.z - rayPos.z;

        // Smooth 3D thickness window prevents stair-stepped contour lines on glass/water reflections
        float thickness = min(stepLength * 1.15, 0.34);
        if (depthDiff > 0.012 && depthDiff < thickness) {
            float thickWindow = smoothstep(0.012, 0.045, depthDiff) * smoothstep(thickness, thickness * 0.35, depthDiff);
            vec3 refinedPos = rayPos - reflectDir * (stepLength * clamp(depthDiff / thickness, 0.15, 0.85));
            vec3 refinedSC = viewToScreen(refinedPos, proj);
            hitUV = refinedSC.xy;
            hitDist3D = length(refinedPos - viewPos);

            vec2 edgeDist = smoothstep(vec2(0.0), vec2(0.10), hitUV) *
                            (1.0 - smoothstep(vec2(0.90), vec2(1.0), hitUV));
            float distFade = exp(-hitDist3D * mix(0.28, 0.08, smoothness));
            hitConfidence = edgeDist.x * edgeDist.y * distFade * thickWindow;
            break;
        }
    }

    vec3 reflectedColor = skyFallback;
    if (hitConfidence > 0.001) {
        // Roughness-scaled 5-tap cross filter so semi-gloss surfaces (like frosty ice or polished stone)
        // show a smooth, blurry optical reflection instead of a sharp floating cutout sticker!
        float blurRadius = roughness * (0.003 + hitDist3D * 0.0025);
        vec3 s0 = texture(directLitTex, hitUV).rgb;
        vec3 s1 = texture(directLitTex, clamp(hitUV + vec2( blurRadius,  blurRadius * 0.6), vec2(0.002), vec2(0.998))).rgb;
        vec3 s2 = texture(directLitTex, clamp(hitUV + vec2(-blurRadius,  blurRadius * 0.6), vec2(0.002), vec2(0.998))).rgb;
        vec3 s3 = texture(directLitTex, clamp(hitUV + vec2( blurRadius * 0.6, -blurRadius), vec2(0.002), vec2(0.998))).rgb;
        vec3 s4 = texture(directLitTex, clamp(hitUV + vec2(-blurRadius * 0.6, -blurRadius), vec2(0.002), vec2(0.998))).rgb;
        vec3 ssrSample = s0 * 0.36 + (s1 + s2 + s3 + s4) * 0.16;

        // Compress extreme HDR emitter values so dielectric reflections look naturally blended into the surface
        float sampleLuma = getLuminance(ssrSample);
        float maxCompression = isMetal ? 0.22 : 0.65;
        ssrSample /= (1.0 + sampleLuma * maxCompression);

        reflectedColor = mix(skyFallback, ssrSample, hitConfidence);
    }

    bool isTranslucentGlass = isMaterial(matId, MAT_GLASS) || isMaterial(matId, MAT_STAINED_GLASS);
    float materialBoost = isMetal ? 1.25 : (isTranslucentGlass ? 0.42 : 0.82);
    return vec4(reflectedColor * fresnelVec * SPECULAR_STRENGTH * materialBoost, fresnelScalar);
}

#endif // SSR_REFLECTION_GLSL
