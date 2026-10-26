#ifndef SETTINGS_GLSL
#define SETTINGS_GLSL

// ============================================================================
// MAA-Shader: Cinematic-Realistic Lightweight Shaderpack Settings
// ============================================================================

// --- Shadow Settings ---
#define SHADOW_MAP_RESOLUTION 2048      // [1024 1536 2048 3072 4096]
#define SHADOW_DISTANCE 128.0           // [64.0 96.0 128.0 160.0 192.0 256.0]
#define SHADOW_DISTORTION 0.85          // [0.70 0.80 0.85 0.90]
#define SHADOW_PCF_SAMPLES 6            // [4 6 8 12]
#define SHADOW_SOFTNESS 1.0             // [0.5 0.8 1.0 1.2 1.5 2.0]
#define SHADOW_COLORED_GLASS            // Colored light & shadows through stained glass
#define SHADOW_CONTACT_HARDENING        // Sharper shadows near contact point

// --- Directional Blocklight & Tube Occlusion ---
#define DIRECTIONAL_BLOCKLIGHT          // Reconstruct 3D light direction from gradient
#define TUBE_OCCLUSION_STRENGTH 0.90    // [0.00 0.50 0.70 0.85 0.90 1.00]
#define BLOCKLIGHT_OCCLUSION_STEPS 4    // [2 4 6 8]
#define BLOCKLIGHT_INTENSITY 1.65       // [0.80 1.00 1.20 1.35 1.65 2.00]
#define BLOCKLIGHT_DISTANCE_FALLOFF 1.85 // [1.0 1.25 1.5 1.85 2.2]

// --- Handheld Dynamic Light ---
// 0: Adaptive Hybrid (Point + Forward Spot boost)
// 1: Pure Omni-Directional Point Light
// 2: Pure Directional Spotlight / Flashlight
#define HANDLIGHT_MODE 0                // [0 1 2]
#define HANDLIGHT_INTENSITY 1.35        // [0.00 0.50 0.80 1.00 1.35 1.60 2.00]
#define HANDLIGHT_RANGE 18.0            // [10.0 14.0 18.0 24.0 32.0]
#define HANDLIGHT_SMOOTH_SPEED 6.0      // [2.0 4.0 6.0 10.0 15.0] Lower = smoother transition
#define SPOTLIGHT_INNER_COS 0.89        // Inner cone cosine (~27 deg)
#define SPOTLIGHT_OUTER_COS 0.65        // Outer cone cosine (~49 deg)

// --- Indirect Light Bounce (SSGI) ---
#define ENABLE_SSGI                     // Screen-Space Global Illumination bounce
#define SSGI_SAMPLES 4                  // [0 2 4 6 8]
#define SSGI_STEPS 5                    // [3 4 5 6 8]
#define SSGI_INTENSITY 1.15             // [0.50 0.80 1.00 1.15 1.50 2.00]

// --- Specular & Screen-Space Reflections (SSR) ---
#define ENABLE_SSR                      // Screen-space reflections on water, glass & metals
#define SSR_STEPS 12                    // [6 8 12 16 24]
#define SPECULAR_STRENGTH 1.15          // [0.0 0.5 0.8 1.0 1.15 1.5]
#define WETNESS_REFLECTION 0.85         // [0.0 0.5 0.85 1.0] Rain puddle reflections

// --- Ambient & Shadow Visibility ---
#define MIN_CAVE_BRIGHTNESS 0.052       // [0.020 0.035 0.052 0.080 0.120] Crisp caves without milky haze
#define SKY_AMBIENT_INTENSITY 0.95      // [0.60 0.80 0.95 1.10 1.30 1.50]
#define GROUND_BOUNCE_STRENGTH 0.25     // [0.10 0.20 0.25 0.40]
#define ENABLE_AUTO_EXPOSURE            // Eye adaptation in dark caves / bright sunlight
#define AUTO_EXPOSURE_SPEED 2.5         // [1.0 2.5 5.0 10.0]

// --- Volumetric Fog, Colored Atmosphere & Distant Shimmer ---
#define ENABLE_VOLUMETRIC_FOG           // Colored light shafts & distance atmospheric fog
#define VOLUMETRIC_STEPS 6              // [4 6 8 12]
#define FOG_DENSITY_MULTIPLIER 0.65     // [0.0 0.35 0.65 1.0 1.5 2.0]
#define COLORED_LIGHT_FOG_INFLUENCE 1.25 // [0.0 0.5 1.0 1.25 1.6]
#define ENABLE_HEAT_HAZE                // Distant light scintillation & thermal shimmer
#define DISTANT_LIGHT_SHIMMER 1.0       // [0.0 0.5 1.0 1.5 2.0]

// --- Waving Foliage & Water Waves ---
#define ENABLE_WAVING_FOLIAGE           // Waving leaves, grass, crops
#define WAVING_SPEED 1.0                // [0.5 1.0 1.5 2.0]
#define WATER_WAVE_STRENGTH 0.85        // [0.0 0.5 0.85 1.2]

// --- Post-Processing & Cinematic Grading ---
#define ENABLE_FXAA                     // Fast Approximate Anti-Aliasing
#define CAS_SHARPENING 0.45             // [0.0 0.2 0.35 0.45 0.8]
#define CINEMATIC_CONTRAST 1.12         // [0.95 1.00 1.06 1.12 1.20]
#define CINEMATIC_SATURATION 1.10       // [0.85 1.00 1.10 1.20]
#define SHADOW_TOE_LIFT 0.002           // [0.000 0.002 0.005 0.010 0.020] Subtle toe without milky haze

#endif // SETTINGS_GLSL
