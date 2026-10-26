#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/shadow_distort.glsl"

in vec4 mc_Entity;
in vec4 mc_midTexCoord;

uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;

out vec2 vTexCoord;
out vec4 vColor;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor = gl_Color;

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    vec4 playerPos = shadowModelViewInverse * viewPos;

    #ifdef ENABLE_WAVING_FOLIAGE
    int blockId = int(mc_Entity.x + 0.5);
    if (blockId == 10001) {
        vec3 worldPos = playerPos.xyz + cameraPosition;
        float t = frameTimeCounter * 2.4 * WAVING_SPEED;
        float waveX = sin(t + worldPos.x * 1.7 + worldPos.z * 0.9) * 0.045;
        float waveZ = cos(t * 0.85 + worldPos.z * 1.5 + worldPos.x * 1.1) * 0.035;
        playerPos.x += waveX;
        playerPos.z += waveZ;
    }
    #endif

    vec4 clipPos = shadowProjection * (shadowModelView * playerPos);
    clipPos.xyz = distortShadowClipPos(clipPos.xyz);
    gl_Position = clipPos;
}

