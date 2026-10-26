#version 330 compatibility

out vec2 vTexCoord;
out vec4 vColor;
out vec3 vViewNormal;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor = gl_Color;
    vViewNormal = normalize(gl_NormalMatrix * gl_Normal);
    gl_Position = ftransform();
}

