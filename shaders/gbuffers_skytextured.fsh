#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform float rainStrength;

in vec2 vTexCoord;
in vec4 vColor;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
layout(location = 2) out vec4 outColor2;

void main() {
    vec4 texCol = texture(tex, vTexCoord) * vColor;
    float luma = getLuminance(texCol.rgb);
    if (texCol.a < 0.05 || luma < 0.02) {
        discard;
    }

    float visibility = clamp(1.0 - rainStrength * 0.95, 0.05, 1.0);
    outColor0 = vec4(texCol.rgb * 1.85 * visibility, texCol.a * visibility);
    outColor1 = vec4(0.5, 0.5, 0.0, 1.0);
    outColor2 = vec4(0.0, 0.0, 1.0, 1.0);
}

