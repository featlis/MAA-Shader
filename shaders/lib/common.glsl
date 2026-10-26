#ifndef COMMON_GLSL
#define COMMON_GLSL

#include "/lib/settings.glsl"

const float PI = 3.14159265359;
const float HALF_PI = 1.57079632679;
const float INV_PI = 0.31830988618;
const float EPSILON = 1e-5;

// ============================================================================
// Material ID Encoding (Stored in colortex2.a, spaced >= 0.04 apart for RGBA8)
// ============================================================================
const float MAT_SKY            = 0.00;
const float MAT_TERRAIN        = 0.08; // Rough stone, cobblestone, dirt, wood (diffuse-dominant)
const float MAT_HAND           = 0.14; // First-person held item / hand
const float MAT_FOLIAGE        = 0.20; // Subsurface scattering (leaves, grass, plants)
const float MAT_EMISSIVE_WARM  = 0.30; // Flame Torch, Lantern, Campfire, Candle, Fire
const float MAT_EMISSIVE_GOLD  = 0.36; // Glowstone, Shroomlight, Jack o'Lantern, Ochre Froglight, Copper Bulb
const float MAT_EMISSIVE_SOUL  = 0.42; // Soul Torch, Soul Lantern, Soul Fire (Cyan)
const float MAT_EMISSIVE_RED   = 0.50; // Redstone Torch, Redstone Block, Redstone Lamp/Ore
const float MAT_EMISSIVE_LAVA  = 0.58; // Lava, Magma Block (Deep Orange-Red)
const float MAT_EMISSIVE_AQUA  = 0.66; // Sea Lantern, Conduit, Verdant Froglight, Sea Pickle
const float MAT_EMISSIVE_END   = 0.74; // End Rod, Crying Obsidian, Respawn Anchor, Amethyst, Beacon
const float MAT_METALLIC       = 0.82; // High-gloss Iron, Gold, Copper, Diamond, Emerald, Netherite
const float MAT_POLISHED       = 0.87; // Semi-gloss Polished Stone, Quartz, Glazed Terracotta
const float MAT_WATER          = 0.91; // Water surface
const float MAT_GLASS          = 0.95; // Clear Glass, Ice, Packed/Blue Ice
const float MAT_STAINED_GLASS  = 0.99; // Colored Stained Glass & Panes, Tinted Glass

bool isMaterial(float matAlpha, float targetMat) {
    return abs(matAlpha - targetMat) < 0.018;
}

bool isEmissiveMaterial(float matAlpha) {
    return matAlpha >= 0.27 && matAlpha <= 0.77;
}

bool isGlossyMaterial(float matAlpha) {
    return matAlpha >= 0.80;
}

// ============================================================================
// Octahedral Normal Encoding / Decoding (2-channel [0, 1] storage)
// ============================================================================
vec2 signNotZero(vec2 v) {
    return vec2((v.x >= 0.0) ? 1.0 : -1.0, (v.y >= 0.0) ? 1.0 : -1.0);
}

vec2 encodeNormal(vec3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z) + EPSILON);
    if (n.z < 0.0) {
        n.xy = (1.0 - abs(n.yx)) * signNotZero(n.xy);
    }
    return n.xy * 0.5 + 0.5;
}

vec3 decodeNormal(vec2 e) {
    vec2 f = e * 2.0 - 1.0;
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = clamp(-n.z, 0.0, 1.0);
    n.x += (n.x >= 0.0) ? -t : t;
    n.y += (n.y >= 0.0) ? -t : t;
    return normalize(n);
}

// ============================================================================
// Coordinate & Depth Transformations
// ============================================================================
float linearizeDepth(float depth, float nearPlane, float farPlane) {
    return (nearPlane * farPlane) / (farPlane - depth * (farPlane - nearPlane));
}

