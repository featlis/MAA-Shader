#ifndef COLORS_GLSL
#define COLORS_GLSL

#include "/lib/common.glsl"

// ============================================================================
// Light Source Color Palette (Linear HDR space)
// ============================================================================
const vec3 COLOR_TORCH_CORE = vec3(1.00, 0.85, 0.56);
const vec3 COLOR_TORCH_WARM = vec3(1.00, 0.56, 0.20);
const vec3 COLOR_GOLD_GLOW  = vec3(1.00, 0.72, 0.28);
const vec3 COLOR_SOUL_CYAN  = vec3(0.12, 0.82, 1.00);
const vec3 COLOR_REDSTONE   = vec3(1.00, 0.10, 0.05);
const vec3 COLOR_LAVA_FIRE  = vec3(1.00, 0.36, 0.04);
const vec3 COLOR_SEA_AQUA   = vec3(0.66, 0.96, 1.00);
const vec3 COLOR_END_VIOLET = vec3(0.88, 0.64, 1.00);

// Returns the characteristic linear light color for an emissive material ID
vec3 getEmissiveColorFromMat(float matId, float blockLightLevel) {
    if (isMaterial(matId, MAT_EMISSIVE_SOUL)) {
        return COLOR_SOUL_CYAN;
    } else if (isMaterial(matId, MAT_EMISSIVE_RED)) {
        return COLOR_REDSTONE;
    } else if (isMaterial(matId, MAT_EMISSIVE_LAVA)) {
        return COLOR_LAVA_FIRE;
    } else if (isMaterial(matId, MAT_EMISSIVE_AQUA)) {
        return COLOR_SEA_AQUA;
    } else if (isMaterial(matId, MAT_EMISSIVE_END)) {
        return COLOR_END_VIOLET;
    } else if (isMaterial(matId, MAT_EMISSIVE_GOLD)) {
        return mix(COLOR_GOLD_GLOW, COLOR_TORCH_CORE, smoothstep(0.70, 1.0, blockLightLevel) * 0.45);
    }
    // Warm torch/lantern/campfire with blackbody temperature shift near core
    return mix(COLOR_TORCH_WARM, COLOR_TORCH_CORE, smoothstep(0.68, 1.0, blockLightLevel));
}

// Combines material ID spectral color with the actual chromaticity of the emitter block's texture
vec3 getEmissiveColorFromMatAndTex(float matId, vec3 texAlbedoLinear, float blockLightLevel) {
    vec3 basePalette = getEmissiveColorFromMat(matId, blockLightLevel);
    float texMax = max(texAlbedoLinear.r, max(texAlbedoLinear.g, texAlbedoLinear.b));
    if (texMax > 0.05) {
        vec3 texChroma = texAlbedoLinear / texMax;
        // Boost saturation of texture chroma so light emission is vivid and distinct
        float luma = getLuminance(texChroma);
        vec3 vividChroma = clamp(mix(vec3(luma), texChroma, 1.45), vec3(0.08), vec3(1.0));
        return normalize(mix(basePalette, vividChroma, 0.42)) * length(basePalette);
    }
    return basePalette;
}

// Extracts saturated stained-glass transmission color from linear glass albedo
vec3 getStainedGlassTransmission(vec3 glassAlbedoLinear, float glassAlpha) {
    float maxC = max(glassAlbedoLinear.r, max(glassAlbedoLinear.g, glassAlbedoLinear.b));
    vec3 normColor = (maxC > 0.01) ? (glassAlbedoLinear / maxC) : vec3(1.0);
    // Deepen chromatic saturation according to Beer-Lambert optical absorption
    vec3 opticalFilter = pow(clamp(normColor, vec3(0.03), vec3(1.0)), vec3(1.25));
    float tintStrength = clamp(glassAlpha * 1.35, 0.35, 0.94);
    return mix(vec3(1.0), opticalFilter * 1.22, tintStrength);
}

// Energy-preserving optical tint when a light source passes through colored stained glass:
// Shifts the light's hue/chromaticity to the stained glass color without crushing brightness to black!
vec3 tintLightByStainedGlass(vec3 baseLightColor, vec3 pureGlassLinear, float tintWeight) {
    float maxG = max(pureGlassLinear.r, max(pureGlassLinear.g, pureGlassLinear.b));
    if (maxG <= 0.01) return baseLightColor;
    vec3 glassChroma = pureGlassLinear / maxG;
    float gLuma = getLuminance(glassChroma);
    vec3 vividGlass = clamp(mix(vec3(gLuma), glassChroma, 1.55), vec3(0.05), vec3(1.0));
    float baseEnergy = max(length(baseLightColor), 1.15);
    vec3 targetColoredLight = normalize(vividGlass) * baseEnergy * 1.12;
    return mix(baseLightColor, targetColoredLight, clamp(tintWeight, 0.0, 0.95));
}

