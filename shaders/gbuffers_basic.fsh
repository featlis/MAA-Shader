#version 330 compatibility

#include "/lib/common.glsl"

in vec4 vColor;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
layout(location = 2) out vec4 outColor2;

void main() {
    if (vColor.a < 0.05) {
        discard;
    }

    outColor0 = vec4(vColor.rgb, MAT_TERRAIN);
    outColor1 = vec4(0.5, 0.5, 0.5, 0.8);
    outColor2 = vec4(0.10, 0.04, 0.25, 1.0);
}

