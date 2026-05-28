/*
    Cinematic Halation Shader for ReShade
    Optimized for SDR Movie Watching
    
    Features:
    - High-quality 16-bit half-resolution separable Gaussian Blur
    - Customizable highlight threshold and smooth roll-off
    - Multiple blending modes (Screen, Add, Lighten, Soft Light)
    - Highlight Protection to preserve detail in blown-out whites


    Cinematic Halation Shader for ReShade
    Optimized for SDR Movie Watching
    
    Update: Added "Dark Neighborhood" (Local Contrast) Highlight Isolation
*/

#include "ReShadeUI.fxh"
#include "ReShade.fxh"

// ===============================================================================
// USER INTERFACE
// ===============================================================================

uniform bool bDebugMode <
    ui_category = "Debug";
    ui_label = "Show Halation Map Only";
    ui_tooltip = "Enable this to see exactly what the shader is extracting. Vital for tuning the Dark Neighborhood settings.";
> = false;

// --- Appearance ---
uniform float fIntensity <
    ui_category = "Halation Appearance";
    ui_label = "Halation Intensity";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
> = 0.70;

uniform float fRadius <
    ui_category = "Halation Appearance";
    ui_label = "Blur Radius";
    ui_tooltip = "How far the red glow spreads.";
    ui_type = "slider";
    ui_min = 1.0; ui_max = 10.0;
    ui_step = 0.1;
> = 4.0;

uniform float3 cHalationTint <
    ui_category = "Halation Appearance";
    ui_label = "Halation Tint";
    ui_type = "color";
> = float3(1.0, 0.15, 0.02);

// --- Base Extraction ---
uniform float fThreshold <
    ui_category = "Base Highlight Extraction";
    ui_label = "Luminance Threshold";
    ui_tooltip = "Determines how bright a pixel must be to even be considered for halation.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = 0.75;

uniform float fSmoothness <
    ui_category = "Base Highlight Extraction";
    ui_label = "Extraction Smoothness";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.5;
    ui_step = 0.01;
> = 0.20;

// --- Dark Neighborhood (Local Contrast) ---
uniform float fNeighborInfluence <
    ui_category = "Dark Neighborhood Requirement";
    ui_label = "Neighborhood Influence";
    ui_tooltip = "0.0 = Halation everywhere bright.\n1.0 = Halation ONLY occurs if surrounded by dark pixels.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = 0.85;

uniform float fNeighborRadius <
    ui_category = "Dark Neighborhood Requirement";
    ui_label = "Search Radius (Pixels)";
    ui_tooltip = "How far out to look for dark pixels. Larger values isolate larger light sources.";
    ui_type = "slider";
    ui_min = 2.0; ui_max = 50.0;
    ui_step = 1.0;
> = 15.0;

uniform float fNeighborDiffThreshold <
    ui_category = "Dark Neighborhood Requirement";
    ui_label = "Contrast Threshold";
    ui_tooltip = "How much darker the neighborhood needs to be compared to the center pixel to trigger halation.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = 0.25;

uniform float fNeighborSmoothness <
    ui_category = "Dark Neighborhood Requirement";
    ui_label = "Contrast Smoothness";
    ui_tooltip = "Smooths out the transition so the halation doesn't instantly snap on/off at high contrast edges.";
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.5;
    ui_step = 0.01;
> = 0.15;

// --- Compositing ---
uniform int iBlendMode <
    ui_category = "Compositing";
    ui_label = "Blend Mode";
    ui_type = "combo";
    ui_items = "Screen (Cinematic & Safe)\0Linear Dodge / Add (Aggressive)\0Lighten (Subtle)\0Soft Light (Contrast Enhancing)\0";
> = 0;

uniform float fHighlightProtection <
    ui_category = "Compositing";
    ui_label = "Highlight Protection";
    ui_tooltip = "Prevents the halation glow from blowing out core detail inside bright light sources.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
> = 0.85;

// ===============================================================================
// TEXTURES & SAMPLERS
// ===============================================================================

texture texColor : COLOR;
sampler sTexColor { Texture = texColor; };

