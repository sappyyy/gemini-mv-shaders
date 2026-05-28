#include "ReShade.fxh"

// ==============================================================================
// UI SETTINGS
// ==============================================================================

uniform int iDebugView <
    ui_type = "combo";
    ui_items = "Off\0Show Halation Blur\0Show Core Protection Mask\0";
    ui_label = "Debug View";
    ui_tooltip = "Helps you visualize exactly what the shader is doing.";
    ui_category = "Debug";
> = 0;

uniform float fHalationThreshold <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Threshold";
    ui_tooltip = "How bright a pixel needs to be to cause halation. Keep high (0.6 - 0.8) for realism.";
    ui_category = "Halation Properties";
> = 0.70;

uniform float fHalationIntensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 5.0;
    ui_label = "Halation Intensity";
    ui_tooltip = "Overall strength of the halation glow.";
    ui_category = "Halation Properties";
> = 1.5;

uniform float fHalationRadius <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_label = "Scattering Radius";
    ui_tooltip = "How far the light scatters across the film emulsion.";
    ui_category = "Halation Properties";
> = 3.0;

uniform float3 fHalationTint <
    ui_type = "color";
    ui_label = "Emulsion Tint (Red/Orange)";
    ui_tooltip = "The color of the bottom emulsion layer.";
    ui_category = "Color";
> = float3(1.0, 0.15, 0.02);

uniform float fCoreProtection <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "White Core Protection";
    ui_tooltip = "Forces the center of bright lights to remain white, pushing the red tint exclusively to the fringes. Prevents 'pink lightbulb' syndrome.";
    ui_category = "Highlight Preservation";
> = 0.9;

uniform float fCoreThreshold <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.0;
    ui_label = "Core Protection Threshold";
    ui_tooltip = "Determines exactly where the 'core' of the light starts.";
    ui_category = "Highlight Preservation";
> = 0.85;

// ==============================================================================
// TEXTURES & SAMPLERS
// ==============================================================================

// Half-resolution for a wider, softer blur and better performance
texture texHalationPre  { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
texture texHalationBlur { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };

sampler SamplerHalationPre  { Texture = texHalationPre;  };
sampler SamplerHalationBlur { Texture = texHalationBlur; };

// ==============================================================================
// HELPER FUNCTIONS (Linear Space Math)
// ==============================================================================

float3 SRGBToLinear(float3 c) 
{ 
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); 
}

float3 LinearToSRGB(float3 c) 
{ 
    return max(1.055 * pow(abs(c), 0.416666667) - 0.055, 0.0); 
}

float GetLuma(float3 color) 
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// ==============================================================================
// SHADER PASSES
// ==============================================================================

// Pass 1: Extract and tint the extreme highlights in Linear Space
float4 PS_ExtractHighlights(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    color = SRGBToLinear(color); // Work in linear space for realistic light behavior
    
    float luma = GetLuma(color);
    
    // Smoothstep up to 1.5 to allow super-bright highlights (HDR-like behavior)
    float thresholdMask = smoothstep(fHalationThreshold, 1.5, luma);
    
    // Apply tint during extraction
    float3 halationColor = color * fHalationTint * thresholdMask;
    
    return float4(halationColor, 1.0);
}

// Pass 2: Horizontal Advanced Gaussian Blur (15 taps for smooth filmic falloff)
float4 PS_BlurX(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixelSize = ReShade::PixelSize * 2.0 * fHalationRadius; 
    float4 sum = 0.0;
    
    sum += tex2D(SamplerHalationPre, texcoord + float2(-7.0, 0.0) * pixelSize) * 0.004429;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-6.0, 0.0) * pixelSize) * 0.008957;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-5.0, 0.0) * pixelSize) * 0.021596;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-4.0, 0.0) * pixelSize) * 0.044368;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-3.0, 0.0) * pixelSize) * 0.077674;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-2.0, 0.0) * pixelSize) * 0.115876;
    sum += tex2D(SamplerHalationPre, texcoord + float2(-1.0, 0.0) * pixelSize) * 0.147308;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 0.0, 0.0) * pixelSize) * 0.159576;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 1.0, 0.0) * pixelSize) * 0.147308;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 2.0, 0.0) * pixelSize) * 0.115876;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 3.0, 0.0) * pixelSize) * 0.077674;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 4.0, 0.0) * pixelSize) * 0.044368;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 5.0, 0.0) * pixelSize) * 0.021596;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 6.0, 0.0) * pixelSize) * 0.008957;
    sum += tex2D(SamplerHalationPre, texcoord + float2( 7.0, 0.0) * pixelSize) * 0.004429;
    
    return sum;
}

// Pass 3: Vertical Advanced Gaussian Blur
float4 PS_BlurY(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float2 pixelSize = ReShade::PixelSize * 2.0 * fHalationRadius;
    float4 sum = 0.0;
    
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -7.0) * pixelSize) * 0.004429;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -6.0) * pixelSize) * 0.008957;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -5.0) * pixelSize) * 0.021596;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -4.0) * pixelSize) * 0.044368;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -3.0) * pixelSize) * 0.077674;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -2.0) * pixelSize) * 0.115876;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0, -1.0) * pixelSize) * 0.147308;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  0.0) * pixelSize) * 0.159576;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  1.0) * pixelSize) * 0.147308;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  2.0) * pixelSize) * 0.115876;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  3.0) * pixelSize) * 0.077674;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  4.0) * pixelSize) * 0.044368;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  5.0) * pixelSize) * 0.021596;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  6.0) * pixelSize) * 0.008957;
    sum += tex2D(SamplerHalationBlur, texcoord + float2(0.0,  7.0) * pixelSize) * 0.004429;
    
    return sum;
}

// Pass 4: Composite with True Core Protection and Linear Blend
float4 PS_Composite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
    
    // Linearize for accurate blending
    float3 linOriginal = SRGBToLinear(original); 
    float3 linHalation = tex2D(SamplerHalationPre, texcoord).rgb * fHalationIntensity; 

    // --- TRUE CORE PROTECTION ---
    float origLuma = GetLuma(linOriginal);
    
    // Find the center of bright objects
    float coreMask = smoothstep(fCoreThreshold, 1.2, origLuma) * fCoreProtection;
    
    // Instead of making the halation dark, we neutralize its color to pure white at the core.
    // This allows the bright center to stay bright white, while the edges remain red!
    float halationLuma = GetLuma(linHalation);
    float3 neutralWhiteBloom = float3(halationLuma, halationLuma, halationLuma);
    
    linHalation = lerp(linHalation, neutralWhiteBloom, coreMask);

    // --- LINEAR SCREEN BLENDING ---
    float3 finalColor = linOriginal + linHalation - (linOriginal * saturate(linHalation));
    
    // Convert back to Gamma space for the monitor
    finalColor = LinearToSRGB(finalColor);
    
    // --- DEBUG VIEWS ---
    if (iDebugView == 1) return float4(LinearToSRGB(linHalation), 1.0);
    if (iDebugView == 2) return float4(coreMask.xxx, 1.0);

    return float4(finalColor, 1.0);
}

// ==============================================================================
// TECHNIQUES
// ==============================================================================

technique AdvancedFilmicHalation
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