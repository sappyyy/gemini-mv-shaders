/*
    Advanced Filmic Glow & Halation for ReShade
    Author: Assistant
    Description: High-quality, multi-octave bloom with physical linear-space processing,
                 smooth knee thresholding, cinematic film halation, highlight protection,
                 and multiple blend modes.
*/

#include "ReShade.fxh"

// ===============================================================================
// UI CONTROLS
// ===============================================================================

uniform bool DebugGlow <
    ui_category = "Debug";
    ui_label = "Show Glow Only";
    ui_tooltip = "Mutes the base image to show only the generated glow and halation.";
> = false;

uniform float Threshold <
    ui_category = "Luminance Extraction";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Glow Threshold";
    ui_tooltip = "Minimum brightness required for pixels to emit glow.";
> = 0.8;

uniform float SmoothKnee <
    ui_category = "Luminance Extraction";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Smooth Knee";
    ui_tooltip = "Softens the transition into the threshold, preventing harsh cutoffs.";
> = 0.5;

uniform float GlowIntensity <
    ui_category = "Filmic Glow Shape";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Global Glow Intensity";
> = 1.0;

uniform float GlowRadius <
    ui_category = "Filmic Glow Shape";
    ui_type = "slider";
    ui_min = 0.5; ui_max = 2.5; ui_step = 0.01;
    ui_label = "Glow Radius (Spread)";
    ui_tooltip = "Expands the blur radius. Keep between 1.0 and 1.5 for highest quality.";
> = 1.2;

uniform float3 GlowTint <
    ui_category = "Color & Halation";
    ui_type = "color";
    ui_label = "Glow Tint";
> = float3(1.0, 0.95, 0.9);

uniform float HalationIntensity <
    ui_category = "Color & Halation";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Halation Intensity";
    ui_tooltip = "Emulates the red/orange light scattering inside physical film emulsion.";
> = 0.4;

uniform float3 HalationTint <
    ui_category = "Color & Halation";
    ui_type = "color";
    ui_label = "Halation Tint";
> = float3(1.0, 0.2, 0.05);

uniform int BlendMode <
    ui_category = "Composition & Blending";
    ui_type = "combo";
    ui_label = "Blend Mode";
    ui_items = "Additive (Physical Light)\0Screen (Soft LDR)\0Lighten (Subtle)\0";
    ui_tooltip = "Additive: Most realistic, adds light mathematically.\nScreen: Softer, prevents blowing out whites.\nLighten: Only applies glow if it's brighter than the background.";
> = 0;

uniform float HighlightProtection <
    ui_category = "Composition & Blending";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Highlight Protection";
    ui_tooltip = "Attenuates glow in already-bright areas to prevent the image from overexposing or blowing out detail. 0.0 = Off, 1.0 = Max Protection.";
> = 0.3;

// ===============================================================================
// TEXTURES & SAMPLERS (16-bit Float for HDR precision + Linear Filtering)
// ===============================================================================

texture texColor : COLOR;
sampler sColor { Texture = texColor; SRGBTexture = false; };

// Octave 1 (1/2 Resolution)
texture texGlow1H { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sGlow1H   { Texture = texGlow1H; Filter = LINEAR; };
texture texGlow1V { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sGlow1V   { Texture = texGlow1V; Filter = LINEAR; };

// Octave 2 (1/4 Resolution)
texture texGlow2H { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA16F; };
sampler sGlow2H   { Texture = texGlow2H; Filter = LINEAR; };
texture texGlow2V { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA16F; };
sampler sGlow2V   { Texture = texGlow2V; Filter = LINEAR; };

// Octave 3 (1/8 Resolution)
texture texGlow3H { Width = BUFFER_WIDTH / 8; Height = BUFFER_HEIGHT / 8; Format = RGBA16F; };
sampler sGlow3H   { Texture = texGlow3H; Filter = LINEAR; };
texture texGlow3V { Width = BUFFER_WIDTH / 8; Height = BUFFER_HEIGHT / 8; Format = RGBA16F; };
sampler sGlow3V   { Texture = texGlow3V; Filter = LINEAR; };

// ===============================================================================
// HELPER FUNCTIONS
// ===============================================================================

float3 ToLinear(float3 col) { return pow(abs(col), 2.2); }
float3 ToSRGB(float3 col)   { return pow(abs(col), 1.0 / 2.2); }

float GetLuminance(float3 col) {
    return dot(col, float3(0.2126, 0.7152, 0.0722));
}

// 13-tap Separable Gaussian Blur
float3 GaussianBlur(sampler tex, float2 uv, float2 dir, float radius) {
    float3 color = 0.0;
    float weights[7] = { 0.199471, 0.176033, 0.120985, 0.064759, 0.026995, 0.008764, 0.002216 };
    
    color += tex2D(tex, uv).rgb * weights[0];
    for (int i = 1; i < 7; i++) {
        float2 offset = dir * (float(i) * radius);
        color += tex2D(tex, uv + offset).rgb * weights[i];
        color += tex2D(tex, uv - offset).rgb * weights[i];
    }
    return color;
}

// ===============================================================================
// PIXEL SHADERS
// ===============================================================================

// PASS 1: Extract Highlights 
void PS_PreFilter(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 color = ToLinear(tex2D(sColor, uv).rgb);
    float luma = GetLuminance(color);
    
    // Smooth Knee Thresholding
    float knee = Threshold * SmoothKnee + 1e-5;
    float curve = luma - Threshold + knee;
    curve = clamp(curve, 0.0, 2.0 * knee);
    curve = (curve * curve) / (4.0 * knee);
    
    float mask = max(luma - Threshold, curve) / max(luma, 1e-5);
    outColor = float4(color * mask, 1.0);
}

// PASS 2 & 3: Octave 1 (1/2 Res)
void PS_Blur1H(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow1V, uv, float2(1.0 / (BUFFER_WIDTH / 2.0), 0.0), GlowRadius), 1.0);
}
void PS_Blur1V(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow1H, uv, float2(0.0, 1.0 / (BUFFER_HEIGHT / 2.0)), GlowRadius), 1.0);
}

