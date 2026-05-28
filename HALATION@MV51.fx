#include "ReShade.fxh"

// ==============================================================================
// UI SETTINGS
// ==============================================================================

uniform int iDebugView <
    ui_type = "combo";
    ui_items = "Off\0Show Halation Blur\0Show Core Protection Mask\0Show Extracted Highlights (Before Blur)\0";
    ui_label = "Debug View";
    ui_tooltip = "Helps you visualize exactly what the shader is doing.";
    ui_category = "Debug";
> = 0;

uniform int iBlendMode <
    ui_type = "combo";
    ui_items = "Screen (Anti-Clipping)\0Additive (Realistic Light)\0";
    ui_label = "Blending Mode";
    ui_tooltip = "Screen is softer and protects against blowing out the image. Additive is how real light behaves and is brighter.";
    ui_category = "Halation Properties";
> = 0;

uniform float fHalationThreshold <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Threshold";
    ui_tooltip = "How bright a pixel needs to be to cause halation. Keep high (0.80+) to completely avoid midtones.";
    ui_category = "Halation Extraction";
> = 0.80;

uniform float fExtractionStrictness <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 5.0;
    ui_label = "Extraction Strictness";
    ui_tooltip = "Higher values aggressively suppress bright midtones, ensuring ONLY extreme highlights generate halation.";
    ui_category = "Halation Extraction";
> = 2.0;

// --- NEW SETTINGS FOR DARK NEIGHBORHOOD FIX ---
uniform float fLocalContrastRequirement <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Dark Neighborhood Requirement";
    ui_tooltip = "0.0 = Halation on ALL white objects (old behavior). 1.0 = Halation ONLY bleeds if the surrounding area is dark.";
    ui_category = "Halation Extraction (Contrast)";
> = 0.85;

uniform float fContrastRadius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 20.0;
    ui_label = "Neighborhood Search Radius";
    ui_tooltip = "How far out the shader looks to decide if the background is 'dark'.";
    ui_category = "Halation Extraction (Contrast)";
> = 10.0;
// ----------------------------------------------

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

// We now use 3 textures so Debug View 3 actually shows the unblurred extraction correctly.
texture texHalationPre   { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
texture texHalationBlur  { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
texture texHalationFinal { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };

sampler SamplerHalationPre   { Texture = texHalationPre;   };
sampler SamplerHalationBlur  { Texture = texHalationBlur;  };
sampler SamplerHalationFinal { Texture = texHalationFinal; };

// ==============================================================================
// HELPER FUNCTIONS
// ==============================================================================

float GetLuma(float3 color) 
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// ==============================================================================
// SHADER PASSES
// ==============================================================================

// Pass 1: Strict Extraction (Now with Local Contrast / Dark Neighborhood detection)
float4 PS_ExtractHighlights(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float luma = GetLuma(color);
    
    // 1. Hard cutoff: Anything below the threshold is exactly 0.0
    float highlight = max(0.0, luma - fHalationThreshold);
    highlight /= max(0.0001, 1.0 - fHalationThreshold);
    float thresholdMask = pow(highlight, fExtractionStrictness);
    
    // 2. NEW: Local Contrast (Dark Neighborhood) Check
    // We sample in an 8-point ring around the current pixel
    float2 px = ReShade::PixelSize * fContrastRadius;
    float localLuma = 0.0;
    
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(px.x, 0.0)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, 0.0)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(0.0, px.y)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(0.0, -px.y)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(px.x, px.y)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, -px.y)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(px.x, -px.y)).rgb);
    localLuma += GetLuma(tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, px.y)).rgb);
    localLuma /= 8.0; // Average brightness of the neighborhood
    
    // Isolation measures how much brighter the center is compared to its surroundings.
    // The * 1.5 ensures slightly thick bright edges don't get completely eliminated.
    float isolation = saturate((luma - localLuma) * 1.5); 
    
    // Blend between old behavior (always extract) and new behavior (only extract if isolated)
    float contrastMask = lerp(1.0, isolation, fLocalContrastRequirement);
    
    // 3. Apply tint and masks 
    float3 halationColor = color * fHalationTint * thresholdMask * contrastMask;
    
    return float4(halationColor, 1.0);
}

// Pass 2: Horizontal Advanced Gaussian Blur
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

// Pass 4: Composite with True Core Protection
float4 PS_Composite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    // Debug View 3 now correctly grabs the un-blurred extraction to show what the contrast mask did
    if (iDebugView == 3) return tex2D(SamplerHalationPre, texcoord);

    float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 halation = tex2D(SamplerHalationFinal, texcoord).rgb * fHalationIntensity; 

    // --- TRUE CORE PROTECTION ---
    float origLuma = GetLuma(original);
    
    float coreMask = smoothstep(fCoreThreshold, 1.0, origLuma) * fCoreProtection;
    
    float halationLuma = GetLuma(halation);
    float3 neutralWhiteBloom = float3(halationLuma, halationLuma, halationLuma);
    
    halation = lerp(halation, neutralWhiteBloom, coreMask);

    // --- BLENDING ---
    float3 finalColor = original;
    
    if (iBlendMode == 0) 
    {
        finalColor = original + halation - (original * saturate(halation));
    }
    else 
    {
        finalColor = original + halation;
    }
    
    // --- DEBUG VIEWS ---
    if (iDebugView == 1) return float4(halation, 1.0);
    if (iDebugView == 2) return float4(coreMask.xxx, 1.0);

    return float4(finalColor, 1.0);
}

// ==============================================================================
// TECHNIQUES
// ==============================================================================

technique AdvancedFilmicHalation5
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
        RenderTarget = texHalationFinal; // Now routes to a 3rd texture to fix debug views
    }
    
    pass Composite
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Composite;
    }
}