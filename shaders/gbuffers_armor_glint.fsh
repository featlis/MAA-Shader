#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec4 vColor;

/* RENDERTARGETS: 0,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor2;

void main() {
    vec4 glint = texture(tex, vTexCoord) * vColor;
    if (glint.a < 0.05) {
        discard;
    }

    outColor0 = vec4(glint.rgb * 1.35, glint.a * 0.65);
    outColor2 = vec4(0.85, 0.25, 0.70, 1.0);
}