texture texHalation_A { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sTexHalation_A { Texture = texHalation_A; AddressU = CLAMP; AddressV = CLAMP; };

texture texHalation_B { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sTexHalation_B { Texture = texHalation_B; AddressU = CLAMP; AddressV = CLAMP; };

// ===============================================================================
// HELPER FUNCTIONS
// ===============================================================================

float GetLuma(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float GaussianWeight(int x, float sigma)
{
    float sigma2 = sigma * sigma;
    return (1.0 / sqrt(2.0 * 3.14159265 * sigma2)) * exp(-(float(x * x)) / (2.0 * sigma2));
}

// 8-tap circular pattern for neighborhood checking
static const float2 ringOffsets[8] = {
    float2(0.0, 1.0), 
    float2(0.707, 0.707), 
    float2(1.0, 0.0), 
    float2(0.707, -0.707),
    float2(0.0, -1.0), 
    float2(-0.707, -0.707), 
    float2(-1.0, 0.0), 
    float2(-0.707, 0.707)
};

// ===============================================================================
// SHADER PASSES
// ===============================================================================

void PS_Extract(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 outColor : SV_Target)
{
    float3 color = tex2D(sTexColor, texcoord).rgb;
    float centerLuma = GetLuma(color);
    
    // 1. Base Extraction (Is the pixel bright enough?)
    float extractMask = smoothstep(fThreshold - fSmoothness, fThreshold + fSmoothness, centerLuma);
    
    // 2. Dark Neighborhood Requirement (Is the pixel surrounded by darkness?)
    if (fNeighborInfluence > 0.0 && extractMask > 0.0)
    {
        float neighborLuma = 0.0;
        float2 pixelSize = float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT) * fNeighborRadius;
        
        // Sample surrounding pixels
        for(int i = 0; i < 8; i++)
        {
            float3 neighborColor = tex2D(sTexColor, texcoord + (ringOffsets[i] * pixelSize)).rgb;
            neighborLuma += GetLuma(neighborColor);
        }
        neighborLuma /= 8.0; // Average of the neighborhood
        
        // Calculate contrast (How much brighter is the center than its surroundings?)
        float lumaDifference = centerLuma - neighborLuma;
        
        // Create proximity mask based on contrast difference
        float proximityMask = smoothstep(fNeighborDiffThreshold - fNeighborSmoothness, 
                                         fNeighborDiffThreshold + fNeighborSmoothness, 
                                         lumaDifference);
                                         
        // Blend between standard thresholding and neighborhood thresholding based on Influence
        extractMask *= lerp(1.0, proximityMask, fNeighborInfluence);
    }
    
    // Output tinted highlights
    float3 extracted = color * extractMask * cHalationTint;
    outColor = float4(extracted, 1.0);
}

void PS_BlurH(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 outColor : SV_Target)
{
    float3 sum = 0.0; float weightSum = 0.0;
    float sigma = max(fRadius, 0.001);
    int taps = clamp(int(sigma * 3.0), 1, 15);
    float2 pixelSize = float2(1.0 / (BUFFER_WIDTH / 2.0), 1.0 / (BUFFER_HEIGHT / 2.0));
    
    for (int i = -taps; i <= taps; i++) {
        float weight = GaussianWeight(i, sigma);
        sum += tex2D(sTexHalation_A, texcoord + float2(float(i) * pixelSize.x, 0.0)).rgb * weight;
        weightSum += weight;
    }
    outColor = float4(sum / weightSum, 1.0);
}

void PS_BlurV(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 outColor : SV_Target)
{
    float3 sum = 0.0; float weightSum = 0.0;
    float sigma = max(fRadius, 0.001);
    int taps = clamp(int(sigma * 3.0), 1, 15);
    float2 pixelSize = float2(1.0 / (BUFFER_WIDTH / 2.0), 1.0 / (BUFFER_HEIGHT / 2.0));
    
    for (int i = -taps; i <= taps; i++) {
        float weight = GaussianWeight(i, sigma);
        sum += tex2D(sTexHalation_B, texcoord + float2(0.0, float(i) * pixelSize.y)).rgb * weight;
        weightSum += weight;
    }
    outColor = float4(sum / weightSum, 1.0);
}

void PS_Composite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 outColor : SV_Target)
{
    float3 baseColor = tex2D(sTexColor, texcoord).rgb;
    float3 halation = tex2D(sTexHalation_A, texcoord).rgb * fIntensity;
    
    if (bDebugMode) { outColor = float4(halation, 1.0); return; }

    // Highlight Protection
    float protectionMask = 1.0 - saturate(GetLuma(baseColor) * fHighlightProtection);
    halation *= protectionMask;

    float3 finalColor = baseColor;

    // Blending Modes
    if (iBlendMode == 0)      finalColor = 1.0 - (1.0 - baseColor) * (1.0 - halation); // Screen
    else if (iBlendMode == 1) finalColor = baseColor + halation;                       // Add
    else if (iBlendMode == 2) finalColor = max(baseColor, halation);                   // Lighten
    else if (iBlendMode == 3) finalColor = (1.0 - 2.0 * halation) * baseColor * baseColor + 2.0 * baseColor * halation; // Soft Light

    outColor = float4(finalColor, 1.0);
}

// ===============================================================================
// TECHNIQUES
// ===============================================================================

technique CinematicHalation
{
    pass Extract   { VertexShader = PostProcessVS; PixelShader = PS_Extract; RenderTarget = texHalation_A; }
    pass BlurX     { VertexShader = PostProcessVS; PixelShader = PS_BlurH;   RenderTarget = texHalation_B; }
    pass BlurY     { VertexShader = PostProcessVS; PixelShader = PS_BlurV;   RenderTarget = texHalation_A; }
    pass Composite { VertexShader = PostProcessVS; PixelShader = PS_Composite; }
}