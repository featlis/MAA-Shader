#version 330 compatibility

#include "/lib/common.glsl"

in vec4 mc_Entity;
in vec4 mc_midTexCoord;

uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;

out vec2 vTexCoord;
out vec2 vLmCoord;
out vec4 vColor;
out vec3 vViewNormal;
flat out int vBlockId;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 rawLm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vLmCoord = clamp((rawLm - 0.03125) / 0.9375, 0.0, 1.0);
    vColor = gl_Color;
    vViewNormal = normalize(gl_NormalMatrix * gl_Normal);
    vBlockId = int(mc_Entity.x + 0.5);

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

    #ifdef ENABLE_WAVING_FOLIAGE
    if (vBlockId == 10001) {
        vec4 playerPos = gbufferModelViewInverse * viewPos;
        vec3 worldPos = playerPos.xyz + cameraPosition;
        float t = frameTimeCounter * 2.4 * WAVING_SPEED;
        playerPos.x += sin(t + worldPos.x * 1.7 + worldPos.z * 0.9) * 0.045;
        playerPos.z += cos(t * 0.85 + worldPos.z * 1.5 + worldPos.x * 1.1) * 0.035;
        viewPos = gbufferModelView * playerPos;
    }
    #endif

    gl_Position = gl_ProjectionMatrix * viewPos;
}

