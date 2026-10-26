#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

uniform vec4 starData;
uniform vec3 sunPosition;
uniform float rainStrength;
uniform mat4 gbufferModelViewInverse;

in vec4 vColor;
in vec3 vViewPos;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 outColor0;
layout(location = 1) out vec4 outColor1;
layout(location = 2) out vec4 outColor2;

void main() {
    if (starData.r > 0.5) {
        // Star geometry
        outColor0 = vec4(vColor.rgb * 1.45, MAT_SKY);
        outColor1 = vec4(0.5, 0.5, 0.0, 1.0);
        outColor2 = vec4(0.0, 0.0, 1.0, 1.0);
        return;
    }

    vec3 viewDir = normalize(vViewPos);
    vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));

    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    float zenithFactor = pow(clamp(worldDir.y, 0.0, 1.0), 0.55);
    vec3 skyColor = mix(atm.skyHorizon, atm.skyZenith, zenithFactor);

    // Subtle solar halo around sun/moon
    float sunCos = dot(worldDir, sunWorldDir);
    float sunGlow = pow(clamp(sunCos * 0.5 + 0.5, 0.0, 1.0), 6.0) * (1.0 - rainStrength * 0.85);
    skyColor += atm.directLight * sunGlow * 0.24;

    outColor0 = vec4(skyColor, MAT_SKY);
    outColor1 = vec4(0.5, 0.5, 0.0, 1.0);
    outColor2 = vec4(0.0, 0.0, 0.0, 1.0);
}

