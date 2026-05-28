#include "ReShade.fxh"

// ==========================================
// UNIFORMS (User Interface)
// ==========================================

uniform float timer < source = "timer"; >;

// --- GATE WEAVE ---
uniform float WeaveAmount <
    ui_category = "Gate Weave (Film Shake)";
    ui_label = "Weave Intensity";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.02; ui_step = 0.0001;
    ui_tooltip = "How far the film physically shifts in the projector gate.";
> = 0.0015;

uniform float WeaveSpeed <
    ui_category = "Gate Weave (Film Shake)";
    ui_label = "Weave Speed";
    ui_type = "slider";
    ui_min = 1.0; ui_max = 50.0; ui_step = 0.1;
    ui_tooltip = "How fast the film jitters.";
> = 12.0;

uniform float EdgeZoom <
    ui_category = "Gate Weave (Film Shake)";
    ui_label = "Edge Crop (Zoom)";
    ui_type = "slider";
    ui_min = 1.0; ui_max = 1.1; ui_step = 0.001;
    ui_tooltip = "Zooms in slightly to hide the black edges caused by the film shifting.";
> = 1.015;

// --- FILM FLICKER ---
uniform float FlickerAmount <
    ui_category = "Film Flicker";
    ui_label = "Flicker Intensity";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "How much the brightness drops during a flicker.";
> = 0.08;

uniform float FlickerSpeed <
    ui_category = "Film Flicker";
    ui_label = "Flicker Speed";
    ui_type = "slider";
    ui_min = 1.0; ui_max = 100.0; ui_step = 0.5;
> = 24.0;

uniform float FlickerTension <
    ui_category = "Film Flicker";
    ui_label = "Flicker Sharpness";
    ui_type = "slider";
    ui_min = 0.1; ui_max = 10.0; ui_step = 0.1;
    ui_tooltip = "Higher values create sudden, sharp dips in brightness. Lower values create a smooth pulsing.";
> = 3.0;


// ==========================================
// FUNCTIONS
// ==========================================

// 1D Hash function for pseudo-random numbers
float hash(float n) 
{
    return frac(sin(n) * 43758.5453123); // Fixed: frac instead of fract
}

// 1D Value Noise for smooth, organic randomization
float smoothNoise(float x) 
{
    float i = floor(x);
    float f = frac(x); // Fixed: frac instead of fract
    
    // Cubic interpolation (Smoothstep)
    f = f * f * (3.0 - 2.0 * f);
    
    // Mix between the two random hash points
    float res = lerp(hash(i), hash(i + 1.0), f); // Fixed: lerp instead of mix
    
    return res * 2.0 - 1.0; // Convert to range -1.0 to 1.0
}


// ==========================================
// PIXEL SHADER
// ==========================================

float4 PS_FilmMechanics(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float time = timer * 0.001; // Convert ReShade timer to seconds
    
    // 1. ZOOM (To hide edges)
    float2 uv = texcoord;
    uv = (uv - 0.5) / EdgeZoom + 0.5;

    // 2. GATE WEAVE
    // We combine a slow sway with a faster jitter to simulate mechanical tension and slippage
    float swayX = smoothNoise(time * WeaveSpeed * 0.4);
    float jitterX = smoothNoise(time * WeaveSpeed * 1.5 + 10.0);
    float weaveX = (swayX * 0.6) + (jitterX * 0.4);
    
    float swayY = smoothNoise(time * WeaveSpeed * 0.3 + 20.0);
    float jitterY = smoothNoise(time * WeaveSpeed * 1.7 + 30.0);
    float weaveY = (swayY * 0.7) + (jitterY * 0.3); // Film tends to bounce vertically more than horizontally

    // Apply the weave to UV coordinates
    uv.x += weaveX * WeaveAmount;
    uv.y += weaveY * WeaveAmount * 1.5; // Vertical weave is naturally slightly heavier
    
    // Sample the backbuffer with the new UVs
    float4 color = tex2D(ReShade::BackBuffer, uv);
    
    // Hard black edges if the weave pushes past the zoomed boundaries
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
    {
        color.rgb = 0.0;
    }

    // 3. FILM FLICKER
    // Flicker rarely gets *brighter* than 1.0, it's usually the shutter blocking light (darkening)
    // Convert smoothNoise (which is -1 to 1) to a 0 to 1 range
    float rawNoise = (smoothNoise(time * FlickerSpeed + 50.0) + 1.0) * 0.5; 
    
    // Use pow() to shape the noise. This causes the brightness to stay at normal levels mostly, 
    // but occasionally spike downwards, simulating a mechanical shutter.
    float dip = pow(rawNoise, FlickerTension); 
    
    // Calculate final multiplier
    float flickerMultiplier = 1.0 - (dip * FlickerAmount);
    
    color.rgb *= flickerMultiplier;

    return color;
}

// ==========================================
// TECHNIQUES
// ==========================================

technique MV_FilmMech
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_FilmMechanics;
    }
}