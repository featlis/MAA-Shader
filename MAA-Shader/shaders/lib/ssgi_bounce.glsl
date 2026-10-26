#ifndef SSGI_BOUNCE_GLSL
#define SSGI_BOUNCE_GLSL

#include "/lib/common.glsl"

// Builds an orthonormal tangent basis (T, B, N) from normal N (Frisvad / Duff method)
void buildOrthonormalBasis(vec3 n, out vec3 b1, out vec3 b2) {
    float signZ = (n.z >= 0.0) ? 1.0 : -1.0;
    float a = -1.0 / (signZ + n.z);
    float b = n.x * n.y * a;
    b1 = vec3(1.0 + signZ * n.x * n.x * a, signZ * b, -signZ * n.x);
    b2 = vec3(b, signZ + n.y * n.y * a, -n.y);
}

// Golden-ratio spiral hemisphere sample with per-pixel dither rotation
vec3 sampleCosineHemisphere(vec3 normal, int sampleIdx, int totalSamples, float dither, vec2 rand2) {
    float fi = (float(sampleIdx) + rand2.x) / float(totalSamples);
    float phi = 2.0 * PI * fract(float(sampleIdx) * 0.6180339887 + dither);
    float cosTheta = sqrt(clamp(1.0 - fi, 0.05, 1.0));
    float sinTheta = sqrt(clamp(fi, 0.0, 0.95));

    vec3 t, b;
    buildOrthonormalBasis(normal, t, b);
    return normalize(t * (cos(phi) * sinTheta) + b * (sin(phi) * sinTheta) + normal * cosTheta);
}

// Traces short screen-space rays to gather indirect bounced light (color bleeding) & AO
// Returns: rgb = indirect bounce radiance, a = ambient occlusion visibility [0..1]
vec4 computeSSGIBounceAndAO(
    vec3 viewPos,
    vec3 viewNormal,
    vec2 texCoord,
    float dither,
    sampler2D directLitTex, // colortex3
    sampler2D normalLightTex, // colortex1
    sampler2D depthTex, // depthtex0
    mat4 proj,
    mat4 projInv
) {
    #ifndef ENABLE_SSGI
    return vec4(0.0, 0.0, 0.0, 1.0);
    #endif

    int numRays = SSGI_SAMPLES;
    if (numRays <= 0) {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }

    vec3 bounceAccum = vec3(0.0);
    float aoOcclusion = 0.0;

    vec2 rand2 = hash22(texCoord * 1024.0 + vec2(dither * 37.0));
    vec3 startPos = viewPos + viewNormal * 0.06;
    float maxRayDist = clamp(length(viewPos) * 0.35 + 1.8, 2.0, 6.5);
    int numSteps = SSGI_STEPS;

    for (int r = 0; r < numRays; r++) {
        vec3 rayDir = sampleCosineHemisphere(viewNormal, r, numRays, dither, rand2);
        float stepSize = maxRayDist / float(numSteps);

        vec3 rayHitRadiance = vec3(0.0);
        float rayOccluded = 0.0;

        for (int s = 1; s <= numSteps; s++) {
            // Non-linear step progression: fine steps near surface for AO, wider steps for GI bounce
            float tNorm = (float(s) - 0.5 + 0.5 * dither) / float(numSteps);
            float rayDist = maxRayDist * (tNorm * tNorm * 0.75 + tNorm * 0.25);
            vec3 samplePos = startPos + rayDir * rayDist;

            vec3 sc = viewToScreen(samplePos, proj);
            if (sc.x <= 0.005 || sc.x >= 0.995 || sc.y <= 0.005 || sc.y >= 0.995) {
                break;
            }

            float sceneDepth = texture(depthTex, sc.xy).r;
            if (sceneDepth >= 0.9999) continue;

            vec3 geomPos = screenToView(sc.xy, sceneDepth, projInv);
            float depthDiff = geomPos.z - samplePos.z; // Positive if geometry is in front of ray

            float thickness = 0.35 + rayDist * 0.32;
            if (depthDiff > 0.03 && depthDiff < thickness) {
                // Hit valid surface!
                vec3 hitNormal = decodeNormal(texture(normalLightTex, sc.xy).rg);
                vec3 hitDirect = texture(directLitTex, sc.xy).rgb;

                // Ensure surface isn't coplanar and faces roughly toward our ray
                float facing = clamp(dot(hitNormal, -rayDir) * 0.8 + 0.35, 0.1, 1.0);
                float distAtten = 1.0 / (1.0 + 0.25 * rayDist * rayDist);

                // Clamp fireflies while keeping vibrant colored light bounce
                vec3 clampedHit = hitDirect / (1.0 + getLuminance(hitDirect) * 0.28);
                rayHitRadiance = clampedHit * facing * distAtten * 2.2;

                // Short-range hit contributes to Ambient Occlusion
                if (rayDist < 1.85) {
                    rayOccluded = clamp(1.0 - (rayDist / 1.85), 0.0, 1.0);
                }
                break;
            }
        }

        bounceAccum += rayHitRadiance;
        aoOcclusion += rayOccluded;
    }

    vec3 finalBounce = (bounceAccum / float(numRays)) * SSGI_INTENSITY;
    float finalAO = clamp(1.0 - (aoOcclusion / float(numRays)) * 0.65, 0.32, 1.0);

    return vec4(finalBounce, finalAO);
}

// Edge-preserving Cross-Bilateral Filter to denoise & upscale SSGI + AO cleanly
vec4 sampleBilateralSSGI(
    vec2 texCoord,
    vec3 centerNormal,
    float centerLinearDepth,
    vec2 texelSize,
    sampler2D ssgiTex,
    sampler2D normalLightTex,
    sampler2D depthTex,
    float nearPlane,
    float farPlane
) {
    vec4 centerVal = texture(ssgiTex, texCoord);
    vec4 sumVal = centerVal * 0.28;
    float sumWeight = 0.28;

    const vec2 OFFSETS[8] = vec2[8](
        vec2(-1.5, -0.5), vec2( 1.5,  0.5),
        vec2(-0.5,  1.5), vec2( 0.5, -1.5),
        vec2(-2.5,  1.5), vec2( 2.5, -1.5),
        vec2( 1.5,  2.5), vec2(-1.5, -2.5)
    );

    for (int i = 0; i < 8; i++) {
        vec2 sampleUV = clamp(texCoord + OFFSETS[i] * texelSize, vec2(0.002), vec2(0.998));
        float sampleDepth = texture(depthTex, sampleUV).r;
        if (sampleDepth >= 0.9999) continue;

        float sampleLinDepth = linearizeDepth(sampleDepth, nearPlane, farPlane);
        vec3 sampleNormal = decodeNormal(texture(normalLightTex, sampleUV).rg);

        // Normal similarity weight
        float normalWeight = pow(max(dot(centerNormal, sampleNormal), 0.0), 8.0);
        // Depth similarity weight
        float depthDiff = abs(centerLinearDepth - sampleLinDepth) / max(centerLinearDepth, 0.5);
        float depthWeight = exp(-depthDiff * 18.0);

        float w = max(normalWeight * depthWeight, 0.001) * 0.09;
        sumVal += texture(ssgiTex, sampleUV) * w;
        sumWeight += w;
    }

    return sumVal / max(sumWeight, 0.001);
}

#endif // SSGI_BOUNCE_GLSL

