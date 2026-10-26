#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
layout(location = 2) out vec4 outColor2;

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    outColor0 = vec4(albedo.rgb, albedo.a * 0.65);
    outColor1 = vec4(0.5, 0.5, vLmCoord.x, vLmCoord.y);
    outColor2 = vec4(0.10, 0.04, 0.0, 1.0);
}

