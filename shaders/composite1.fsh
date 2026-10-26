#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"
#include "/lib/ssgi_bounce.glsl"
#include "/lib/ssr_reflection.glsl"

uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D depthtex0;

uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform vec3 sunPosition;
uniform float rainStrength;
uniform int frameCounter;

in vec2 vTexCoord;

/* RENDERTARGETS: 4,6 */
layout(location = 0) out vec4 outSSGI; // colortex4: rgb = Indirect Bounce Radiance, a = Screen-Space AO
layout(location = 1) out vec4 outSSR;  // colortex6: rgb = SSR Reflection Color, a = Fresnel weight

void main() {
    float depth = texture(depthtex0, vTexCoord).r;
    if (depth >= 0.9999) {
        outSSGI = vec4(0.0, 0.0, 0.0, 1.0);
        outSSR  = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    vec4 c1 = texture(colortex1, vTexCoord);
    vec4 c2 = texture(colortex2, vTexCoord);

    vec3 viewNormal = decodeNormal(c1.rg);
    float skyLight  = c1.a;
    float smoothness = c2.r;
    float f0         = c2.g;

    vec3 viewPos = screenToView(vTexCoord, depth, gbufferProjectionInverse);
    vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);

    float dither = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);

    // 1. Compute Screen-Space Indirect Light Bounce (SSGI Color Bleeding) & AO
    outSSGI = computeSSGIBounceAndAO(
        viewPos, viewNormal, vTexCoord, dither,
        colortex3, colortex1, depthtex0,
        gbufferProjection, gbufferProjectionInverse
    );

    // 2. Compute Screen-Space Specular Reflections (SSR)
    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));
    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    outSSR = computeScreenSpaceReflection(
        viewPos, viewNormal, worldNormal,
        smoothness, f0, skyLight, dither, atm,
        colortex3, depthtex0,
        gbufferProjection, gbufferProjectionInverse
    );
}

