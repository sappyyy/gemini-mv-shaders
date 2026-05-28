/*
    ADVANCED NEXT-GEN BLOOM FOR RESHADE
    Based on the Dual-Filtering method (13-tap downsample, 9-tap upsample)
    Features Soft-Knee thresholding, HDR precision, and multiple blend modes.
*/

#include "ReShade.fxh"

// ===============================================================================
// UI SETTINGS
// ===============================================================================

uniform float BloomThreshold <
    ui_category = "Extraction";
    ui_type = "slider";
    ui_label = "Bloom Threshold";
    ui_tooltip = "Luminance required to start glowing.";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.8;

uniform float BloomSoftKnee <
    ui_category = "Extraction";
    ui_type = "slider";
    ui_label = "Soft Knee";
    ui_tooltip = "Smoothes the transition between glowing and non-glowing areas.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float BloomIntensity <
    ui_category = "Appearance";
    ui_type = "slider";
    ui_label = "Bloom Intensity";
    ui_tooltip = "Overall brightness of the bloom.";
    ui_min = 0.0; ui_max = 5.0; ui_step = 0.01;
> = 1.0;

uniform float BloomSpread <
    ui_category = "Appearance";
    ui_type = "slider";
    ui_label = "Bloom Spread (Radius)";
    ui_tooltip = "How far the bloom spreads across the screen.";
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.01;
> = 1.0;

uniform float BloomSaturation <
    ui_category = "Color";
    ui_type = "slider";
    ui_label = "Bloom Saturation";
    ui_tooltip = "Vibrance of the bloom glow.";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
> = 1.2;

uniform float3 BloomTint <
    ui_category = "Color";
    ui_type = "color";
    ui_label = "Bloom Tint";
    ui_tooltip = "Color tint applied to the bloom.";
> = float3(1.0, 1.0, 1.0);

uniform int BlendMode <
    ui_category = "Compositing";
    ui_type = "combo";
    ui_label = "Blend Mode";
    ui_items = "Screen\0Additive (Linear)\0Soft Light (Cinematic)\0Overlay\0Mix (Interpolation)\0";
    ui_tooltip = "How the bloom is applied to the original image.";
> = 0;

uniform bool DebugBloom <
    ui_category = "Debug";
    ui_label = "Show Bloom Only";
    ui_tooltip = "Isolates the bloom texture for fine-tuning.";
> = false;


// ===============================================================================
// TEXTURES & SAMPLERS
// ===============================================================================

// We use RGBA16F format to maintain HDR precision and prevent banding.
#define TEX_FORMAT RGBA16F

texture texDown1 { Width = BUFFER_WIDTH / 2;   Height = BUFFER_HEIGHT / 2;   Format = TEX_FORMAT; };
texture texDown2 { Width = BUFFER_WIDTH / 4;   Height = BUFFER_HEIGHT / 4;   Format = TEX_FORMAT; };
texture texDown3 { Width = BUFFER_WIDTH / 8;   Height = BUFFER_HEIGHT / 8;   Format = TEX_FORMAT; };
texture texDown4 { Width = BUFFER_WIDTH / 16;  Height = BUFFER_HEIGHT / 16;  Format = TEX_FORMAT; };
texture texDown5 { Width = BUFFER_WIDTH / 32;  Height = BUFFER_HEIGHT / 32;  Format = TEX_FORMAT; };
texture texDown6 { Width = BUFFER_WIDTH / 64;  Height = BUFFER_HEIGHT / 64;  Format = TEX_FORMAT; };

texture texUp5 { Width = BUFFER_WIDTH / 32;  Height = BUFFER_HEIGHT / 32;  Format = TEX_FORMAT; };
texture texUp4 { Width = BUFFER_WIDTH / 16;  Height = BUFFER_HEIGHT / 16;  Format = TEX_FORMAT; };
texture texUp3 { Width = BUFFER_WIDTH / 8;   Height = BUFFER_HEIGHT / 8;   Format = TEX_FORMAT; };
texture texUp2 { Width = BUFFER_WIDTH / 4;   Height = BUFFER_HEIGHT / 4;   Format = TEX_FORMAT; };
texture texUp1 { Width = BUFFER_WIDTH / 2;   Height = BUFFER_HEIGHT / 2;   Format = TEX_FORMAT; };

