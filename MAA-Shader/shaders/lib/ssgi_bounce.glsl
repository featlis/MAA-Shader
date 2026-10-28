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

// Golden-ratio spiral hemisphere sample with full 2D stratified jitter (zero fixed ray lobes!)
vec3 sampleCosineHemisphere(vec3 normal, int sampleIdx, int totalSamples, float dither, vec2 rand2) {
    float radialJitter = fract(dither * 1.6180339887 + rand2.x);
    float fi = (float(sampleIdx) + radialJitter) / float(totalSamples);
    float phi = 2.0 * PI * fract(float(sampleIdx) * 0.6180339887 + dither + rand2.y * 0.5);
    float cosTheta = sqrt(clamp(1.0 - fi, 0.10, 1.0));
    float sinTheta = sqrt(clamp(fi, 0.0, 0.90));

    vec3 t, b;
    buildOrthonormalBasis(normal, t, b);
    return normalize(t * (cos(phi) * sinTheta) + b * (sin(phi) * sinTheta) + normal * cosTheta);
}

// Traces screen-space rays to gather material-dependent indirect bounced light & AO
// Distinguishes rough diffuse blocks (stone: soft, dim, wide bounce) vs glossy/metallic/glass blocks (strong reflection)
// Returns: rgb = indirect bounce radiance, a = ambient occlusion visibility [0..1]
vec4 computeSSGIBounceAndAO(
    vec3 viewPos,
    vec3 viewNormal,
    vec2 texCoord,
    float receiverSmoothness,
    float receiverF0,
    float receiverMatId,
    float dither,
    sampler2D directLitTex,   // colortex3
    sampler2D normalLightTex, // colortex1
    sampler2D matSpecTex,     // colortex2 (r=smoothness, g=f0, b=emission, a=matId)
    sampler2D depthTex,       // depthtex0
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

    bool isReceiverTranslucent = isMaterial(receiverMatId, MAT_STAINED_GLASS) ||
                                 isMaterial(receiverMatId, MAT_GLASS) ||
                                 isMaterial(receiverMatId, MAT_WATER);

    vec3 bounceAccum = vec3(0.0);
    float aoOcclusion = 0.0;

    vec2 rand2 = hash22(texCoord * 512.0);
    vec3 startPos = viewPos + viewNormal * 0.06;
    float maxRayDist = clamp(length(viewPos) * 0.32 + 1.8, 2.0, 6.5);
    int numSteps = SSGI_STEPS;

    vec3 V = normalize(-viewPos);
    vec3 mirrorDir = reflect(-V, viewNormal);
    float specLobeBias = smoothstep(0.35, 0.90, receiverSmoothness) * 0.42;

    for (int r = 0; r < numRays; r++) {
        vec3 hemiDir = sampleCosineHemisphere(viewNormal, r, numRays, dither, rand2);
        vec3 rayDir = normalize(mix(hemiDir, mirrorDir, specLobeBias));
        if (dot(rayDir, viewNormal) < 0.06) {
            rayDir = hemiDir;
        }

        vec3 rayHitRadiance = vec3(0.0);
        float rayOccluded = 0.0;

        for (int s = 1; s <= numSteps; s++) {
            float stepJitter = fract(dither + float(r) * 0.6180339887) - 0.5;
            float tNorm = clamp((float(s) - 0.45 + stepJitter * 0.75) / float(numSteps), 0.05, 1.0);
            float rayDist = maxRayDist * (tNorm * tNorm * 0.72 + tNorm * 0.28);
            vec3 samplePos = startPos + rayDir * rayDist;

            vec3 sc = viewToScreen(samplePos, proj);
            if (sc.x <= 0.005 || sc.x >= 0.995 || sc.y <= 0.005 || sc.y >= 0.995) {
                break;
            }

            float sceneDepth = texture(depthTex, sc.xy).r;
            if (sceneDepth >= 0.9999) continue;

            vec3 geomPos = screenToView(sc.xy, sceneDepth, projInv);
            float depthDiff = geomPos.z - samplePos.z;

            // Tight 3D thickness check prevents foreground overhangs from stamping onto background surfaces
            float thickness = 0.22 + rayDist * 0.14;
            float planeHeight = dot(geomPos - viewPos, viewNormal);

            if (depthDiff > 0.025 && depthDiff < thickness && planeHeight > 0.08) {
                vec3 hitNormal = decodeNormal(texture(normalLightTex, sc.xy).rg);
                vec4 hitDirectData = texture(directLitTex, sc.xy);
                vec3 hitDirect = hitDirectData.rgb;
                float hitEmissiveFlag = hitDirectData.a;
                vec4 hitMatInfo = texture(matSpecTex, sc.xy);

                float hitSmoothness = hitMatInfo.r;
                float hitF0         = hitMatInfo.g;
                float hitEmission   = hitMatInfo.b;
                float hitMat        = hitMatInfo.a;

                // Never re-bounce direct HDR emitters or emitter-backed stained glass in SSGI (already lit by computeDirectionalBlocklight)
                // and never cast SSAO shadows from light blocks! Eliminates the 4 hexagonal blobs on grass and 5 stripes on walls.
                if (hitEmissiveFlag > 0.5 || isEmissiveMaterial(hitMat) || hitEmission > 0.02) {
                    break;
                }

                float facing = clamp(dot(hitNormal, -rayDir) * 0.85 + 0.25, 0.10, 1.0);
                float distAtten = 1.0 / (1.0 + 0.26 * rayDist * rayDist);

                // Material-dependent bounce multiplier on the HIT surface:
                // - Stone / rough terrain (hitSmoothness ~ 0.12): soft subtle diffuse bounce (0.45x)
                // - Polished stone (hitSmoothness ~ 0.58): medium bounce (1.10x)
                // - Glass / Stained Glass / Metal / Water: strong reflection/transmission bounce
                float hitReflectivity = mix(0.45, 1.65, smoothstep(0.15, 0.88, hitSmoothness))
                                      + hitF0 * 0.65;

                if (isMaterial(hitMat, MAT_STAINED_GLASS)) {
                    hitReflectivity = max(hitReflectivity, 1.35);
                    facing = max(facing, 0.65);
                } else if (isMaterial(hitMat, MAT_GLASS)) {
                    hitReflectivity = max(hitReflectivity, 1.20);
                }

                float hitWindow = smoothstep(0.025, 0.08, depthDiff) * smoothstep(thickness, thickness * 0.4, depthDiff);
                // Smooth firefly compression prevents blotchy colored spots
                vec3 clampedHit = hitDirect / (1.0 + getLuminance(hitDirect) * 1.15);
                rayHitRadiance = clampedHit * facing * distAtten * hitReflectivity * hitWindow;

                if (rayDist < 1.65 && !isMaterial(hitMat, MAT_STAINED_GLASS) && !isMaterial(hitMat, MAT_GLASS)) {
                    rayOccluded = clamp(1.0 - (rayDist / 1.65), 0.0, 1.0);
                }
                break;
            }
        }

        bounceAccum += rayHitRadiance;
        aoOcclusion += rayOccluded;
    }

    float receiverBounceScale = mix(0.60, 1.32, smoothstep(0.15, 0.85, receiverSmoothness)) + receiverF0 * 0.35;
    vec3 finalBounce = (bounceAccum / float(numRays)) * SSGI_INTENSITY * receiverBounceScale;

    // Never darken translucent glass/water with SSAO (prevents black mesh on glass!)
    float finalAO = isReceiverTranslucent ? 1.0 : clamp(1.0 - (aoOcclusion / float(numRays)) * 0.58, 0.42, 1.0);

    return vec4(finalBounce, finalAO);
}

