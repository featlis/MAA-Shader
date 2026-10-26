#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;

/* DRAWBUFFERS:012 */

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    gl_FragData[0] = vec4(albedo.rgb, albedo.a * 0.65);
    gl_FragData[1] = vec4(0.5, 0.5, vLmCoord.x, vLmCoord.y);
    gl_FragData[2] = vec4(0.10, 0.04, 0.0, MAT_TERRAIN);
}
