#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

uniform vec3 sunPosition;
uniform float rainStrength;
uniform mat4 gbufferModelViewInverse;

in vec4 vColor;
in vec3 vViewPos;

/* DRAWBUFFERS:012 */

void main() {
    // Detect stars: equal R, G, B channels > 0
    bool isStar = (abs(vColor.r - vColor.g) < 0.01 && abs(vColor.g - vColor.b) < 0.01 && vColor.r > 0.02 && vColor.r < 0.95);
    if (isStar) {
        gl_FragData[0] = vec4(vColor.rgb * 1.65, 1.0);
        gl_FragData[1] = vec4(0.5, 0.5, 0.0, 1.0);
        gl_FragData[2] = vec4(0.0, 0.0, 1.0, MAT_SKY);
        return;
    }

    vec3 viewDir = normalize(vViewPos);
    vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));

    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    float zenithFactor = pow(clamp(worldDir.y, 0.0, 1.0), 0.55);
    vec3 skyColor = mix(atm.skyHorizon, atm.skyZenith, zenithFactor);

    float sunCos = dot(worldDir, sunWorldDir);
    float sunGlow = pow(clamp(sunCos * 0.5 + 0.5, 0.0, 1.0), 6.0) * (1.0 - rainStrength * 0.85);
    skyColor += atm.directLight * sunGlow * 0.24;

    gl_FragData[0] = vec4(skyColor, 1.0);
    gl_FragData[1] = vec4(0.5, 0.5, 0.0, 1.0);
    gl_FragData[2] = vec4(0.0, 0.0, 0.0, MAT_SKY);
}
