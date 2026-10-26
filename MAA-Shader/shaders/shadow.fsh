#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec4 vColor;

/* DRAWBUFFERS:0 */

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }
    gl_FragData[0] = albedo;
}
