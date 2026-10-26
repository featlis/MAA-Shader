#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec4 vColor;

/* DRAWBUFFERS:0 */

void main() {
    vec4 glint = texture(tex, vTexCoord) * vColor;
    if (glint.a < 0.05) {
        discard;
    }

    gl_FragData[0] = vec4(glint.rgb * 1.35, glint.a * 0.65);
}
