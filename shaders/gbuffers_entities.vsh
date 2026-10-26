#version 330 compatibility

out vec2 vTexCoord;
out vec2 vLmCoord;
out vec4 vColor;
out vec3 vViewNormal;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vec2 rawLm = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vLmCoord = clamp((rawLm - 0.03125) / 0.9375, 0.0, 1.0);
    vColor = gl_Color;
    vViewNormal = normalize(gl_NormalMatrix * gl_Normal);
    gl_Position = ftransform();
}

