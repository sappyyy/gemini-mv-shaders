/*
    ACR Texture Replicator for ReShade (V3 - True Guided Filter)
    
    Replicates the "Texture" slider from Adobe Camera Raw / Lightroom perfectly.
    
    Uses a True Guided Image Filter (GIF) architecture.
    Unlike Bilateral filters (which look plastic/staircased on negative values) 
    or unblurred variance masks (which lose detail pop on positive values), 
    the True GIF provides flawless edge-preserving bandpass separation.
*/

#include "ReShade.fxh"

// ==========================================
// UI PARAMETERS
// ==========================================

uniform float fStrength <
    ui_type = "slider";
    ui_min = -2.0; ui_max = 4.0;
    ui_label = "Texture Strength";
    ui_tooltip = "Positive: Enhances medium textures organically.\nNegative: Smooths them (Flawless skin softening).";
> = 0.5;

uniform float fMidFreqRadius <
    ui_type = "slider";
    ui_min = 2.0; ui_max = 15.0;
    ui_label = "Coarse Radius (Detail Size)";
    ui_tooltip = "Determines the upper size limit of the textures being enhanced.";
> = 8.0;

uniform float fHighFreqRadius <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_label = "Fine Radius (Ignore Grain)";
    ui_tooltip = "Ignores details smaller than this radius. Prevents sharpening film grain/noise.";
> = 1.0;

uniform float fEdgeTolerance <
    ui_type = "slider";
    ui_min = 0.0001; ui_max = 0.02; format = "%.4f";
    ui_label = "Edge Tolerance (Variance)";
    ui_tooltip = "Determines what is considered a 'sharp edge'. 0.002 is highly recommended.";
> = 0.002;

uniform bool bDebugMode <
    ui_label = "Show Isolated Texture (Debug)";
> = false;

// ==========================================
// TEXTURES & SAMPLERS
// ==========================================
// RG16F is mandatory for floating-point mean and variance accuracy.

