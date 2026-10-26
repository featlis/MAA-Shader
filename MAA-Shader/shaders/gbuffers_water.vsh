#version 330 compatibility

#include "/lib/common.glsl"

in vec4 mc_Entity;

uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;

out vec2 vTexCoord;
out vec2 vLmCoord;
out vec4 vColor;
out vec3 vViewNormal;
out vec3 vWorldPos;
flat out int vBlockId;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 rawLm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vLmCoord = clamp((rawLm - 0.03125) / 0.9375, 0.0, 1.0);
    vColor = gl_Color;
    vViewNormal = normalize(gl_NormalMatrix * gl_Normal);
    vBlockId = int(mc_Entity.x + 0.5);

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    vec4 playerPos = gbufferModelViewInverse * viewPos;
    vWorldPos = playerPos.xyz + cameraPosition;

    if (vBlockId == 10008 && WATER_WAVE_STRENGTH > 0.001) {
        float t = frameTimeCounter * 1.8;
        float wave = sin(t + vWorldPos.x * 1.3 + vWorldPos.z * 0.9) * 0.025 +
                     cos(t * 1.3 - vWorldPos.z * 1.6 + vWorldPos.x * 0.7) * 0.018;
        playerPos.y += wave * WATER_WAVE_STRENGTH;
        viewPos = gbufferModelView * playerPos;
    }

    gl_Position = gl_ProjectionMatrix * viewPos;
}

