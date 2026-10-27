#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;
uniform float rainStrength;

in vec2 vTexCoord;
in vec4 vColor;

/* DRAWBUFFERS:012 */

void main() {
    vec4 texCol = texture(tex, vTexCoord) * vColor;
    float luma = getLuminance(texCol.rgb);
    if (texCol.a < 0.05 || luma < 0.02) {
        discard;
    }

    float visibility = clamp(1.0 - rainStrength * 0.95, 0.05, 1.0);
    vec3 sunMoonOut = pow(texCol.rgb, vec3(0.75)) * 1.75 * visibility;
    gl_FragData[0] = vec4(sunMoonOut, texCol.a * visibility);
    gl_FragData[1] = vec4(0.5, 0.5, 0.0, 1.0);
    gl_FragData[2] = vec4(0.0, 0.0, clamp(luma * visibility, 0.0, 1.0), MAT_SKY);
}