vec3 screenToView(vec2 texCoord, float depth, mat4 projInverse) {
    vec4 ndc = vec4(texCoord * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = projInverse * ndc;
    return viewPos.xyz / viewPos.w;
}

vec3 viewToScreen(vec3 viewPos, mat4 proj) {
    vec4 clipPos = proj * vec4(viewPos, 1.0);
    vec3 ndc = clipPos.xyz / clipPos.w;
    return ndc * 0.5 + 0.5;
}

vec3 viewToWorld(vec3 viewPos, mat4 modelViewInverse) {
    return (modelViewInverse * vec4(viewPos, 1.0)).xyz;
}

// ============================================================================
// Noise & Dithering Functions (Zero-texture ALU noise)
// ============================================================================
// Interleaved Gradient Noise (Jimenez 2014) - High frequency spatial dither
float interleavedGradientNoise(vec2 pixelCoord, int frame) {
    pixelCoord += float(frame % 64) * 5.588238;
    return fract(52.9829189 * fract(0.06711056 * pixelCoord.x + 0.00583715 * pixelCoord.y));
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Bayer 4x4 ordered dither
float bayer4x4(vec2 pos) {
    ivec2 p = ivec2(mod(pos, 4.0));
    int index = p.x + p.y * 4;
    const float bayer[16] = float[16](
         0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
        12.0/16.0,  4.0/16.0, 14.0/16.0,  6.0/16.0,
         3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
        15.0/16.0,  7.0/16.0, 13.0/16.0,  5.0/16.0
    );
    return bayer[index];
}

// ============================================================================
// Color & Physically-Based BRDF Utilities (Oren-Nayar + Cook-Torrance GGX)
// ============================================================================
vec3 toLinear(vec3 srgb) {
    return pow(max(srgb, vec3(0.0)), vec3(2.2));
}

vec3 toSRGB(vec3 linear) {
    return pow(max(linear, vec3(0.0)), vec3(1.0 / 2.2));
}

float getLuminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

float fresnelSchlickScalar(float cosTheta, float F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Oren-Nayar Rough Diffuse BRDF (models wide diffuse backscattering on rough stone/dirt)
float orenNayarDiffuse(vec3 L, vec3 V, vec3 N, float roughness) {
    float NoL = max(dot(N, L), 0.0);
    float NoV = max(dot(N, V), 0.001);
    if (NoL <= 0.0) return 0.0;

    float sigma2 = roughness * roughness;
    float A = 1.0 - 0.5 * (sigma2 / (sigma2 + 0.33));
    float B = 0.45 * (sigma2 / (sigma2 + 0.09));

    float LoV = dot(L, V);
    float s = LoV - NoL * NoV;
    float t = (s <= 0.0) ? 1.0 : max(NoL, NoV);

    return NoL * (A + B * (s / max(t, EPSILON)));
}

// Trowbridge-Reitz GGX Normal Distribution Function D(h)
float distributionGGX(float NoH, float roughness) {
    float a = max(roughness * roughness, 0.0025);
    float a2 = a * a;
    float denom = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * denom * denom, EPSILON);
}

// Smith-Schlick GGX Geometry Shadowing-Masking Function G(l, v)
float geometrySchlickGGX(float NoV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) * 0.125;
    return NoV / max(NoV * (1.0 - k) + k, EPSILON);
}

float geometrySmithGGX(float NoV, float NoL, float roughness) {
    return geometrySchlickGGX(NoV, roughness) * geometrySchlickGGX(NoL, roughness);
}

// Full Energy-Conserving Cook-Torrance Microfacet BRDF + Oren-Nayar Diffuse
void evaluatePBRSurface(
    vec3 N,
    vec3 V,
    vec3 L,
    vec3 albedoLinear,
    float smoothness,
    float f0Scalar,
    float matId,
    out vec3 outDiffuseBRDF,
    out vec3 outSpecularBRDF
) {
    float roughness = clamp(1.0 - smoothness, 0.03, 0.98);
    float NoL = max(dot(N, L), 0.0);
    float NoV = max(dot(N, V), 0.001);

    if (NoL <= 0.0) {
        outDiffuseBRDF = vec3(0.0);
        outSpecularBRDF = vec3(0.0);
        return;
    }

    vec3 H = normalize(V + L);
    float NoH = max(dot(N, H), 0.0);
    float VoH = max(dot(V, H), 0.0);

    bool isMetal = isMaterial(matId, MAT_METALLIC);
    float metalness = isMetal ? clamp((f0Scalar - 0.25) / 0.65, 0.55, 0.92) : 0.0;

    // Metallic F0 is tinted by surface albedo (Gold, Copper, Iron, Diamond); dielectric F0 is achromatic
    vec3 F0 = mix(vec3(f0Scalar), mix(vec3(f0Scalar), albedoLinear * 1.15, 0.85), metalness);

    vec3 F = fresnelSchlick(VoH, F0);
    float D = distributionGGX(NoH, roughness);
    float G = geometrySmithGGX(NoV, NoL, roughness);

    // Cook-Torrance microfacet specular: (D * G * F) / (4 * NoV * NoL) * NoL = (D * G * F) / (4 * NoV)
    vec3 specBRDF = (D * G * F) / max(4.0 * NoV, 0.005);

    // Physical scale: rough stone (smoothness ~0.12) has wide, very soft sheen;
    // glass/metals (smoothness ~0.90+) have crisp, intense specular reflection
    float glossEmphasis = mix(0.18, 1.45, smoothstep(0.15, 0.85, smoothness));
    outSpecularBRDF = min(specBRDF * glossEmphasis * SPECULAR_STRENGTH, vec3(18.0));

    // Energy conservation: light reflected as specular cannot also scatter as diffuse
    vec3 kS = clamp(F, vec3(0.0), vec3(0.95));
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metalness * 0.78);

    float roughDiffuse = orenNayarDiffuse(L, V, N, roughness);
    outDiffuseBRDF = kD * roughDiffuse;
}

// ============================================================================
// Distant Light Scintillation & Flame Flicker (Air Turbulence Simulation)
// ============================================================================
float computeLightShimmer(vec3 worldPos, float viewDist, float time, bool isFlame) {
    float shimmer = 1.0;

    // Subtle natural flame flicker for torches, lanterns, campfires, lava
    if (isFlame) {
        float pPhase = dot(floor(worldPos * 2.0 + 0.5), vec3(1.73, 2.91, 3.47));
        float flicker = sin(time * 7.8 + pPhase) * 0.5
                      + sin(time * 14.3 - pPhase * 1.7) * 0.3
                      + cos(time * 21.1 + pPhase * 0.8) * 0.2;
        shimmer += flicker * 0.055;
    }

    // Distant atmospheric scintillation (twinkling/wavering of distant lights > 14m)
    float distFactor = smoothstep(14.0, 52.0, viewDist) * DISTANT_LIGHT_SHIMMER;
    if (distFactor > 0.001) {
        float spatialPhase = dot(worldPos, vec3(0.85, 1.35, 0.95));
        float turb1 = sin(time * 9.5 + spatialPhase);
        float turb2 = cos(time * 16.2 - spatialPhase * 1.4 + worldPos.y * 2.1);
        float turb3 = sin(time * 23.7 + worldPos.x * 1.9 - worldPos.z * 1.6);
        float scintillation = (turb1 * 0.45 + turb2 * 0.35 + turb3 * 0.20);
        shimmer *= (1.0 + scintillation * 0.14 * distFactor);
    }

    return clamp(shimmer, 0.75, 1.30);
}

#endif // COMMON_GLSL
