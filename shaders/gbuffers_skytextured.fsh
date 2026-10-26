#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform float rainStrength;

in vec2 vTexCoord;
in vec4 vColor;

/* DRAWBUFFERS:0 */

void main() {
    vec4 texCol = texture(tex, vTexCoord) * vColor;
    float luma = getLuminance(texCol.rgb);
    if (texCol.a < 0.05 || luma < 0.02) {
        discard;
    }

    float visibility = clamp(1.0 - rainStrength * 0.95, 0.05, 1.0);
    gl_FragData[0] = vec4(texCol.rgb * 1.85 * visibility, texCol.a * visibility);
}
