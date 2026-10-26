#version 330 compatibility

out vec4 vColor;
out vec3 vViewPos;

void main() {
    vColor = gl_Color;
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    gl_Position = ftransform();
}