// Infers light color from held item ID (mapped via item.properties)
vec3 getHeldItemLightColor(int itemId) {
    // 10101: Soul Torch / Soul Lantern / Soul Campfire
    if (itemId == 10101) return COLOR_SOUL_CYAN;
    // 10102: Redstone Torch / Redstone Block
    if (itemId == 10102) return COLOR_REDSTONE;
    // 10103: Lava Bucket / Magma / Blaze Rod
    if (itemId == 10103) return COLOR_LAVA_FIRE;
    // 10104: Sea Lantern / Conduit / Glow Ink / Verdant Froglight
    if (itemId == 10104) return COLOR_SEA_AQUA;
    // 10105: End Rod / Amethyst / Crying Obsidian / Pearlescent Froglight
    if (itemId == 10105) return COLOR_END_VIOLET;
    // 10106: Glowstone / Shroomlight / Jack o'Lantern / Ochre Froglight
    if (itemId == 10106) return COLOR_GOLD_GLOW;
    // Default warm torch / lantern
    return mix(COLOR_TORCH_WARM, COLOR_TORCH_CORE, 0.45);
}

// ============================================================================
// Celestial & Atmospheric Colors (Cinematic-Realistic Day/Night Cycle)
// ============================================================================
struct AtmosphereColors {
    vec3 directLight;
    vec3 skyZenith;
    vec3 skyHorizon;
    vec3 groundBounce;
    float dayFactor;
    float sunsetFactor;
    float nightFactor;
};

AtmosphereColors getAtmosphereColors(float sunElevation, float rainStrength) {
    AtmosphereColors atm;

    // sunElevation is dot(sunVecWorld, vec3(0, 1, 0)) in [-1, 1]
    atm.dayFactor    = smoothstep(-0.05, 0.25, sunElevation);
    atm.nightFactor  = smoothstep(0.08, -0.15, sunElevation);
    atm.sunsetFactor = clamp(1.0 - abs(sunElevation * 3.8), 0.0, 1.0) * smoothstep(-0.18, 0.02, sunElevation);

    // Direct Sunlight / Moonlight
    vec3 noonSun   = vec3(1.00, 0.96, 0.88) * 2.25;
    vec3 sunsetSun = vec3(1.00, 0.46, 0.16) * 1.75;
    vec3 moonLight = vec3(0.30, 0.46, 0.72) * 0.44; // Visible cinematic moonlight

    atm.directLight = mix(moonLight, noonSun, atm.dayFactor);
    atm.directLight = mix(atm.directLight, sunsetSun, atm.sunsetFactor * 0.85);

    // Sky Dome Zenith
    vec3 dayZenith    = vec3(0.14, 0.36, 0.78);
    vec3 sunsetZenith = vec3(0.20, 0.25, 0.52);
    vec3 nightZenith  = vec3(0.025, 0.042, 0.095);

    atm.skyZenith = mix(nightZenith, dayZenith, atm.dayFactor);
    atm.skyZenith = mix(atm.skyZenith, sunsetZenith, atm.sunsetFactor * 0.65);

    // Sky Horizon
    vec3 dayHorizon    = vec3(0.45, 0.66, 0.92);
    vec3 sunsetHorizon = vec3(0.96, 0.44, 0.18);
    vec3 nightHorizon  = vec3(0.045, 0.072, 0.14);

    atm.skyHorizon = mix(nightHorizon, dayHorizon, atm.dayFactor);
    atm.skyHorizon = mix(atm.skyHorizon, sunsetHorizon, atm.sunsetFactor * 0.85);

    // Weather / Rain desaturation and darkening
    if (rainStrength > 0.001) {
        vec3 rainDirect  = vec3(0.32, 0.36, 0.42) * mix(0.25, 0.75, atm.dayFactor);
        vec3 rainSky     = vec3(0.22, 0.26, 0.32) * mix(0.20, 0.85, atm.dayFactor);
        atm.directLight  = mix(atm.directLight, rainDirect, rainStrength * 0.85);
        atm.skyZenith    = mix(atm.skyZenith, rainSky * 0.85, rainStrength);
        atm.skyHorizon   = mix(atm.skyHorizon, rainSky * 1.05, rainStrength);
    }

    // Ground warm bounce approximation
    atm.groundBounce = (atm.skyZenith * 0.38 + atm.directLight * 0.16) * vec3(0.88, 0.82, 0.72);

    return atm;
}

#endif // COLORS_GLSL
