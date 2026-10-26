#version 330 compatibility

#include "/lib/common.glsl"

uniform sampler2D tex;

in vec2 vTexCoord;
in vec4 vColor;
in vec3 vViewNormal;

/* DRAWBUFFERS:012 */

void main() {
    vec4 albedo = texture(tex, vTexCoord) * vColor;
    if (albedo.a < 0.1) {
        discard;
    }

    vec3 viewNormal = normalize(vViewNormal);
    gl_FragData[0] = vec4(albedo.rgb, albedo.a);
    gl_FragData[1] = vec4(encodeNormal(viewNormal), 0.0, 1.0);
    gl_FragData[2] = vec4(0.10, 0.02, 0.0, MAT_TERRAIN);
}
