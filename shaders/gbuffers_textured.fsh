#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec2 vLmCoord;
in vec4 vColor;
in vec3 vViewNormal;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
layout(location = 2) out vec4 outColor2;

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    vec3 viewNormal = normalize(vViewNormal);
    float emission = smoothstep(0.85, 0.99, vLmCoord.x) * 0.75;

    outColor0 = vec4(albedo.rgb, MAT_TERRAIN);
    outColor1 = vec4(encodeNormal(viewNormal), vLmCoord.x, vLmCoord.y);
    outColor2 = vec4(0.15, 0.04, emission, 1.0);
}

