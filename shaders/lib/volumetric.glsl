#ifndef VOLUMETRIC_GLSL
#define VOLUMETRIC_GLSL

#include "/lib/common.glsl"
#include "/lib/colors.glsl"
#include "/lib/shadow_distort.glsl"

// Henyey-Greenstein phase function for forward Mie scattering (Sun/Moon shafts)
float henyeyGreenstein(float cosTheta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cosTheta;
    return (1.0 - g2) / (4.0 * PI * pow(max(denom, 0.0001), 1.5));
}

vec3 applyVolumetricFogAndLightShafts(
    vec3 sceneColor,
    vec3 viewPos,
    vec3 playerPos,
    vec3 lightVecView,
    float blockLight,
    float skyLight,
    vec3 localBlockLightColor,
    float smoothHeldIntensity,
    vec3 heldLightColor,
    float rainStrength,
    int isEyeInWater,
    float dither,
    AtmosphereColors atm,
    sampler2D shadowTex0,
    sampler2D shadowTex1,
    sampler2D shadowColor0,
    mat4 shadowMV,
    mat4 shadowProj
) {
    #ifndef ENABLE_VOLUMETRIC_FOG
    return sceneColor;
    #endif

    float viewDist = length(viewPos);
    vec3 viewDir = viewPos / max(viewDist, 0.001);

    // Underwater volumetric scattering
    if (isEyeInWater == 1) {
        vec3 waterFogColor = vec3(0.03, 0.18, 0.26) * (atm.directLight * 0.45 + vec3(0.12));
        waterFogColor += localBlockLightColor * blockLight * 0.45 * COLORED_LIGHT_FOG_INFLUENCE;
        float waterFogFactor = 1.0 - exp(-viewDist * 0.055 * FOG_DENSITY_MULTIPLIER);
        return mix(sceneColor, waterFogColor, clamp(waterFogFactor, 0.0, 0.92));
    }

    // Mie scattering phase toward active celestial light (Sun or Moon)
    float cosTheta = dot(viewDir, lightVecView);
    float miePhase = henyeyGreenstein(cosTheta, 0.62);

    // Raymarch volumetric sun/moon shafts through distorted shadow map
    int steps = VOLUMETRIC_STEPS;
    float maxMarchDist = min(viewDist, min(SHADOW_DISTANCE * 0.85, 84.0));
    vec3 shaftAccum = vec3(0.0);

    if (skyLight > 0.02 || viewDist > 24.0) {
        for (int i = 0; i < steps; i++) {
            float t = (float(i) + dither) / float(steps);
            // Non-linear distribution concentrates samples closer to camera
            float marchDist = maxMarchDist * (t * t * 0.65 + t * 0.35);
            vec3 samplePlayerPos = (playerPos / max(viewDist, 0.001)) * marchDist;

            vec4 sView = shadowMV * vec4(samplePlayerPos, 1.0);
            vec4 sClip = shadowProj * sView;
            sClip.xyz /= sClip.w;
            sClip.xyz = distortShadowClipPos(sClip.xyz);
            vec3 sScreen = sClip.xyz * 0.5 + 0.5;

            if (sScreen.x > 0.002 && sScreen.x < 0.998 &&
                sScreen.y > 0.002 && sScreen.y < 0.998 &&
                sScreen.z > 0.0 && sScreen.z < 1.0) {

                float opaqueD = texture(shadowTex1, sScreen.xy).r;
                if (sScreen.z <= opaqueD) {
                    vec3 stepLight = vec3(1.0);
                    #ifdef SHADOW_COLORED_GLASS
                    float allD = texture(shadowTex0, sScreen.xy).r;
                    if (sScreen.z > allD) {
                        // Colored volumetric beam through stained glass!
                        vec4 glass = texture(shadowColor0, sScreen.xy);
                        stepLight = mix(vec3(1.0), glass.rgb * 1.35, clamp(glass.a, 0.0, 0.95));
                    }
                    #endif
                    shaftAccum += stepLight;
                }
            }
        }
        shaftAccum /= float(steps);
    }

    // Base atmospheric fog density (morning/sunset mist, rain fog, distance haze)
    float baseDensity = 0.0022 * FOG_DENSITY_MULTIPLIER;
    baseDensity *= (1.0 + atm.sunsetFactor * 1.45 + rainStrength * 2.8);

    // Height attenuation (thicker mist in valleys / near water level)
    float heightFactor = exp(- clamp(playerPos.y * 0.015, -0.5, 2.0));
    float fogOpticalDepth = viewDist * baseDensity * heightFactor;
    float fogFactor = clamp(1.0 - exp(-fogOpticalDepth), 0.0, 0.88);

    // Sky/Sun atmospheric fog color
    vec3 skyFogColor = mix(atm.skyHorizon, atm.directLight * 0.65, clamp(miePhase * 0.85, 0.0, 0.75));

    // Local Colored Blocklight Fog Influence ("光源の色によって霧に影響")
    // Both placed blocklights and handheld dynamic light tint nearby fog!
    float localLightFogWeight = pow(blockLight, 1.6) * COLORED_LIGHT_FOG_INFLUENCE;
    vec3 blockFogContribution = localBlockLightColor * localLightFogWeight * 0.55;

    // Handheld light volumetric mist halo near camera
    float handMist = smoothHeldIntensity * HANDLIGHT_INTENSITY * exp(-viewDist * 0.12) * 0.14 * COLORED_LIGHT_FOG_INFLUENCE;
    vec3 handFogContribution = heldLightColor * handMist;

    // Combine outdoor sky fog (scaled by skyLight) and indoor/cave colored light fog
    float outdoorWeight = clamp(skyLight * skyLight + smoothstep(32.0, 96.0, viewDist), 0.05, 1.0);
    vec3 combinedFogColor = skyFogColor * outdoorWeight + blockFogContribution;

    // Volumetric light shafts (God rays)
    float shaftIntensity = (0.14 + atm.sunsetFactor * 0.22 + rainStrength * 0.10) * FOG_DENSITY_MULTIPLIER;
    float distFactor = clamp(maxMarchDist / 56.0, 0.0, 1.0);
    vec3 godRays = atm.directLight * shaftAccum * (0.35 + miePhase * 1.45) * shaftIntensity * distFactor;

    vec3 outColor = mix(sceneColor, combinedFogColor, fogFactor);
    outColor += godRays + handFogContribution;

    return outColor;
}

#endif // VOLUMETRIC_GLSL

