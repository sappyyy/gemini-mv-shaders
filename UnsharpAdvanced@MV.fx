// =====================================================================
// Advanced Unsharp Mask & Clarity Shader
// Self-contained: No #include dependencies required.
// =====================================================================

#ifndef UNSHARP_BLUR_RADIUS
#define UNSHARP_BLUR_RADIUS 10 // Equals 21 samples (-10 to +10)
#endif

namespace FXShaders
{

// =====================================================================
// UI / Uniforms
// =====================================================================

uniform int BlendMode <
    ui_category = "General";
    ui_label = "Blend Mode";
    ui_type = "combo";
    ui_items = "Standard Unsharp\0High-Pass Overlay\0High-Pass Soft Light\0High-Pass Hard Light\0Legacy FXShaders (Original)\0";
> = 0;

uniform float Amount <
    ui_category = "General";
    ui_label = "Overall Amount";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 3.0;
> = 1.0;

uniform float BlurScale <
    ui_category = "General";
    ui_label = "Blur Radius Scale";
    ui_type = "slider";
    ui_min = 0.01;
    ui_max = 2.0;
> = 1.0;

uniform bool PreserveSaturation <
    ui_category = "General";
    ui_label = "Preserve Original Saturation";
    ui_tooltip = "Sharpening typically increases color saturation. Enable this to apply the effect to Luminance (brightness) only.";
> = true;

uniform bool EnableSplit <
    ui_category = "Shadows & Highlights";
    ui_label = "Enable Shadows/Highlights Split";
    ui_tooltip = "If disabled, the Overall Amount applies equally to everything.";
> = false;

uniform float ShadowAmount <
    ui_category = "Shadows & Highlights";
    ui_label = "Shadows Amount";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
> = 1.0;

uniform float HighlightAmount <
    ui_category = "Shadows & Highlights";
    ui_label = "Highlights Amount";
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
> = 1.0;

uniform float TonalPivot <
    ui_category = "Shadows & Highlights";
    ui_label = "Tonal Pivot (Luma)";
    ui_tooltip = "The brightness level that separates shadows from highlights.";
    ui_type = "slider";
    ui_min = 0.1;
    ui_max = 0.9;
> = 0.5;

uniform float TonalFeather <
    ui_category = "Shadows & Highlights";
    ui_label = "Tonal Feather (Smoothness)";
    ui_type = "slider";
    ui_min = 0.01;
    ui_max = 0.5;
> = 0.2;

uniform int DebugMode <
    ui_category = "Debug";
    ui_label = "Debug View";
    ui_tooltip = "Visualize the inner workings of the shader.";
    ui_type = "combo";
    ui_items = "Off\0Show Blur (Low-Pass)\0Show Details (High-Pass)\0Show Shadows/Highlights Application\0Show Legacy Mask\0";
> = 0;

// =====================================================================
// Textures & Samplers
// =====================================================================

texture ColorTex : COLOR;
sampler ColorSRGB { Texture = ColorTex; SRGBTexture = false; };

texture OriginalTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler Original { Texture = OriginalTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

texture BlurTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler BlurSampler { Texture = BlurTex; MinFilter = LINEAR; MagFilter = LINEAR; MipFilter = LINEAR; };

// =====================================================================
// Native Helper Functions
// =====================================================================

void PostProcessVS(in uint id : SV_VertexID, out float4 pos : SV_Position, out float2 uv : TEXCOORD)
{
    uv.x = (id == 2) ? 2.0 : 0.0;
    uv.y = (id == 1) ? 2.0 : 0.0;
    pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

float GetLuma(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float3 BlendOverlay(float3 base, float3 blend)
{
    return lerp(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), step(0.5, base));
}

float3 BlendSoftLight(float3 base, float3 blend)
{
    float3 blend2 = blend * 2.0;
    return base * lerp(blend2 + base * (1.0 - blend2), sqrt(base) * (blend2 - 1.0) + 1.0, step(0.5, blend));
}

float3 BlendHardLight(float3 base, float3 blend)
{
    return BlendOverlay(blend, base);
}

float4 GaussianBlur1D(sampler tex, float2 uv, float2 dir)
{
    float4 color = 0.0;
    float totalWeight = 0.0;
    float sigma = max((float)UNSHARP_BLUR_RADIUS * BlurScale / 2.0, 0.001);
    float2 pixelSize = float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT);

    for (int i = -UNSHARP_BLUR_RADIUS; i <= UNSHARP_BLUR_RADIUS; i++)
    {
        float weight = exp(-(i * i) / (2.0 * sigma * sigma));
        color += tex2D(tex, uv + dir * i * pixelSize) * weight;
        totalWeight += weight;
    }

    return color / totalWeight;
}

// =====================================================================
// Pixel Shaders
// =====================================================================

float4 CopyOriginalPS(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET
{
    return tex2D(ColorSRGB, uv);
}

float4 BlurHorizontalPS(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET
{
    return GaussianBlur1D(Original, uv, float2(1.0, 0.0));
}

float4 BlendPS(float4 p : SV_POSITION, float2 uv : TEXCOORD) : SV_TARGET
{
    float4 blurColor = GaussianBlur1D(BlurSampler, uv, float2(0.0, 1.0));
    float4 origColor = tex2D(Original, uv);
    
    // ---------------------------------------------------------
    // DEBUG VIEWS
    // ---------------------------------------------------------
    if (DebugMode == 1) // Show Blur
        return float4(blurColor.rgb, origColor.a);
        
    if (DebugMode == 2) // Show High-Pass Details
        return float4((origColor.rgb - blurColor.rgb) + 0.5, origColor.a);
        
    if (DebugMode == 3) // Show Shadows/Highlights Application Heatmap
    {
        float luma = GetLuma(origColor.rgb);
        float highlightMask = smoothstep(TonalPivot - TonalFeather, TonalPivot + TonalFeather, luma);
        float shadowMask = 1.0 - highlightMask;
        
        // Visualizer: Red = Shadows Amount, Green = Highlights Amount.
        float3 debugView = float3(shadowMask * ShadowAmount, highlightMask * HighlightAmount, 0.0);
        
        // If split is disabled, just show a plain white mask
        if (!EnableSplit) debugView = float3(1.0, 1.0, 1.0); 
        
        // Displayed at 50% intensity so a max slider of 2.0 doesn't blow out the screen to pure white
        return float4(debugView * 0.5, origColor.a);
    }
        
    if (DebugMode == 4) // Show Legacy Mask
    {
        float mask = GetLuma(1.0 - blurColor.rgb) * 0.75;
        return float4(mask, mask, mask, origColor.a);
    }

    // ---------------------------------------------------------
    // NORMAL RENDERING
    // ---------------------------------------------------------
    float3 finalColor = origColor.rgb;
    float currentAmount = Amount;
    
    // Shadows / Highlights Masking Calculation
    if (EnableSplit)
    {
        float luma = GetLuma(origColor.rgb);
        float highlightMask = smoothstep(TonalPivot - TonalFeather, TonalPivot + TonalFeather, luma);
        float shadowMask = 1.0 - highlightMask;
        
        currentAmount *= (highlightMask * HighlightAmount) + (shadowMask * ShadowAmount);
    }

    // Apply selected blend mode
    if (BlendMode == 0) // Standard Unsharp Mask
    {
        float3 diff = origColor.rgb - blurColor.rgb;
        finalColor = origColor.rgb + (diff * currentAmount);
    }
    else if (BlendMode == 1) // High-Pass Overlay
    {
        float3 highPass = (origColor.rgb - blurColor.rgb) + 0.5;
        finalColor = lerp(origColor.rgb, BlendOverlay(origColor.rgb, highPass), currentAmount);
    }
    else if (BlendMode == 2) // High-Pass Soft Light
    {
        float3 highPass = (origColor.rgb - blurColor.rgb) + 0.5;
        finalColor = lerp(origColor.rgb, BlendSoftLight(origColor.rgb, highPass), currentAmount);
    }
    else if (BlendMode == 3) // High-Pass Hard Light
    {
        float3 highPass = (origColor.rgb - blurColor.rgb) + 0.5;
        finalColor = lerp(origColor.rgb, BlendHardLight(origColor.rgb, highPass), currentAmount);
    }
    else if (BlendMode == 4) // Legacy FXShaders
    {
        float mask = GetLuma(1.0 - blurColor.rgb) * 0.75;
        finalColor = lerp(origColor.rgb, BlendOverlay(origColor.rgb, float3(mask, mask, mask)), currentAmount);
    }

    // Isolate effect to Luminance to prevent color saturation shifts
    if (PreserveSaturation)
    {
        float finalLuma = GetLuma(finalColor);
        float origLuma = GetLuma(origColor.rgb);
        
        // Applies ONLY the brightness difference back onto the exact original RGB colors
        finalColor = origColor.rgb + (finalLuma - origLuma); 
    }

    return float4(finalColor, origColor.a);
}

// =====================================================================
// Technique
// =====================================================================

technique VM_Gemini_UnsharpAdvanced
{
    pass CopyOriginal
    {
        VertexShader = PostProcessVS;
        PixelShader = CopyOriginalPS;
        RenderTarget = OriginalTex;
    }
    pass BlurX
    {
        VertexShader = PostProcessVS;
        PixelShader = BlurHorizontalPS;
        RenderTarget = BlurTex;
    }
    pass BlurYAndBlend
    {
        VertexShader = PostProcessVS;
        PixelShader = BlendPS;
    }
}

}