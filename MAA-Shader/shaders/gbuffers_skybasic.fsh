#version 330 compatibility

#include "/lib/common.glsl"
#include "/lib/colors.glsl"

uniform vec3 sunPosition;
uniform float rainStrength;
uniform float frameTimeCounter;
uniform mat4 gbufferModelViewInverse;

in vec4 vColor;
in vec3 vViewPos;

/* DRAWBUFFERS:012 */

float hash13(vec3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 hash33(vec3 p3) {
    p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Evaluates a 3D spherical cell layer of twinkling stars
vec3 sampleStarLayer(vec3 celDir, float gridScale, float densityThreshold, float time) {
    vec3 p = celDir * gridScale;
    vec3 cellId = floor(p);
    vec3 localPos = fract(p) - 0.5;

    float h = hash13(cellId);
    if (h < densityThreshold) return vec3(0.0);

    vec3 rnd = hash33(cellId);
    vec3 starCenter = (rnd - 0.5) * 0.55;
    float dist = length(localPos - starCenter);

    // Sharp pinpoint core + tiny optical halo
    float core = smoothstep(0.16, 0.015, dist);
    if (core <= 0.001) return vec3(0.0);

    // Stellar blackbody color (Blue-white O/B star, Diamond A/F star, Warm K/M star)
    vec3 coldStar = vec3(0.68, 0.84, 1.00);
    vec3 pureStar = vec3(0.98, 0.98, 1.00);
    vec3 warmStar = vec3(1.00, 0.80, 0.55);
    vec3 starCol = (rnd.x < 0.45) ? mix(coldStar, pureStar, rnd.x * 2.2)
                                  : mix(pureStar, warmStar, (rnd.x - 0.45) * 1.8);

    // Dynamic atmospheric scintillation / twinkling
    float phase = rnd.y * 62.83 + rnd.z * 31.41;
    float freq  = 3.5 + rnd.x * 6.5;
    float twinkle = 0.65 + 0.55 * sin(time * freq + phase) * cos(time * (freq * 0.63) - phase * 0.7);
    float mag = smoothstep(densityThreshold, 1.0, h);

    return starCol * (core * core * (0.85 + mag * 1.65) * max(twinkle, 0.15));
}

void main() {
    vec3 viewDir = normalize(vViewPos);
    vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
    vec3 sunWorldDir = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));
    float clearSky = clamp(1.0 - rainStrength * 0.95, 0.0, 1.0);

    // Detect vanilla stars: equal R, G, B channels > 0
    bool isStar = (abs(vColor.r - vColor.g) < 0.01 && abs(vColor.g - vColor.b) < 0.01 && vColor.r > 0.02 && vColor.r < 0.95);
    if (isStar) {
        float starSeed = dot(floor(worldDir * 120.0), vec3(1.37, 2.91, 4.13));
        float twinkle = 0.75 + 0.45 * sin(frameTimeCounter * 5.8 + starSeed) * cos(frameTimeCounter * 3.7 - starSeed);
        vec3 tint = mix(vec3(0.76, 0.88, 1.00), vec3(1.00, 0.88, 0.70), fract(starSeed * 0.37));
        vec3 starOut = tint * pow(vColor.rgb, vec3(0.45)) * (1.55 * twinkle * STAR_SPARKLE_INTENSITY * clearSky);
        gl_FragData[0] = vec4(starOut, 1.0);
        gl_FragData[1] = vec4(0.5, 0.5, 0.0, 1.0);
        gl_FragData[2] = vec4(0.0, 0.0, 0.95, MAT_SKY);
        return;
    }

    AtmosphereColors atm = getAtmosphereColors(sunWorldDir.y, rainStrength);

    float upDot = clamp(worldDir.y, 0.0, 1.0);
    float zenithFactor = pow(upDot, 0.52);
    vec3 skyColor = mix(atm.skyHorizon, atm.skyZenith, zenithFactor);

    // Horizon Rayleigh / Twilight belt glow
    float horizonBand = pow(clamp(1.0 - abs(worldDir.y), 0.0, 1.0), 4.0);
    vec3 twilightBelt = vec3(0.95, 0.38, 0.22) * atm.sunsetFactor * 0.35
                      + vec3(0.05, 0.11, 0.24) * atm.nightFactor * 0.28;
    skyColor += twilightBelt * horizonBand * clearSky;

    // Solar Corona (Day / Sunset)
    float sunCos = dot(worldDir, sunWorldDir);
    float sunGlowWide = pow(clamp(sunCos * 0.5 + 0.5, 0.0, 1.0), 6.0);
    float sunGlowCore = pow(clamp(sunCos, 0.0, 1.0), 32.0);
    skyColor += atm.directLight * (sunGlowWide * 0.22 + sunGlowCore * 0.35) * clearSky * (1.0 - atm.nightFactor * 0.85);

    // Lunar Silvery-Blue Corona & Night Sky Sparkle (Night)
    float starEmission = 0.0;
    if (atm.nightFactor > 0.01 && clearSky > 0.01) {
        float moonCos = dot(worldDir, -sunWorldDir);
        float moonHalo = pow(clamp(moonCos * 0.5 + 0.5, 0.0, 1.0), 10.0);
        float moonCore = pow(clamp(moonCos, 0.0, 1.0), 48.0);
        skyColor += vec3(0.32, 0.50, 0.82) * (moonHalo * 0.16 + moonCore * 0.38) * atm.nightFactor * clearSky;

        // Procedural Sparkling Stars & Milky Way Band above horizon
        float horizonMask = smoothstep(0.02, 0.22, worldDir.y);
        if (horizonMask > 0.001 && STAR_SPARKLE_INTENSITY > 0.01) {
            // Build celestial coordinate frame rotating with sunWorldDir
            vec3 celZ = normalize(vec3(sunWorldDir.x, sunWorldDir.y, 0.0001));
            vec3 celX = normalize(cross(vec3(0.0, 0.0, 1.0), celZ));
            vec3 celY = cross(celZ, celX);
            vec3 celDir = normalize(vec3(dot(worldDir, celX), dot(worldDir, celY), dot(worldDir, celZ)));

            // Subtle Milky Way galactic band
            float galPlane = abs(dot(celDir, normalize(vec3(0.48, 0.36, -0.80))));
            float milkyWay = exp(-galPlane * galPlane * 14.0) * 0.042;
            vec3 milkyColor = mix(vec3(0.06, 0.12, 0.26), vec3(0.16, 0.22, 0.38), smoothstep(0.25, 0.0, galPlane));
            skyColor += milkyColor * milkyWay * horizonMask * atm.nightFactor * clearSky * STAR_SPARKLE_INTENSITY;

            // Dual-layer twinkling stars
            vec3 stars1 = sampleStarLayer(celDir, 76.0,  0.915, frameTimeCounter);
            vec3 stars2 = sampleStarLayer(celDir, 148.0, 0.940, frameTimeCounter * 0.85) * 0.65;
            vec3 totalStars = (stars1 + stars2) * horizonMask * atm.nightFactor * clearSky * STAR_SPARKLE_INTENSITY;

            skyColor += totalStars;
            starEmission = clamp(getLuminance(totalStars) * 1.2, 0.0, 1.0);
        }
    }

    gl_FragData[0] = vec4(skyColor, 1.0);
    gl_FragData[1] = vec4(0.5, 0.5, 0.0, 1.0);
    gl_FragData[2] = vec4(0.0, 0.0, starEmission, MAT_SKY);
}
