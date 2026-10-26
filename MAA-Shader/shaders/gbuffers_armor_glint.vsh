#version 330 compatibility

out vec2 vTexCoord;
out vec4 vColor;

void main() {
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    vColor = gl_Color;
    gl_Position = ftransform();
}

