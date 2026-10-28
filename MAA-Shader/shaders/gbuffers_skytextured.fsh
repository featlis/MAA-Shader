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
    float bodyMask = smoothstep(0.08, 0.24, luma);
    if (texCol.a < 0.05 || bodyMask < 0.01) {
        discard;
    }

    float visibility = clamp(1.0 - rainStrength * 0.95, 0.05, 1.0);
    vec3 sunMoonOut = texCol.rgb * bodyMask * 1.15 * visibility;
    gl_FragData[0] = vec4(sunMoonOut, texCol.a * bodyMask * visibility);
}