sampler sDown1 { Texture = texDown1; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDown2 { Texture = texDown2; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDown3 { Texture = texDown3; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDown4 { Texture = texDown4; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDown5 { Texture = texDown5; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sDown6 { Texture = texDown6; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };

sampler sUp5 { Texture = texUp5; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sUp4 { Texture = texUp4; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sUp3 { Texture = texUp3; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sUp2 { Texture = texUp2; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };
sampler sUp1 { Texture = texUp1; Filter = LINEAR; AddressU = CLAMP; AddressV = CLAMP; };


// ===============================================================================
// HELPER FUNCTIONS
// ===============================================================================

float GetLuminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// 13-tap Downsample Filter (Karis / Call of Duty method)
float3 Downsample(sampler2D tex, float2 uv, float2 texelSize) {
    float3 A = tex2D(tex, uv - texelSize * float2(1.0, 1.0)).rgb;
    float3 B = tex2D(tex, uv + texelSize * float2(0.0, -1.0)).rgb;
    float3 C = tex2D(tex, uv + texelSize * float2(1.0, -1.0)).rgb;
    float3 D = tex2D(tex, uv + texelSize * float2(-0.5, -0.5)).rgb;
    float3 E = tex2D(tex, uv + texelSize * float2(0.5, -0.5)).rgb;
    float3 F = tex2D(tex, uv + texelSize * float2(-1.0, 0.0)).rgb;
    float3 G = tex2D(tex, uv).rgb;
    float3 H = tex2D(tex, uv + texelSize * float2(1.0, 0.0)).rgb;
    float3 I = tex2D(tex, uv + texelSize * float2(-0.5, 0.5)).rgb;
    float3 J = tex2D(tex, uv + texelSize * float2(0.5, 0.5)).rgb;
    float3 K = tex2D(tex, uv + texelSize * float2(-1.0, 1.0)).rgb;
    float3 L = tex2D(tex, uv + texelSize * float2(0.0, 1.0)).rgb;
    float3 M = tex2D(tex, uv + texelSize * float2(1.0, 1.0)).rgb;

    float2 div = (1.0 / 4.0) * float2(0.5, 0.125);

    float3 color = (D + E + I + J) * div.x;
    color += (A + B + G + F) * div.y;
    color += (B + C + H + G) * div.y;
    color += (F + G + L + K) * div.y;
    color += (G + H + M + L) * div.y;

    return color;
}

// 9-tap Upsample Filter (Tent)
float3 Upsample(sampler2D tex, float2 uv, float2 texelSize, float spread) {
    float x = texelSize.x * spread;
    float y = texelSize.y * spread;

    float3 a = tex2D(tex, float2(uv.x - x, uv.y + y)).rgb;
    float3 b = tex2D(tex, float2(uv.x,     uv.y + y)).rgb;
    float3 c = tex2D(tex, float2(uv.x + x, uv.y + y)).rgb;
    float3 d = tex2D(tex, float2(uv.x - x, uv.y)).rgb;
    float3 e = tex2D(tex, float2(uv.x,     uv.y)).rgb;
    float3 f = tex2D(tex, float2(uv.x + x, uv.y)).rgb;
    float3 g = tex2D(tex, float2(uv.x - x, uv.y - y)).rgb;
    float3 h = tex2D(tex, float2(uv.x,     uv.y - y)).rgb;
    float3 i = tex2D(tex, float2(uv.x + x, uv.y - y)).rgb;

    float3 color = e * 4.0;
    color += (b + d + f + h) * 2.0;
    color += (a + c + g + i);
    color *= 1.0 / 16.0;

    return color;
}


// ===============================================================================
// SHADER PASSES
// ===============================================================================

// Pass 1: Extract Brights + First Downsample
void PS_Extract(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 color = tex2D(ReShade::BackBuffer, uv).rgb;
    
    // Soft Knee Curve formulation
    float luminance = GetLuminance(color);
    float knee = BloomThreshold * BloomSoftKnee;
    
    float soft = luminance - BloomThreshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.00001);
    
    float multiplier = max(luminance - BloomThreshold, soft) / max(luminance, 0.00001);
    
    outColor = float4(color * multiplier, 1.0);
}

// Downsample Chain
void PS_Down2(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(Downsample(sDown1, uv, 1.0 / float2(BUFFER_WIDTH/2, BUFFER_HEIGHT/2)), 1.0);
}
void PS_Down3(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(Downsample(sDown2, uv, 1.0 / float2(BUFFER_WIDTH/4, BUFFER_HEIGHT/4)), 1.0);
}
void PS_Down4(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(Downsample(sDown3, uv, 1.0 / float2(BUFFER_WIDTH/8, BUFFER_HEIGHT/8)), 1.0);
}
void PS_Down5(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(Downsample(sDown4, uv, 1.0 / float2(BUFFER_WIDTH/16, BUFFER_HEIGHT/16)), 1.0);
}
void PS_Down6(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    outColor = float4(Downsample(sDown5, uv, 1.0 / float2(BUFFER_WIDTH/32, BUFFER_HEIGHT/32)), 1.0);
}

// Upsample & Combine Chain
void PS_Up5(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 up = Upsample(sDown6, uv, 1.0 / float2(BUFFER_WIDTH/64, BUFFER_HEIGHT/64), BloomSpread);
    float3 base = tex2D(sDown5, uv).rgb;
    outColor = float4(base + up, 1.0);
}
void PS_Up4(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 up = Upsample(sUp5, uv, 1.0 / float2(BUFFER_WIDTH/32, BUFFER_HEIGHT/32), BloomSpread);
    float3 base = tex2D(sDown4, uv).rgb;
    outColor = float4(base + up, 1.0);
}
void PS_Up3(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 up = Upsample(sUp4, uv, 1.0 / float2(BUFFER_WIDTH/16, BUFFER_HEIGHT/16), BloomSpread);
    float3 base = tex2D(sDown3, uv).rgb;
    outColor = float4(base + up, 1.0);
}
void PS_Up2(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 up = Upsample(sUp3, uv, 1.0 / float2(BUFFER_WIDTH/8, BUFFER_HEIGHT/8), BloomSpread);
    float3 base = tex2D(sDown2, uv).rgb;
    outColor = float4(base + up, 1.0);
}
void PS_Up1(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 up = Upsample(sUp2, uv, 1.0 / float2(BUFFER_WIDTH/4, BUFFER_HEIGHT/4), BloomSpread);
    float3 base = tex2D(sDown1, uv).rgb;
    outColor = float4(base + up, 1.0);
}

// Final Compositing Pass
void PS_Composite(float4 vpos : SV_Position, float2 uv : TEXCOORD, out float4 outColor : SV_Target) {
    float3 original = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 bloom = Upsample(sUp1, uv, 1.0 / float2(BUFFER_WIDTH/2, BUFFER_HEIGHT/2), BloomSpread);
    
    // Apply Saturation
    float luma = GetLuminance(bloom);
    bloom = lerp(float3(luma, luma, luma), bloom, BloomSaturation);
    
    // Apply Tint and Intensity
    bloom *= BloomTint * BloomIntensity;

    if (DebugBloom) {
        outColor = float4(bloom, 1.0);
        return;
    }

    float3 finalColor = original;

    // Blending Methods
    if (BlendMode == 0) {
        // Screen
        finalColor = 1.0 - (1.0 - original) * (1.0 - bloom);
    } 
    else if (BlendMode == 1) {
        // Additive
        finalColor = original + bloom;
    } 
    else if (BlendMode == 2) {
        // Soft Light (Pegtop)
        finalColor = (1.0 - 2.0 * bloom) * original * original + 2.0 * bloom * original;
        finalColor = lerp(original, finalColor, BloomIntensity); // Normalizing for intensity
    } 
    else if (BlendMode == 3) {
        // Overlay
        float3 check = step(0.5, original);
        float3 overlayColor = check * (1.0 - 2.0 * (1.0 - original) * (1.0 - bloom)) + 
                              (1.0 - check) * (2.0 * original * bloom);
        finalColor = lerp(original, overlayColor, BloomIntensity);
    }
    else if (BlendMode == 4) {
        // Mix
        finalColor = lerp(original, bloom, clamp(BloomIntensity * 0.5, 0.0, 1.0));
    }

    outColor = float4(finalColor, 1.0);
}

// ===============================================================================
// TECHNIQUES
// ===============================================================================

technique AdvancedBloom < ui_tooltip = "High-Quality Next-Gen Bloom"; >
{
    pass Extract { VertexShader = PostProcessVS; PixelShader = PS_Extract; RenderTarget = texDown1; }
    
    pass Down2   { VertexShader = PostProcessVS; PixelShader = PS_Down2; RenderTarget = texDown2; }
    pass Down3   { VertexShader = PostProcessVS; PixelShader = PS_Down3; RenderTarget = texDown3; }
    pass Down4   { VertexShader = PostProcessVS; PixelShader = PS_Down4; RenderTarget = texDown4; }
    pass Down5   { VertexShader = PostProcessVS; PixelShader = PS_Down5; RenderTarget = texDown5; }
    pass Down6   { VertexShader = PostProcessVS; PixelShader = PS_Down6; RenderTarget = texDown6; }

    pass Up5     { VertexShader = PostProcessVS; PixelShader = PS_Up5; RenderTarget = texUp5; }
    pass Up4     { VertexShader = PostProcessVS; PixelShader = PS_Up4; RenderTarget = texUp4; }
    pass Up3     { VertexShader = PostProcessVS; PixelShader = PS_Up3; RenderTarget = texUp3; }
    pass Up2     { VertexShader = PostProcessVS; PixelShader = PS_Up2; RenderTarget = texUp2; }
    pass Up1     { VertexShader = PostProcessVS; PixelShader = PS_Up1; RenderTarget = texUp1; }

    pass Combine { VertexShader = PostProcessVS; PixelShader = PS_Composite; }
}