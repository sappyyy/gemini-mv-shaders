/*
    Cinematic Film Grain for ReShade - Advanced Version
    Description: Advanced organic film grain emulation featuring multiple 
    noise algorithms, overlay modes, and luminance masking.
*/

#include "ReShade.fxh"

// ==========================================
// USER INTERFACE
// ==========================================

uniform int NoiseType <
    ui_type = "combo";
    ui_items = "Organic Value (Cinematic Clumps)\0Uniform Digital (Raw ISO White Noise)\0Gaussian Digital (Soft Sensor Noise)\0Silver Halide Crystals (Voronoi Micro-structure)\0";
    ui_tooltip = "Select the algorithm used to generate the noise texture.";
    ui_category = "General";
> = 0;

uniform int BlendMode <
    ui_type = "combo";
    ui_items = "Soft Light (W3C Standard Film Look)\0Overlay (High Contrast)\0Hard Light (Gritty/Harsh)\0Linear Light (Mathematical/Bright)\0Multiply (Darkens Image)\0Screen (Brightens Image)\0";
    ui_tooltip = "Select how the grain blends with the image.";
    ui_category = "General";
> = 0;

uniform float Intensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Overall opacity of the film grain.";
    ui_category = "General";
> = 0.5;

uniform float Size <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 5.0;
    ui_tooltip = "Size of the grain clumps. 1.0 is standard. Higher is 16mm/8mm.";
    ui_category = "General";
> = 1.5;

uniform float Roughness <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Adds secondary micro-grain to the clumps for a grittier texture.";
    ui_category = "General";
> = 0.6;

uniform float ColorSaturation <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "0.0 = B&W Silver Halide grain. 1.0 = Color Film Dye Clouds.";
    ui_category = "Color";
> = 0.2;

uniform float AnimationFPS <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 60.0;
    ui_tooltip = "Framerate of the grain. Set to 24 for standard cinematic look. 0 pauses.";
    ui_category = "Animation";
> = 24.0;

uniform float ShadowGrain <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Intensity of grain in dark areas.";
    ui_category = "Luminance Response (Exposure)";
> = 0.8;

uniform float MidtoneGrain <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Intensity of grain in mid-grey areas (usually highest in real film).";
    ui_category = "Luminance Response (Exposure)";
> = 1.0;

uniform float HighlightGrain <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Intensity of grain in bright areas (usually blown out/lowest in real film).";
    ui_category = "Luminance Response (Exposure)";
> = 0.2;

uniform float Timer < source = "timer"; >;

// ==========================================
// MATH & NOISE GENERATORS
// ==========================================