// PASS 4 & 5: Octave 2 (1/4 Res) - Hardware bilinear filtering applies during this downsample
void PS_Blur2H(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow1V, uv, float2(1.0 / (BUFFER_WIDTH / 4.0), 0.0), GlowRadius), 1.0);
}
void PS_Blur2V(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow2H, uv, float2(0.0, 1.0 / (BUFFER_HEIGHT / 4.0)), GlowRadius), 1.0);
}

// PASS 6 & 7: Octave 3 (1/8 Res)
void PS_Blur3H(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow2V, uv, float2(1.0 / (BUFFER_WIDTH / 8.0), 0.0), GlowRadius), 1.0);
}
void PS_Blur3V(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(GaussianBlur(sGlow3H, uv, float2(0.0, 1.0 / (BUFFER_HEIGHT / 8.0)), GlowRadius), 1.0);
}

// PASS 8: Final Composition
void PS_Composite(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 baseColor = ToLinear(tex2D(sColor, uv).rgb);
    
    // Sample the octaves
    float3 glow1 = tex2D(sGlow1V, uv).rgb;
    float3 glow2 = tex2D(sGlow2V, uv).rgb;
    float3 glow3 = tex2D(sGlow3V, uv).rgb;
    
    // Combine with filmic weights (exponential falloff)
    float3 combinedGlow = (glow1 * 0.5) + (glow2 * 0.35) + (glow3 * 0.15);
    combinedGlow *= GlowIntensity * GlowTint;
    
    // Process Halation (using the tightest blur octave)
    float3 halation = glow1 * HalationIntensity * HalationTint;
    
    // Total added light
    float3 totalGlow = combinedGlow + halation;
    
    // ==========================================
    // HIGHLIGHT PROTECTION
    // ==========================================
    float baseLuma = GetLuminance(baseColor);
    // As baseLuma approaches 1.0, reduce glow based on HighlightProtection slider
    float hpMask = lerp(1.0, saturate(1.0 - baseLuma), HighlightProtection);
    totalGlow *= hpMask;

    // ==========================================
    // BLEND MODES
    // ==========================================
    float3 finalColor = baseColor;
    
    if (BlendMode == 0) {
        // Additive (Linear Dodge)
        finalColor = baseColor + totalGlow;
    } 
    else if (BlendMode == 1) {
        // Screen (Clamped to avoid HDR inversion math errors)
        float3 cb = saturate(baseColor);
        float3 cg = saturate(totalGlow);
        finalColor = cb + cg - (cb * cg);
        // Add back any raw HDR data above 1.0 that was cut off by the saturate
        finalColor += max(0.0, baseColor - 1.0); 
    } 
    else if (BlendMode == 2) {
        // Lighten
        finalColor = max(baseColor, totalGlow);
    }
    
    // Debug Mode Overlay
    if (DebugGlow) {
        finalColor = totalGlow;
    }
    
    // Return to sRGB space for final display output
    outColor = float4(ToSRGB(finalColor), 1.0);
}

// ===============================================================================
// TECHNIQUE
// ===============================================================================

technique MV_FilmicGlow
{
    // Extract Threshold
    pass PreFilter { VertexShader = PostProcessVS; PixelShader = PS_PreFilter; RenderTarget = texGlow1V; }
    
    // Octave 1
    pass Blur1H { VertexShader = PostProcessVS; PixelShader = PS_Blur1H; RenderTarget = texGlow1H; }
    pass Blur1V { VertexShader = PostProcessVS; PixelShader = PS_Blur1V; RenderTarget = texGlow1V; }
    
    // Octave 2
    pass Blur2H { VertexShader = PostProcessVS; PixelShader = PS_Blur2H; RenderTarget = texGlow2H; }
    pass Blur2V { VertexShader = PostProcessVS; PixelShader = PS_Blur2V; RenderTarget = texGlow2V; }
    
    // Octave 3 
    pass Blur3H { VertexShader = PostProcessVS; PixelShader = PS_Blur3H; RenderTarget = texGlow3H; }
    pass Blur3V { VertexShader = PostProcessVS; PixelShader = PS_Blur3V; RenderTarget = texGlow3V; }
    
    // Composition
    pass Composite { VertexShader = PostProcessVS; PixelShader = PS_Composite; }
}