#include "ReShade.fxh"

// ==============================================================================
// UI SETTINGS
// ==============================================================================

uniform float fHalationThreshold <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Threshold";
    ui_tooltip = "How bright a pixel needs to be to cause halation. Keep high (0.8+) for realism.";
    ui_category = "Halation Properties";
> = 0.80;

uniform float fHalationIntensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_label = "Halation Intensity";
    ui_tooltip = "Overall strength of the halation glow.";
    ui_category = "Halation Properties";
> = 1.2;

uniform float fHalationRadius <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 5.0;
    ui_label = "Scattering Radius";
    ui_tooltip = "How far the light scatters across the film emulsion.";
    ui_category = "Halation Properties";
> = 2.0;

uniform float3 fHalationTint <
    ui_type = "color";
    ui_label = "Emulsion Tint (Red/Orange)";
    ui_tooltip = "The color of the bottom emulsion layer.";
    ui_category = "Color";
> = float3(1.0, 0.25, 0.05);

uniform float fCoreProtection <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "White Core Protection";
    ui_tooltip = "Prevents pure white highlights from becoming fully saturated with red. Highly recommended to prevent clipping and loss of detail.";
    ui_category = "Highlight Preservation";
> = 0.8;

// ==============================================================================
// TEXTURES & SAMPLERS
// ==============================================================================

// Half-resolution for a wider, softer blur and better performance
texture texHalationPre  { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
texture texHalationBlur { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };

sampler SamplerHalationPre  { Texture = texHalationPre;  };
sampler SamplerHalationBlur { Texture = texHalationBlur; };

// ==============================================================================
// SHADER PASSES
// ==============================================================================

// Pass 1: Extract and tint the extreme highlights smoothly
float4 PS_ExtractHighlights(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float4 color = tex2D(ReShade::BackBuffer, texcoord);
    
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    
    // Smoothstep up to 1.0 ensures a soft extraction curve, preventing blocky edges
    float thresholdMask = smoothstep(fHalationThreshold, 1.0, luma);
    
    float3 halationColor = luma * fHalationTint * thresholdMask;
    
    return float4(halationColor, 1.0);
}

// Pass 2: Horizontal Gaussian Blur
float4 PS_BlurX(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixelSize = ReShade::PixelSize * 2.0 * fHalationRadius; 
    float4 sum = 0.0;
    
    sum += tex2D(SamplerHalationPre, texcoord + float2(-6.0, 0.0) * pixelSize) * 0.002216;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-5.0, 0.0) * pixelSize) * 0.008764;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-4.0, 0.0) * pixelSize) * 0.026995;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-3.0, 0.0) * pixelSize) * 0.064758;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-2.0, 0.0) * pixelSize) * 0.120985;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-1.0, 0.0) * pixelSize) * 0.176032;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 0.0, 0.0) * pixelSize) * 0.199471;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 1.0, 0.0) * pixelSize) * 0.176032;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 2.0, 0.0) * pixelSize) * 0.120985;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 3.0, 0.0) * pixelSize) * 0.064758;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 4.0, 0.0) * pixelSize) * 0.026995;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 5.0, 0.0) * pixelSize) * 0.008764;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 6.0, 0.0) * pixelSize) * 0.002216;
    
    return sum;
}

// Pass 3: Vertical Gaussian Blur
float4 PS_BlurY(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixelSize = ReShade::PixelSize * 2.0 * fHalationRadius;
    float4 sum = 0.0;
    
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -6.0) * pixelSize) * 0.002216;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -5.0) * pixelSize) * 0.008764;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -4.0) * pixelSize) * 0.026995;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -3.0) * pixelSize) * 0.064758;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -2.0) * pixelSize) * 0.120985;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -1.0) * pixelSize) * 0.176032;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  0.0) * pixelSize) * 0.199471;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  1.0) * pixelSize) * 0.176032;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  2.0) * pixelSize) * 0.120985;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  3.0) * pixelSize) * 0.064758;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  4.0) * pixelSize) * 0.026995;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  5.0) * pixelSize) * 0.008764;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  6.0) * pixelSize) * 0.002216;
    
    return sum;
}

// Pass 4: Composite with Anti-Clipping (Screen) and Core Protection
float4 PS_Composite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 halation = tex2D(SamplerHalationPre, texcoord).rgb; 
    
    halation *= fHalationIntensity;

    // --- CORE PROTECTION ---
    // Calculate the brightness of the original image
    float origLuma = dot(original, float3(0.2126, 0.7152, 0.0722));
    
    // Create a mask that isolates pure white cores (e.g. the literal center of a lightbulb)
    float coreMask = smoothstep(0.85, 1.0, origLuma) * fCoreProtection;
    
    // Desaturate the halation right where the core is. 
    // This leaves the core bright white while keeping the red fringe bleeding around the edges.
    float halationLuma = dot(halation, float3(0.333, 0.333, 0.333));
    halation = lerp(halation, halationLuma * 0.5, coreMask);

    // --- SCREEN BLENDING ---
    // Formula: A + B - (A * B)
    // This mathematically ensures the resulting image never exceeds 1.0, fully preventing hard clipping.
    float3 finalColor = original + halation - (original * saturate(halation));
    
    return float4(finalColor, 1.0);
}

// ==============================================================================
// TECHNIQUES
// ==============================================================================

technique RealisticHalation2
{
    pass Extract
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_ExtractHighlights;
        RenderTarget = texHalationPre;
    }
    
    pass BlurX
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_BlurX;
        RenderTarget = texHalationBlur;
    }
    
    pass BlurY
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_BlurY;
        RenderTarget = texHalationPre; 
    }
    
    pass Composite
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Composite;
    }
}