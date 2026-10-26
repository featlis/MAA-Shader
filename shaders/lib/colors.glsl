#ifndef COLORS_GLSL
#define COLORS_GLSL

#include "/lib/common.glsl"

// ============================================================================
// Light Source Color Palette (Linear HDR space)
// ============================================================================
const vec3 COLOR_TORCH_CORE = vec3(1.00, 0.82, 0.50);
const vec3 COLOR_TORCH_WARM = vec3(1.00, 0.58, 0.22);
const vec3 COLOR_SOUL_CYAN  = vec3(0.16, 0.78, 1.00);
const vec3 COLOR_REDSTONE   = vec3(1.00, 0.12, 0.07);
const vec3 COLOR_LAVA_FIRE  = vec3(1.00, 0.40, 0.06);
const vec3 COLOR_SEA_AQUA   = vec3(0.42, 0.94, 0.88);
const vec3 COLOR_END_VIOLET = vec3(0.86, 0.70, 1.00);

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
    }
    // Warm torch/lantern/glowstone with blackbody temperature shift near core
    return mix(COLOR_TORCH_WARM, COLOR_TORCH_CORE, smoothstep(0.65, 1.0, blockLightLevel));
}

// Infers light color from held item ID (mapped via item.properties or standard IDs)
vec3 getHeldItemLightColor(int itemId) {
    // 10101: Soul Torch / Soul Lantern / Soul Campfire
    if (itemId == 10101) return COLOR_SOUL_CYAN;
    // 10102: Redstone Torch / Redstone Block
    if (itemId == 10102) return COLOR_REDSTONE;
    // 10103: Lava Bucket / Magma / Blaze Rod
    if (itemId == 10103) return COLOR_LAVA_FIRE;
    // 10104: Sea Lantern / Conduit / Glow Ink
    if (itemId == 10104) return COLOR_SEA_AQUA;
    // 10105: End Rod / Amethyst / Crying Obsidian
    if (itemId == 10105) return COLOR_END_VIOLET;
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
    vec3 noonSun   = vec3(1.00, 0.95, 0.86) * 2.15;
    vec3 sunsetSun = vec3(1.00, 0.46, 0.16) * 1.65;
    vec3 moonLight = vec3(0.30, 0.44, 0.68) * 0.42; // Visible cinematic moonlight (not pitch black!)

    atm.directLight = mix(moonLight, noonSun, atm.dayFactor);
    atm.directLight = mix(atm.directLight, sunsetSun, atm.sunsetFactor * 0.85);

    // Sky Dome Zenith
    vec3 dayZenith    = vec3(0.16, 0.38, 0.78);
    vec3 sunsetZenith = vec3(0.22, 0.26, 0.52);
    vec3 nightZenith  = vec3(0.035, 0.055, 0.11);

    atm.skyZenith = mix(nightZenith, dayZenith, atm.dayFactor);
    atm.skyZenith = mix(atm.skyZenith, sunsetZenith, atm.sunsetFactor * 0.65);

    // Sky Horizon
    vec3 dayHorizon    = vec3(0.48, 0.68, 0.92);
    vec3 sunsetHorizon = vec3(0.95, 0.45, 0.20);
    vec3 nightHorizon  = vec3(0.06, 0.09, 0.16);

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
    atm.groundBounce = (atm.skyZenith * 0.4 + atm.directLight * 0.18) * vec3(0.88, 0.82, 0.72);

    return atm;
}

#endif // COLORS_GLSL

