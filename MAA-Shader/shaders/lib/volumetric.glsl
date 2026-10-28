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
        vec3 waterFogColor = vec3(0.02, 0.16, 0.24) * (atm.directLight * 0.42 + vec3(0.10));
        waterFogColor += localBlockLightColor * pow(blockLight, 2.0) * 0.35 * COLORED_LIGHT_FOG_INFLUENCE;
        float waterFogFactor = 1.0 - exp(-viewDist * 0.048 * FOG_DENSITY_MULTIPLIER);
        return mix(sceneColor, waterFogColor, clamp(waterFogFactor, 0.0, 0.90));
    }

    // Mie scattering phase toward active celestial light (Sun or Moon)
    float cosTheta = dot(viewDir, lightVecView);
    float miePhase = henyeyGreenstein(cosTheta, 0.68);

    // Raymarch volumetric sun/moon shafts through distorted shadow map
    int steps = VOLUMETRIC_STEPS;
    float maxMarchDist = min(viewDist, min(SHADOW_DISTANCE * 0.85, 84.0));
    vec3 shaftAccum = vec3(0.0);
    float coloredBeamWeight = 0.0;

    if ((skyLight > 0.05 || viewDist > 22.0) && viewDist > 6.0) {
        for (int i = 0; i < steps; i++) {
            float t = (float(i) + dither) / float(steps);
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
                    float glassDist = sScreen.z - allD;
                    if (glassDist > 0.0001 && glassDist < 0.025) {
                        // Localized colored volumetric beam through stained glass (fades smoothly behind glass)
                        float beamFade = smoothstep(0.025, 0.002, glassDist);
                        vec4 glass = texture(shadowColor0, sScreen.xy);
                        vec3 glassTrans = getStainedGlassTransmission(toLinear(glass.rgb), glass.a) * 1.25;
                        stepLight = mix(vec3(1.0), glassTrans, beamFade);
                        coloredBeamWeight += beamFade;
                    }
                    #endif
                    shaftAccum += stepLight;
                }
            }
        }
        shaftAccum /= float(steps);
        coloredBeamWeight /= float(steps);
    }

    // Near-camera crystal-clear zone: zero fog haze within 18m (4m in rain)
    float clearZoneMeters = mix(18.0, 4.0, rainStrength);
    float effectiveFogDist = max(viewDist - clearZoneMeters, 0.0);

    // Base atmospheric fog density (distance haze, sunset mist, rain fog)
    float baseDensity = 0.0013 * FOG_DENSITY_MULTIPLIER;
    baseDensity *= (1.0 + atm.sunsetFactor * 1.25 + rainStrength * 2.6);

    float heightFactor = exp(-clamp(playerPos.y * 0.015, -0.4, 2.0));
    float fogOpticalDepth = effectiveFogDist * baseDensity * heightFactor;
    float fogFactor = clamp(1.0 - exp(-fogOpticalDepth), 0.0, 0.82);

    // Sky/Sun atmospheric fog color
    vec3 skyFogColor = mix(atm.skyHorizon, atm.directLight * 0.62, clamp(miePhase * 0.75, 0.0, 0.70));

    // Local Colored Blocklight Fog Influence (only tints actual distance fog & close emitter core)
    float localLightFogWeight = pow(blockLight, 2.4) * COLORED_LIGHT_FOG_INFLUENCE;
    vec3 blockFogContribution = localBlockLightColor * localLightFogWeight * 0.38;

    float outdoorWeight = clamp(skyLight * skyLight + smoothstep(36.0, 110.0, viewDist), 0.02, 1.0);
    vec3 combinedFogColor = skyFogColor * outdoorWeight + blockFogContribution;

    // Volumetric light shafts (God rays): gated by distance and forward Mie phase so nearby blocks stay crystal clear
    float shaftDistGate = smoothstep(8.0, 48.0, viewDist);
    float stainedGlassGate = mix(shaftDistGate, smoothstep(2.0, 16.0, viewDist), clamp(coloredBeamWeight * 2.0, 0.0, 1.0));
    float shaftIntensity = (0.065 + atm.sunsetFactor * 0.14 + rainStrength * 0.06) * FOG_DENSITY_MULTIPLIER;
    vec3 godRays = atm.directLight * shaftAccum * (0.15 + miePhase * 1.55) * shaftIntensity * stainedGlassGate;

    vec3 outColor = mix(sceneColor, combinedFogColor, fogFactor);
    outColor += godRays;

    return outColor;
}

#endif // VOLUMETRIC_GLSL
