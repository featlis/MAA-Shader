#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec4 vColor;

/* DRAWBUFFERS:012 */

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    gl_FragData[0] = vec4(albedo.rgb * 1.6, albedo.a);
    gl_FragData[1] = vec4(0.5, 0.5, 1.0, 0.5);
    gl_FragData[2] = vec4(0.20, 0.04, 0.90, MAT_EMISSIVE_RED);
}
