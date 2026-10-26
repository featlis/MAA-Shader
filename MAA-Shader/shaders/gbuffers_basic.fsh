#version 330 compatibility

#include "/lib/common.glsl"

in vec4 vColor;

/* DRAWBUFFERS:012 */

void main() {
    if (vColor.a < 0.05) {
        discard;
    }

    gl_FragData[0] = vec4(vColor.rgb, vColor.a);
    gl_FragData[1] = vec4(0.5, 0.5, 0.5, 0.8);
    gl_FragData[2] = vec4(0.10, 0.04, 0.25, MAT_TERRAIN);
}
