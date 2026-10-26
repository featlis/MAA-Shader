#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform float wetness;
uniform mat4 gbufferModelViewInverse;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;
in vec3 vViewNormal;
flat in int vBlockId;

/* DRAWBUFFERS:012 */

void main() {
    vec4 texSample = texture(tex, vTexCoord);
    vec4 albedo = texSample * vec4(vColor.rgb, 1.0);
    float alpha = texSample.a * vColor.a;

    if (alpha < 0.1) {
        discard;
    }

    vec3 viewNormal = normalize(vViewNormal);
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);

    float matId = MAT_TERRAIN;
    float luma = getLuminance(albedo.rgb);
    float smoothness = clamp(0.15 + luma * 0.25, 0.10, 0.55);
    float f0 = 0.04;
    float emission = 0.0;

    // Classify material from block.properties ID
    if (vBlockId == 10001) {
        matId = MAT_FOLIAGE;
        smoothness = 0.22;
    } else if (vBlockId == 10100) {
        matId = MAT_EMISSIVE_WARM;
        emission = clamp(smoothstep(0.25, 0.85, luma) * 0.9 + 0.1, 0.2, 1.0);
    } else if (vBlockId == 10101) {
        matId = MAT_EMISSIVE_SOUL;
        emission = clamp(smoothstep(0.20, 0.80, max(albedo.b, luma)) * 0.9 + 0.1, 0.2, 1.0);
    } else if (vBlockId == 10102) {
        matId = MAT_EMISSIVE_RED;
        emission = clamp(smoothstep(0.20, 0.75, albedo.r) * 0.9 + 0.1, 0.2, 1.0);
    } else if (vBlockId == 10103) {
        matId = MAT_EMISSIVE_LAVA;
        emission = clamp(smoothstep(0.15, 0.75, albedo.r) * 0.95 + 0.15, 0.3, 1.0);
    } else if (vBlockId == 10104) {
        matId = MAT_EMISSIVE_AQUA;
        emission = clamp(smoothstep(0.30, 0.85, luma) * 0.9 + 0.15, 0.25, 1.0);
    } else if (vBlockId == 10105) {
        matId = MAT_EMISSIVE_END;
        emission = clamp(smoothstep(0.25, 0.85, luma) * 0.9 + 0.15, 0.25, 1.0);
    } else if (vBlockId == 10200) {
        matId = MAT_METALLIC;
        smoothness = clamp(0.68 + luma * 0.24, 0.65, 0.92);
        f0 = 0.65;
    } else if (vLmCoord.x > 0.965 && luma > 0.65) {
        if (albedo.b > albedo.r * 1.35) {
            matId = MAT_EMISSIVE_SOUL;
        } else if (albedo.r > albedo.g * 2.1 && albedo.r > albedo.b * 2.1) {
            matId = MAT_EMISSIVE_RED;
        } else {
            matId = MAT_EMISSIVE_WARM;
        }
        emission = 0.65;
    }

    // Apply outdoor rain wetness to upward-facing surfaces
    float outdoorWet = wetness * smoothstep(0.75, 0.95, vLmCoord.y) * clamp(worldNormal.y, 0.0, 1.0);
    if (outdoorWet > 0.01 && !isEmissiveMaterial(matId)) {
        smoothness = mix(smoothness, 0.88, outdoorWet * WETNESS_REFLECTION);
        f0 = mix(f0, 0.06, outdoorWet);
        albedo.rgb *= mix(1.0, 0.82, outdoorWet * (1.0 - f0));
    }

    gl_FragData[0] = vec4(albedo.rgb, 1.0);
    gl_FragData[1] = vec4(encodeNormal(viewNormal), vLmCoord.x, vLmCoord.y);
    gl_FragData[2] = vec4(smoothness, f0, emission, matId);
}
