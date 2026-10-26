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

    // Rough materials (stone, dirt, wood: smoothness < 0.30) do not produce sharp mirror reflections
    if (smoothness < 0.30) {
        return vec4(0.0);
    }

    vec3 V = normalize(-viewPos);
    float NoV = max(dot(viewNormal, V), 0.001);
    float roughness = clamp(1.0 - smoothness, 0.02, 1.0);

    bool isMetal = isMaterial(matId, MAT_METALLIC);
    vec3 F0 = isMetal ? mix(vec3(f0), albedoLinear * 1.15, 0.82) : vec3(f0);

    // Physical roughness-attenuated Schlick Fresnel
    float glossMask = smoothstep(0.30, 0.85, smoothness);
    vec3 fresnelVec = fresnelSchlickRoughness(NoV, F0, roughness) * glossMask;
    float fresnelScalar = max(fresnelVec.r, max(fresnelVec.g, fresnelVec.b));

    if (fresnelScalar < 0.012) {
        return vec4(0.0);
    }

    vec3 reflectDir = reflect(-V, viewNormal);

    // Roughness cone perturbation: semi-gloss polished stone has a softer reflection cone,
    // while high-gloss glass/metal/water has a razor-sharp reflection ray
    if (roughness > 0.04) {
        vec3 t, b;
        float signZ = (reflectDir.z >= 0.0) ? 1.0 : -1.0;
        float a = -1.0 / (signZ + reflectDir.z);
        float bVal = reflectDir.x * reflectDir.y * a;
        t = vec3(1.0 + signZ * reflectDir.x * reflectDir.x * a, signZ * bVal, -signZ * reflectDir.x);
        b = vec3(bVal, signZ + reflectDir.y * reflectDir.y * a, -reflectDir.y);

        float angle = dither * 2.0 * PI;
        float spread = roughness * roughness * 0.22;
        reflectDir = normalize(reflectDir + (t * cos(angle) + b * sin(angle)) * spread);
    }

    // Fallback sky reflection (scaled by skylight so indoor/caves don't reflect outdoor sky)
    float upDot = clamp(worldNormal.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyFallback = mix(atm.skyHorizon, atm.skyZenith, upDot) * (skyLight * skyLight);

    // Raymarch in view space with exponential step growth
    int steps = SSR_STEPS;
    vec3 rayPos = viewPos + viewNormal * 0.05;
    float stepLength = 0.22 + 0.18 * dither;

    vec2 hitUV = vec2(-1.0);
    float hitConfidence = 0.0;

    for (int i = 0; i < steps; i++) {
        rayPos += reflectDir * stepLength;
        stepLength *= 1.30;

        if (rayPos.z > -0.1) break;

        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x <= 0.005 || sc.x >= 0.995 || sc.y <= 0.005 || sc.y >= 0.995) {
            break;
        }

        float sceneDepth = texture(depthTex, sc.xy).r;
        if (sceneDepth >= 0.9999) continue;

        vec3 geomPos = screenToView(sc.xy, sceneDepth, projInv);
        float depthDiff = geomPos.z - rayPos.z;

        float thickness = max(stepLength * 1.35, 0.42);
        if (depthDiff > 0.01 && depthDiff < thickness) {
            vec3 refinedPos = rayPos - reflectDir * (stepLength * clamp(depthDiff / thickness, 0.1, 0.9));
            vec3 refinedSC = viewToScreen(refinedPos, proj);
            hitUV = refinedSC.xy;

            vec2 edgeDist = smoothstep(vec2(0.0), vec2(0.07), hitUV) *
                            (1.0 - smoothstep(vec2(0.93), vec2(1.0), hitUV));
            hitConfidence = edgeDist.x * edgeDist.y;
            break;
        }
    }

    vec3 reflectedColor = skyFallback;
    if (hitConfidence > 0.001) {
        vec3 ssrSample = texture(directLitTex, hitUV).rgb;
        reflectedColor = mix(skyFallback, ssrSample, hitConfidence);
    }

    // High-gloss materials (glass, metal, water) reflect crisply and strongly
    float materialBoost = (isMaterial(matId, MAT_GLASS) || isMaterial(matId, MAT_STAINED_GLASS) || isMetal) ? 1.25 : 0.90;
    return vec4(reflectedColor * fresnelVec * SPECULAR_STRENGTH * materialBoost, fresnelScalar);
}

#endif // SSR_REFLECTION_GLSL