texture texTempI    { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sTempI      { Texture = texTempI; };

texture texMeanI_S  { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sMeanI_S    { Texture = texMeanI_S; };

texture texMeanI_L  { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sMeanI_L    { Texture = texMeanI_L; };

texture texTempAB   { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sTempAB     { Texture = texTempAB; };

texture texMeanAB_S { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sMeanAB_S   { Texture = texMeanAB_S; };

texture texMeanAB_L { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RG16F; };
sampler sMeanAB_L   { Texture = texMeanAB_L; };

// ==========================================
// FUNCTIONS & MACROS
// ==========================================

float GetLuma(float3 color) {
    return dot(color, float3(0.299, 0.587, 0.114));
}

// MACRO: Pass 1 - Blur Luma and Luma^2 (Horizontal)
#define DECLARE_BLUR_I_X(PassName, RadiusParam) \
void PassName(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float2 col : SV_Target) { \
    float2 sum = 0; float wSum = 0; float r = RadiusParam; \
    if (r <= 0.01) { float l = GetLuma(tex2D(ReShade::BackBuffer, uv).rgb); col = float2(l, l*l); return; } \
    float sigma = max(r / 2.0, 0.1); \
    int steps = min((int)ceil(r), 25); \
    for(int i = -steps; i <= steps; i++) { \
        float w = exp(-(i*i)/(2.0*sigma*sigma)); \
        float l = GetLuma(tex2Dlod(ReShade::BackBuffer, float4(uv + float2(i * ReShade::PixelSize.x, 0), 0, 0)).rgb); \
        sum += float2(l, l*l) * w; wSum += w; \
    } \
    col = sum / wSum; \
}

// MACRO: Pass 2 - Blur Luma and Luma^2 (Vertical)
#define DECLARE_BLUR_I_Y(PassName, RadiusParam, InputSampler) \
void PassName(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float2 col : SV_Target) { \
    float2 sum = 0; float wSum = 0; float r = RadiusParam; \
    if (r <= 0.01) { col = tex2D(InputSampler, uv).rg; return; } \
    float sigma = max(r / 2.0, 0.1); \
    int steps = min((int)ceil(r), 25); \
    for(int i = -steps; i <= steps; i++) { \
        float w = exp(-(i*i)/(2.0*sigma*sigma)); \
        sum += tex2Dlod(InputSampler, float4(uv + float2(0, i * ReShade::PixelSize.y), 0, 0)).rg * w; \
        wSum += w; \
    } \
    col = sum / wSum; \
}

// MACRO: Pass 3 - Compute Linear Coefficients (A and B) and Blur (Horizontal)
#define DECLARE_BLUR_AB_X(PassName, RadiusParam, MeanSampler) \
void PassName(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float2 col : SV_Target) { \
    float2 sum = 0; float wSum = 0; float r = RadiusParam; \
    if (r <= 0.01) { \
        float2 m = tex2D(MeanSampler, uv).rg; \
        float v = max(m.g - m.r * m.r, 0.0); \
        float a = v / (v + fEdgeTolerance); \
        col = float2(a, m.r - a * m.r); return; \
    } \
    float sigma = max(r / 2.0, 0.1); \
    int steps = min((int)ceil(r), 25); \
    for(int i = -steps; i <= steps; i++) { \
        float w = exp(-(i*i)/(2.0*sigma*sigma)); \
        float2 m = tex2Dlod(MeanSampler, float4(uv + float2(i * ReShade::PixelSize.x, 0), 0, 0)).rg; \
        float v = max(m.g - m.r * m.r, 0.0); \
        float a = v / (v + fEdgeTolerance); \
        sum += float2(a, m.r - a * m.r) * w; wSum += w; \
    } \
    col = sum / wSum; \
}

// MACRO: Pass 4 - Blur Coefficients (Vertical)
#define DECLARE_BLUR_AB_Y(PassName, RadiusParam, InputSampler) \
void PassName(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float2 col : SV_Target) { \
    float2 sum = 0; float wSum = 0; float r = RadiusParam; \
    if (r <= 0.01) { col = tex2D(InputSampler, uv).rg; return; } \
    float sigma = max(r / 2.0, 0.1); \
    int steps = min((int)ceil(r), 25); \
    for(int i = -steps; i <= steps; i++) { \
        float w = exp(-(i*i)/(2.0*sigma*sigma)); \
        sum += tex2Dlod(InputSampler, float4(uv + float2(0, i * ReShade::PixelSize.y), 0, 0)).rg * w; \
        wSum += w; \
    } \
    col = sum / wSum; \
}

// ==========================================
// PASS GENERATION
// ==========================================

// Generate Small Radius Passes
DECLARE_BLUR_I_X(PassSmall_I_X, fHighFreqRadius)
DECLARE_BLUR_I_Y(PassSmall_I_Y, fHighFreqRadius, sTempI)
DECLARE_BLUR_AB_X(PassSmall_AB_X, fHighFreqRadius, sMeanI_S)
DECLARE_BLUR_AB_Y(PassSmall_AB_Y, fHighFreqRadius, sTempAB)

// Generate Large Radius Passes
DECLARE_BLUR_I_X(PassLarge_I_X, fMidFreqRadius)
DECLARE_BLUR_I_Y(PassLarge_I_Y, fMidFreqRadius, sTempI)
DECLARE_BLUR_AB_X(PassLarge_AB_X, fMidFreqRadius, sMeanI_L)
DECLARE_BLUR_AB_Y(PassLarge_AB_Y, fMidFreqRadius, sTempAB)

// Combine Pass
void PassCombine(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 col : SV_Target) {
    float4 original = tex2D(ReShade::BackBuffer, uv);
    float luma = GetLuma(original.rgb);
    
    // Evaluate Guided Filter output for Small Radius (Base guide)
    float2 ab_S = tex2D(sMeanAB_S, uv).rg;
    float filtered_S = ab_S.r * luma + ab_S.g;
    
    // Evaluate Guided Filter output for Large Radius (Coarse guide)
    float2 ab_L = tex2D(sMeanAB_L, uv).rg;
    float filtered_L = ab_L.r * luma + ab_L.g;
    
    // Isolate the Medium Frequencies exactly
    float midFreqDetail = filtered_S - filtered_L;
    
    if (bDebugMode) {
        col = float4(midFreqDetail * fStrength + 0.5.rrr, 1.0);
        return;
    }
    
    col.rgb = saturate(original.rgb + (midFreqDetail * fStrength));
    col.a = original.a;
}

// ==========================================
// TECHNIQUE
// ==========================================

technique ACR_Texture_Ultimate {
    // 1. Calculate base image structure (Small Radius)
    pass { VertexShader = PostProcessVS; PixelShader = PassSmall_I_X; RenderTarget = texTempI; }
    pass { VertexShader = PostProcessVS; PixelShader = PassSmall_I_Y; RenderTarget = texMeanI_S; }
    
    // 2. Compute and blur structure coefficients (Small Radius)
    pass { VertexShader = PostProcessVS; PixelShader = PassSmall_AB_X; RenderTarget = texTempAB; }
    pass { VertexShader = PostProcessVS; PixelShader = PassSmall_AB_Y; RenderTarget = texMeanAB_S; }
    
    // 3. Calculate coarse image structure (Large Radius)
    pass { VertexShader = PostProcessVS; PixelShader = PassLarge_I_X; RenderTarget = texTempI; }
    pass { VertexShader = PostProcessVS; PixelShader = PassLarge_I_Y; RenderTarget = texMeanI_L; }
    
    // 4. Compute and blur structure coefficients (Large Radius)
    pass { VertexShader = PostProcessVS; PixelShader = PassLarge_AB_X; RenderTarget = texTempAB; }
    pass { VertexShader = PostProcessVS; PixelShader = PassLarge_AB_Y; RenderTarget = texMeanAB_L; }
    
    // 5. Final Frequency separation and Combine
    pass { VertexShader = PostProcessVS; PixelShader = PassCombine; }
}