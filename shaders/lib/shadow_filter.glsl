#ifndef SHADOW_FILTER_GLSL
#define SHADOW_FILTER_GLSL

#include "/lib/common.glsl"
#include "/lib/shadow_distort.glsl"

// Optimized 12-tap Poisson Disk
const vec2 POISSON_DISK[12] = vec2[12](
    vec2(-0.326212, -0.405810),
    vec2(-0.840144, -0.073580),
    vec2(-0.695914,  0.457137),
    vec2(-0.203345,  0.620716),
    vec2( 0.962340, -0.194983),
    vec2( 0.473434, -0.480026),
    vec2( 0.519456,  0.767022),
    vec2( 0.185461, -0.893124),
    vec2( 0.507431,  0.064425),
    vec2( 0.896420,  0.412458),
    vec2(-0.321940, -0.932615),
    vec2(-0.791559, -0.597710)
);

vec3 sampleDirectionalShadow(
    vec3 playerPos,
    vec3 worldNormal,
    float NoL,
    float dither,
    sampler2D shadowTex0,
    sampler2D shadowTex1,
    sampler2D shadowColor0,
    mat4 shadowMV,
    mat4 shadowProj
) {
    float distSq = dot(playerPos, playerPos);
    float maxDistSq = SHADOW_DISTANCE * SHADOW_DISTANCE;
    if (distSq >= maxDistSq) {
        return vec3(1.0);
    }

    // Distance fade near shadow boundary
    float edgeFade = smoothstep(maxDistSq * 0.82, maxDistSq, distSq);

    vec3 shadowScreen = worldToShadowScreen(playerPos, worldNormal, NoL, shadowMV, shadowProj);
    if (shadowScreen.x <= 0.001 || shadowScreen.x >= 0.999 ||
        shadowScreen.y <= 0.001 || shadowScreen.y >= 0.999 ||
        shadowScreen.z <= 0.000 || shadowScreen.z >= 1.000) {
        return vec3(1.0);
    }

    float depthBias = 0.00035;
    float receiverZ = shadowScreen.z - depthBias;

    // Rotation matrix from spatial dither
    float angle = dither * (2.0 * PI);
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);

    float baseTexel = (1.25 * SHADOW_SOFTNESS) / float(SHADOW_MAP_RESOLUTION);

    #ifdef SHADOW_CONTACT_HARDENING
    // 2-tap quick blocker distance check for contact hardening
    float blockerSum = 0.0;
    float blockerCount = 0.0;
    for (int b = 0; b < 2; b++) {
        vec2 bOffset = (rot * POISSON_DISK[b]) * baseTexel * 2.0;
        float bDepth = texture(shadowTex1, shadowScreen.xy + bOffset).r;
        if (receiverZ > bDepth) {
            blockerSum += (receiverZ - bDepth);
            blockerCount += 1.0;
        }
    }
    float avgBlockerDist = (blockerCount > 0.0) ? (blockerSum / blockerCount) : 0.0;
    // Scale penumbra radius: sharp near contact, wider soft penumbra further from caster
    float penumbraScale = clamp(0.65 + avgBlockerDist * 85.0, 0.65, 2.6);
    float filterRadius = baseTexel * penumbraScale;
    #else
    float filterRadius = baseTexel * 1.25;
    #endif

    vec3 shadowAccum = vec3(0.0);
    int sampleCount = SHADOW_PCF_SAMPLES;

    for (int i = 0; i < sampleCount; i++) {
        vec2 offset = (rot * POISSON_DISK[i]) * filterRadius;
        vec2 sampleUV = shadowScreen.xy + offset;

        float opaqueDepth = texture(shadowTex1, sampleUV).r;
        if (receiverZ > opaqueDepth) {
            // Fully blocked by opaque geometry
            shadowAccum += vec3(0.0);
        } else {
            #ifdef SHADOW_COLORED_GLASS
            float allDepth = texture(shadowTex0, sampleUV).r;
            if (receiverZ > allDepth) {
                // Blocked by translucent caster (stained glass / water)
                vec4 glassCol = texture(shadowColor0, sampleUV);
                // Transmit tinted light proportional to glass color & opacity
                vec3 tinted = mix(vec3(1.0), glassCol.rgb * 1.25, clamp(glassCol.a * 1.15, 0.0, 0.92));
                shadowAccum += tinted * (1.0 - glassCol.a * 0.45);
            } else {
                shadowAccum += vec3(1.0);
            }
            #else
            shadowAccum += vec3(1.0);
            #endif
        }
    }

    vec3 finalShadow = shadowAccum / float(sampleCount);
    return mix(finalShadow, vec3(1.0), edgeFade);
}

#endif // SHADOW_FILTER_GLSL