// Edge-preserving Cross-Bilateral Filter:
// Uses a wider, softer spatial kernel on rough diffuse surfaces (like stone) so indirect light
// looks softly diffused, and a tighter kernel on glossy surfaces!
vec4 sampleBilateralSSGI(
    vec2 texCoord,
    vec3 centerNormal,
    float centerLinearDepth,
    float centerSmoothness,
    vec2 texelSize,
    sampler2D ssgiTex,
    sampler2D normalLightTex,
    sampler2D depthTex,
    float nearPlane,
    float farPlane
) {
    vec4 centerVal = texture(ssgiTex, texCoord);
    vec4 sumVal = centerVal * 0.26;
    float sumWeight = 0.26;

    float kernelScale = mix(1.55, 0.80, smoothstep(0.15, 0.85, centerSmoothness));

    const vec2 OFFSETS[8] = vec2[8](
        vec2(-1.5, -0.5), vec2( 1.5,  0.5),
        vec2(-0.5,  1.5), vec2( 0.5, -1.5),
        vec2(-2.5,  1.5), vec2( 2.5, -1.5),
        vec2( 1.5,  2.5), vec2(-1.5, -2.5)
    );

    for (int i = 0; i < 8; i++) {
        vec2 sampleUV = clamp(texCoord + OFFSETS[i] * texelSize * kernelScale, vec2(0.002), vec2(0.998));
        float sampleDepth = texture(depthTex, sampleUV).r;
        if (sampleDepth >= 0.9999) continue;

        float sampleLinDepth = linearizeDepth(sampleDepth, nearPlane, farPlane);
        vec3 sampleNormal = decodeNormal(texture(normalLightTex, sampleUV).rg);

        float normalWeight = pow(max(dot(centerNormal, sampleNormal), 0.0), 8.0);
        float depthDiff = abs(centerLinearDepth - sampleLinDepth) / max(centerLinearDepth, 0.5);
        float depthWeight = exp(-depthDiff * 18.0);

        float w = max(normalWeight * depthWeight, 0.001) * 0.0925;
        sumVal += texture(ssgiTex, sampleUV) * w;
        sumWeight += w;
    }

    return sumVal / max(sumWeight, 0.001);
}

#endif // SSGI_BOUNCE_GLSL
