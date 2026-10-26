#ifndef SSR_REFLECTION_GLSL
#define SSR_REFLECTION_GLSL

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

vec4 computeScreenSpaceReflection(
    vec3 viewPos,
    vec3 viewNormal,
    vec3 worldNormal,
    float smoothness,
    float f0,
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

    if (smoothness < 0.22) {
        return vec4(0.0);
    }

    vec3 V = normalize(-viewPos);
    float NoV = max(dot(viewNormal, V), 0.001);
    float fresnel = fresnelSchlickScalar(NoV, f0) * smoothstep(0.22, 0.55, smoothness);

    if (fresnel < 0.015) {
        return vec4(0.0);
    }

    vec3 reflectDir = reflect(-V, viewNormal);

    // Subtle roughness cone perturbation
    float roughness = clamp(1.0 - smoothness, 0.0, 1.0);
    if (roughness > 0.05) {
        vec3 t, b;
        float signZ = (reflectDir.z >= 0.0) ? 1.0 : -1.0;
        float a = -1.0 / (signZ + reflectDir.z);
        float bVal = reflectDir.x * reflectDir.y * a;
        t = vec3(1.0 + signZ * reflectDir.x * reflectDir.x * a, signZ * bVal, -signZ * reflectDir.x);
        b = vec3(bVal, signZ + reflectDir.y * reflectDir.y * a, -reflectDir.y);

        float angle = dither * 2.0 * PI;
        float spread = roughness * roughness * 0.14;
        reflectDir = normalize(reflectDir + (t * cos(angle) + b * sin(angle)) * spread);
    }

    // Fallback sky reflection (scaled by skylight so caves don't reflect outdoor sky!)
    float upDot = clamp(worldNormal.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyFallback = mix(atm.skyHorizon, atm.skyZenith, upDot) * (skyLight * skyLight);

    // Raymarch in view space with exponential step growth
    int steps = SSR_STEPS;
    vec3 rayPos = viewPos + viewNormal * 0.06;
    float stepLength = 0.25 + 0.20 * dither;

    vec2 hitUV = vec2(-1.0);
    float hitConfidence = 0.0;

    for (int i = 0; i < steps; i++) {
        rayPos += reflectDir * stepLength;
        stepLength *= 1.32;

        // If ray goes behind camera near plane, stop
        if (rayPos.z > -0.1) break;

        vec3 sc = viewToScreen(rayPos, proj);
        if (sc.x <= 0.005 || sc.x >= 0.995 || sc.y <= 0.005 || sc.y >= 0.995) {
            break;
        }

        float sceneDepth = texture(depthTex, sc.xy).r;
        if (sceneDepth >= 0.9999) continue;

        vec3 geomPos = screenToView(sc.xy, sceneDepth, projInv);
        float depthDiff = geomPos.z - rayPos.z;

        float thickness = max(stepLength * 1.35, 0.45);
        if (depthDiff > 0.01 && depthDiff < thickness) {
            // 1-step linear refinement
            vec3 refinedPos = rayPos - reflectDir * (stepLength * clamp(depthDiff / thickness, 0.1, 0.9));
            vec3 refinedSC = viewToScreen(refinedPos, proj);
            hitUV = refinedSC.xy;

            // Screen edge vignette fade
            vec2 edgeDist = smoothstep(vec2(0.0), vec2(0.08), hitUV) *
                            (1.0 - smoothstep(vec2(0.92), vec2(1.0), hitUV));
            hitConfidence = edgeDist.x * edgeDist.y;
            break;
        }
    }

    vec3 reflectedColor = skyFallback;
    if (hitConfidence > 0.001) {
        vec3 ssrSample = texture(directLitTex, hitUV).rgb;
        reflectedColor = mix(skyFallback, ssrSample, hitConfidence);
    }

    return vec4(reflectedColor * fresnel * SPECULAR_STRENGTH, fresnel);
}

#endif // SSR_REFLECTION_GLSL

