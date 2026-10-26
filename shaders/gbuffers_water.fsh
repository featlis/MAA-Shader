#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform float frameTimeCounter;
uniform mat4 gbufferModelView;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;
in vec3 vViewNormal;
in vec3 vWorldPos;
flat in int vBlockId;

/* DRAWBUFFERS:012 */

vec3 getWaterWaveNormal(vec3 worldPos, float time) {
    vec2 p = worldPos.xz;
    float t = time * 1.65;

    float dHx = 0.0;
    float dHz = 0.0;

    float p1 = p.x * 1.4 + p.y * 0.8 + t;
    dHx += cos(p1) * 1.4 * 0.045;
    dHz += cos(p1) * 0.8 * 0.045;

    float p2 = p.x * 0.9 - p.y * 1.7 + t * 1.25;
    dHx += cos(p2) * 0.9 * 0.032;
    dHz -= cos(p2) * 1.7 * 0.032;

    float p3 = p.x * 3.1 + p.y * 2.6 - t * 1.8;
    dHx += cos(p3) * 3.1 * 0.012;
    dHz += cos(p3) * 2.6 * 0.012;

    dHx *= WATER_WAVE_STRENGTH;
    dHz *= WATER_WAVE_STRENGTH;

    return normalize(vec3(-dHx, 1.0, -dHz));
}

void main() {
    vec4 texSample = texture(tex, vTexCoord);
    vec4 albedo = texSample * vColor;

    if (albedo.a < 0.04) {
        discard;
    }

    vec3 viewNormal = normalize(vViewNormal);
    float smoothness = 0.94;
    float f0 = 0.06;
    float outAlpha = albedo.a;
    float matId = MAT_GLASS;

    if (vBlockId == 10008) {
        vec3 waveWorldNormal = getWaterWaveNormal(vWorldPos, frameTimeCounter);
        viewNormal = normalize(mat3(gbufferModelView) * waveWorldNormal);

        float waterLuma = getLuminance(albedo.rgb);
        albedo.rgb = mix(vec3(0.04, 0.20, 0.28), albedo.rgb * vec3(0.22, 0.62, 0.78), 0.35) * (0.65 + waterLuma * 0.7);
        outAlpha = 0.50;
        smoothness = 0.96;
        f0 = 0.05;
        matId = MAT_WATER;
    } else if (vBlockId == 10009) {
        // Stained Glass & Panes: enrich chromatic saturation and set high-gloss optical properties
        float luma = getLuminance(albedo.rgb);
        albedo.rgb = clamp(mix(vec3(luma), albedo.rgb, 1.40), vec3(0.02), vec3(1.0));
        outAlpha = clamp(albedo.a * 0.72, 0.28, 0.78);
        smoothness = 0.96;
        f0 = 0.06;
        matId = MAT_STAINED_GLASS;
    } else {
        // Clear Glass, Ice, Packed Ice, Slime, Honey
        smoothness = 0.94;
        f0 = 0.06;
        matId = MAT_GLASS;
    }

    gl_FragData[0] = vec4(albedo.rgb, outAlpha);
    gl_FragData[1] = vec4(encodeNormal(viewNormal), vLmCoord.x, vLmCoord.y);
    gl_FragData[2] = vec4(smoothness, f0, 0.0, matId);
}
