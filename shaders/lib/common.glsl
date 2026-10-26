#ifndef COMMON_GLSL
#define COMMON_GLSL

#include "/lib/settings.glsl"

const float PI = 3.14159265359;
const float HALF_PI = 1.57079632679;
const float INV_PI = 0.31830988618;
const float EPSILON = 1e-5;

// ============================================================================
// Material ID Encoding (Stored in colortex0.a)
// ============================================================================
const float MAT_SKY            = 0.00;
const float MAT_TERRAIN        = 0.10;
const float MAT_FOLIAGE        = 0.20; // Subsurface scattering (leaves, grass, plants)
const float MAT_EMISSIVE_WARM  = 0.30; // Torch, Lantern, Glowstone, Campfire, Shroomlight
const float MAT_EMISSIVE_SOUL  = 0.40; // Soul Torch, Soul Lantern, Soul Fire (Cyan)
const float MAT_EMISSIVE_RED   = 0.50; // Redstone Torch, Redstone Block, Redstone Lamp
const float MAT_EMISSIVE_LAVA  = 0.60; // Lava, Magma Block (Deep Orange-Red)
const float MAT_EMISSIVE_AQUA  = 0.70; // Sea Lantern, Conduit, Soul/Aqua glow
const float MAT_EMISSIVE_END   = 0.75; // End Rod, Amethyst, Crying Obsidian, Froglight
const float MAT_METALLIC       = 0.80; // Iron, Gold, Copper, Diamond, Polished Stone
const float MAT_WATER          = 0.90; // Water surface
const float MAT_GLASS          = 0.95; // Translucent stained glass / ice
const float MAT_HAND           = 0.15; // First-person held item / hand

bool isMaterial(float matAlpha, float targetMat) {
    return abs(matAlpha - targetMat) < 0.025;
}

bool isEmissiveMaterial(float matAlpha) {
    return matAlpha >= 0.275 && matAlpha <= 0.775;
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
    n.xy += (n.xy >= vec2(0.0)) ? vec2(-t) : vec2(t);
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
// Color & BRDF Utilities
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

#endif // COMMON_GLSL