// Fast 3D Hash
float3 hash33(float3 p3) {
    p3 = frac(p3 * float3(.1031, .1030, .0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

// 0. Organic Value Noise (Smooth clumping)
float3 getOrganicNoise(float2 uv, float t) {
    float2 i = floor(uv);
    float2 f = frac(uv);
    float2 u = f * f * (3.0 - 2.0 * f);
    float3 a = hash33(float3(i + float2(0.0, 0.0), t));
    float3 b = hash33(float3(i + float2(1.0, 0.0), t));
    float3 c = hash33(float3(i + float2(0.0, 1.0), t));
    float3 d = hash33(float3(i + float2(1.0, 1.0), t));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// 3. Voronoi / Cellular Noise (Looks like literal film crystals under a microscope)
float cellularNoise(float2 uv, float t) {
    float2 i = floor(uv);
    float2 f = frac(uv);
    float minDist = 1.0;
    
    [unroll]
    for(int y = -1; y <= 1; y++) {
        [unroll]
        for(int x = -1; x <= 1; x++) {
            float2 neighbor = float2(x, y);
            float3 p3 = float3(i + neighbor, t);
            
            // Fast 3D-to-2D hash for Voronoi points
            float2 pt = frac(sin(float2(dot(p3, float3(127.1, 311.7, 74.7)), dot(p3, float3(269.5, 183.3, 246.1)))) * 43758.5453);
            
            float2 diff = neighbor + pt - f;
            float dist = dot(diff, diff); // Squared distance
            minDist = min(minDist, dist);
        }
    }
    return 1.0 - minDist; // Inverted to create "dots/crystals" instead of web
}

// Generates RGB version of Cellular Noise
float3 getCellularNoise(float2 uv, float t) {
    return float3(
        cellularNoise(uv, t),
        cellularNoise(uv, t + 10.0),
        cellularNoise(uv, t + 20.0)
    );
}

// Master Router for Noise Selection
float3 generateBaseNoise(float2 uv, float t, int type) {
    if (type == 1) {
        // Uniform White Noise (Uses floor(uv) so the Size slider makes blocky retro pixels)
        return hash33(float3(floor(uv), t));
    } 
    else if (type == 2) {
        // Gaussian Noise (Central Limit Theorem sum of 3 uniform noises = softer digital noise)
        float3 n1 = hash33(float3(floor(uv), t));
        float3 n2 = hash33(float3(floor(uv) + 13.37, t + 1.0));
        float3 n3 = hash33(float3(floor(uv) - 13.37, t - 1.0));
        return (n1 + n2 + n3) / 3.0;
    } 
    else if (type == 3) {
        return getCellularNoise(uv, t);
    } 
    else {
        return getOrganicNoise(uv, t);
    }
}

// Fractal noise combiner
float3 getFilmGrain(float2 uv, float t, float roughness, int type) {
    float3 grain = generateBaseNoise(uv, t, type);
    
    if (roughness > 0.0) {
        float2 uvRot; // Rotated UVs for the secondary micro-grain
        uvRot.x = uv.x * 0.866 - uv.y * 0.5;
        uvRot.y = uv.x * 0.5   + uv.y * 0.866;
        
        float3 grain2 = generateBaseNoise(uvRot * 2.0, t * 1.1, type);
        grain = (grain + grain2 * roughness * 0.5) / (1.0 + roughness * 0.5);
    }
    return grain;
}

// ==========================================
// BLEND MODES
// ==========================================

// Vectorized Branchless Blend Mode Router
float3 ApplyBlendMode(float3 c, float3 b, int mode) {
    if (mode == 1) { 
        // Overlay
        float3 res_low = 2.0 * c * b;
        float3 res_high = 1.0 - 2.0 * (1.0 - c) * (1.0 - b);
        return lerp(res_low, res_high, step(0.5, c));
    } 
    else if (mode == 2) { 
        // Hard Light
        float3 res_low = 2.0 * c * b;
        float3 res_high = 1.0 - 2.0 * (1.0 - c) * (1.0 - b);
        return lerp(res_low, res_high, step(0.5, b));
    } 
    else if (mode == 3) { 
        // Linear Light
        return saturate(c + 2.0 * b - 1.0);
    } 
    else if (mode == 4) { 
        // Multiply
        return saturate(c * b);
    } 
    else if (mode == 5) { 
        // Screen
        return saturate(1.0 - (1.0 - c) * (1.0 - b));
    } 
    else { 
        // 0 = Soft Light (Default Cinematic)
        float3 res_low = c - (1.0 - 2.0 * b) * c * (1.0 - c);
        float3 d_low = ((16.0 * c - 12.0) * c + 4.0) * c;
        float3 d_high = sqrt(c);
        float3 d = lerp(d_high, d_low, step(c, 0.25)); 
        float3 res_high = c + (2.0 * b - 1.0) * (d - c);
        return lerp(res_high, res_low, step(b, 0.5));
    }
}

// ==========================================
// MAIN PIXEL SHADER
// ==========================================

float3 PS_CinematicFilmGrain(float4 pos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    
    // FPS Timer Math
    float timeSeed = (AnimationFPS > 0.0) ? floor((Timer / 1000.0) * AnimationFPS) : 1.0;
    float2 grainUV = (texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT)) / max(Size, 0.1);
    
    // Generate Raw Noise
    float3 rawGrain = getFilmGrain(grainUV, timeSeed, Roughness, NoiseType);
    
    // Convert to BW / Color
    float monoGrain = dot(rawGrain, float3(0.333333, 0.333333, 0.333333));
    float3 finalGrain = lerp(float3(monoGrain, monoGrain, monoGrain), rawGrain, ColorSaturation);
    
    // Luminance Mask
    float mask = lerp(ShadowGrain, MidtoneGrain, smoothstep(0.0, 0.5, luma));
    mask = lerp(mask, HighlightGrain, smoothstep(0.5, 1.0, luma));
    
    // Determine the "Invisible" Neutral Point based on chosen Blend Mode
    float3 neutralPoint = float3(0.5, 0.5, 0.5); // Standard for Soft/Overlay/Hard/Linear
    if (BlendMode == 4) neutralPoint = float3(1.0, 1.0, 1.0); // Multiply neutral is White
    if (BlendMode == 5) neutralPoint = float3(0.0, 0.0, 0.0); // Screen neutral is Black
    
    // Apply Intensity (Mixes from the "Invisible" Neutral state towards the actual grain)
    finalGrain = lerp(neutralPoint, finalGrain, Intensity * mask);
    
    // Apply Output Blend
    return ApplyBlendMode(color, finalGrain, BlendMode);
}

// ==========================================
// TECHNIQUE DEFINITION
// ==========================================

technique MV_CinenaticFilmGrain <
    ui_tooltip = "Advanced organic film grain emulation featuring multiple noise algorithms and overlay modes.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CinematicFilmGrain;
    }
}