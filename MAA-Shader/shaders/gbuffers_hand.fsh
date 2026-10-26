#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;
in vec3 vViewNormal;

/* DRAWBUFFERS:012 */

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    vec3 viewNormal = normalize(vViewNormal);
    float luma = getLuminance(albedo.rgb);
    int maxHeldLight = max(heldBlockLightValue, heldBlockLightValue2);
    float emission = 0.0;

    if (maxHeldLight > 0) {
        emission = smoothstep(0.42, 0.85, luma) * (float(maxHeldLight) / 15.0) * 0.85;
    }

    gl_FragData[0] = vec4(albedo.rgb, albedo.a);
    gl_FragData[1] = vec4(encodeNormal(viewNormal), vLmCoord.x, vLmCoord.y);
    gl_FragData[2] = vec4(0.30, 0.04, emission, MAT_HAND);
}
