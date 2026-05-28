/* ==========================================================================
   ADVANCED SHADOWS / HIGHLIGHTS REPLICATOR (Photoshop Style)
   For ReShade - V3.2 (Decoupled Contrast & Saturation)
   
   Features:
   - High-fidelity Perceptual Oklab Color Space
   - Edge-Aware Bilateral Spatial Filtering (Vogel Spiral)
   - Exponential Screen/Multiply Curves (Preserves Deep Blacks & Contrast)
   - Decoupled Saturation Logic (Maintains vibrant color during contrast punch)
   ==========================================================================
*/

#include "ReShade.fxh"

// ==========================================================================
// CONTROLLABLE PARAMETERS
// ==========================================================================

uniform float SHADOW_AMOUNT <
    ui_category = "1. Shadows";
    ui_type = "slider";
    ui_label = "Shadow Lift Amount";
    ui_tooltip = "How much to lift the shadows.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.50;

uniform float SHADOW_PUNCH <
    ui_category = "1. Shadows";
    ui_type = "slider";
    ui_label = "Shadow Punch (Contrast)";
    ui_tooltip = "Adds density and contrast back into the lifted shadows to prevent milkiness.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.30;

uniform float SHADOW_TONE_WIDTH <
    ui_category = "1. Shadows";
    ui_type = "slider";
    ui_label = "Shadow Tone Width";
    ui_tooltip = "Range of tones considered 'shadows'.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.45;

uniform float SHADOW_RADIUS <
    ui_category = "1. Shadows";
    ui_type = "slider";
    ui_label = "Shadow Radius";
    ui_tooltip = "Spatial radius of the shadow detection.";
    ui_min = 0.0; ui_max = 0.2;
> = 0.05;

uniform float HIGHLIGHT_AMOUNT <
    ui_category = "2. Highlights";
    ui_type = "slider";
    ui_label = "Highlight Recovery Amount";
    ui_tooltip = "How much to recover the highlights.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.40;

uniform float HIGHLIGHT_PUNCH <
    ui_category = "2. Highlights";
    ui_type = "slider";
    ui_label = "Highlight Punch (Contrast)";
    ui_tooltip = "Adds micro-contrast to recovered highlights to prevent flat gray skies.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.20;

uniform float HIGHLIGHT_TONE_WIDTH <
    ui_category = "2. Highlights";
    ui_type = "slider";
    ui_label = "Highlight Tone Width";
    ui_tooltip = "Range of tones considered 'highlights'.";
    ui_min = 0.0; ui_max = 1.0;
> = 0.55;

uniform float HIGHLIGHT_RADIUS <
    ui_category = "2. Highlights";
    ui_type = "slider";
    ui_label = "Highlight Radius";
    ui_tooltip = "Spatial radius of the highlight detection.";
    ui_min = 0.0; ui_max = 0.2;
> = 0.05;

uniform float COLOR_CORRECTION <
    ui_category = "3. Adjustments";
    ui_type = "slider";
    ui_label = "Color Preservation (Saturation)";
    ui_tooltip = "1.0 maintains vibrant perceived saturation when lifting and punching shadows.";
    ui_min = 0.0; ui_max = 2.0;
> = 1.00;

uniform float MIDTONE_CONTRAST <
    ui_category = "3. Adjustments";
    ui_type = "slider";
    ui_label = "Midtone Contrast";
    ui_tooltip = "Applies a global S-Curve to the midtones.";
    ui_min = -1.0; ui_max = 1.0;
> = 0.15;

uniform int BLUR_SAMPLES <
    ui_category = "4. Engine & Quality";
    ui_type = "slider";
    ui_label = "Blur Samples";
    ui_tooltip = "Higher = better quality mask, slower performance.";
    ui_min = 16; ui_max = 128;
> = 32;

uniform float EDGE_PRESERVATION <
    ui_category = "4. Engine & Quality";
    ui_type = "slider";
    ui_label = "Edge Preservation";
    ui_tooltip = "Lower = tighter edge stopping (prevents glowing halos).";
    ui_min = 0.01; ui_max = 0.5;
> = 0.15;

uniform int DEBUG_MODE <
    ui_category = "5. Debug & Overlay";
    ui_type = "combo";
    ui_label = "View Mode";
    ui_items = "Final Output\0Split Screen (Original vs Adjusted)\0Blurred Luminance Map\0Shadow Mask\0Highlight Mask\0";
> = 0;


// ==========================================================================
// COLOR SPACE UTILITIES (sRGB <-> Linear <-> Oklab)
// ==========================================================================

float3 sRGB_to_Linear(float3 c) {
    float3 linear1 = c / 12.92;
    float3 linear2 = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
    return lerp(linear1, linear2, step(0.04045, c));
}

float3 Linear_to_sRGB(float3 c) {
    float3 srgb1 = c * 12.92;
    float3 srgb2 = 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055;
    return lerp(srgb1, srgb2, step(0.0031308, c));
}

float3 Linear_to_Oklab(float3 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    
    l = sign(l) * pow(abs(l), 1.0/3.0); 
    m = sign(m) * pow(abs(m), 1.0/3.0); 
    s = sign(s) * pow(abs(s), 1.0/3.0);
    
    return float3(
        0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
        1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
        0.0259040371*l + 0.7827717662*m - 0.8086757660*s
    );
}

float3 Oklab_to_Linear(float3 c) {
    float l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
    float m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
    float s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
    
    l_ = l_*l_*l_; 
    m_ = m_*m_*m_; 
    s_ = s_*s_*s_;
    
    return float3(
        4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
        -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
        -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    );
}

// ==========================================================================
// TEXTURES & SAMPLERS
// ==========================================================================

texture2D texLuma { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler2D sLuma   { Texture = texLuma; };

// ==========================================================================
// PASS 1: PRE-COMPUTE OKLAB LUMINANCE
// ==========================================================================

float PS_PrecomputeLuma(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target {
    float3 origRGB = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 origLinear = sRGB_to_Linear(origRGB);
    return Linear_to_Oklab(origLinear).x;
}

// ==========================================================================
// PASS 2: MAIN PROCESSING
// ==========================================================================

float3 PS_ShadowsHighlights(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target {
    
    float3 origRGB = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 origLinear = sRGB_to_Linear(origRGB);
    float3 oklab = Linear_to_Oklab(origLinear);
    
    float L = oklab.x;
    float2 chroma = oklab.yz;
    
    // 1. Perform Fast Bilateral Edge-Aware Blur
    float avgRadius = (SHADOW_RADIUS + HIGHLIGHT_RADIUS) * 0.5;
    float goldenAngle = 2.39996323f;
    float aspect = (float)BUFFER_WIDTH / (float)BUFFER_HEIGHT;
    
    float sumWeights = 0.0;
    float sumLuma = 0.0;
    
    for(int i = 0; i < BLUR_SAMPLES; i++) {
        float r = sqrt((float)i + 0.5) / sqrt((float)BLUR_SAMPLES);
        float theta = (float)i * goldenAngle;
        
        float2 offset = float2(cos(theta), sin(theta)) * r * avgRadius;
        offset.y *= aspect; 
        
        float sampleLuma = tex2Dlod(sLuma, float4(texcoord + offset, 0, 0)).x;
        
        float spatialWeight = 1.0 - r;
        float lumaDiff = abs(sampleLuma - L);
        float rangeWeight = exp(-(lumaDiff * lumaDiff) / (2.0 * EDGE_PRESERVATION * EDGE_PRESERVATION));
        
        float weight = spatialWeight * rangeWeight;
        sumLuma += sampleLuma * weight;
        sumWeights += weight;
    }
    
    float blurredL = sumLuma / max(sumWeights, 0.0001);
    
    // 2. Generate Masks
    float shadowMask = 1.0 - smoothstep(0.0, SHADOW_TONE_WIDTH + 0.001, blurredL);
    float highlightMask = smoothstep(1.0 - HIGHLIGHT_TONE_WIDTH - 0.001, 1.0, blurredL);
    
    // 3. Tonal Adjustments 
    // We separate 'exposureL' (pure light recovery) from 'adjustedL' (includes contrast punch).
    float exposureL = L;
    float adjustedL = L;
    
    // --- SHADOWS ---
    if (shadowMask > 0.0) {
        float shadowPower = 1.0 + (SHADOW_AMOUNT * 2.5);
        float pureLift = 1.0 - pow(max(1.0 - L, 0.0001), shadowPower);
        
        // Track the raw exposure lift for color correction
        exposureL = lerp(exposureL, pureLift, shadowMask);
        
        // Track the final punched contrast for the actual output
        float punchToe = pureLift * pureLift * (3.0 - 2.0 * pureLift);
        float finalLift = lerp(pureLift, punchToe, SHADOW_PUNCH);
        
        adjustedL = lerp(adjustedL, finalLift, shadowMask);
    }
    
    // --- HIGHLIGHTS ---
    if (highlightMask > 0.0) {
        float highlightPower = 1.0 + (HIGHLIGHT_AMOUNT * 2.0);
        
        float pureCompress = pow(max(exposureL, 0.0001), highlightPower);
        exposureL = lerp(exposureL, pureCompress, highlightMask);
        
        float adjustedCompress = pow(max(adjustedL, 0.0001), highlightPower);
        float punchShoulder = adjustedCompress * adjustedCompress * (3.0 - 2.0 * adjustedCompress);
        float finalCompress = lerp(adjustedCompress, punchShoulder, HIGHLIGHT_PUNCH);
        
        adjustedL = lerp(adjustedL, finalCompress, highlightMask);
    }
    
    // 4. Global Midtone Contrast (S-Curve)
    float contrastL = lerp(adjustedL, smoothstep(0.0, 1.0, adjustedL), MIDTONE_CONTRAST);
    adjustedL = lerp(adjustedL, contrastL, 1.0 - max(shadowMask, highlightMask));
    
    // 5. COLOR CORRECTION (DECOUPLED LOGIC)
    // By calculating saturation based ONLY on 'exposureL', we ensure that 
    // when 'adjustedL' is darkened by Shadow Punch or Midtone Contrast, 
    // the color remains deeply saturated, creating a rich, filmic contrast.
    if (exposureL > L) {
        float lumaRatio = exposureL / max(L, 0.001); 
        float blackProtection = smoothstep(0.0, 0.05, L);
        
        float satBoost = lerp(1.0, lumaRatio, COLOR_CORRECTION * blackProtection);
        chroma *= satBoost;
    }
    
    // 6. Reconstruct Final Image (Using the Punched Lightness + The Boosted Chroma)
    float3 finalOklab = float3(adjustedL, chroma);
    float3 finalLinear = saturate(Oklab_to_Linear(finalOklab));
    float3 finalRGB = Linear_to_sRGB(finalLinear);
    
    // ==========================================================================
    // DEBUG & OVERLAY MODES
    // ==========================================================================
    
    float3 outputRGB = finalRGB;
    
    if (DEBUG_MODE == 1) { // Split Screen
        float split = step(0.5, texcoord.x);
        outputRGB = lerp(origRGB, finalRGB, split);
        if (abs(texcoord.x - 0.5) < 0.0015) outputRGB = float3(1.0, 1.0, 1.0);
    } 
    else if (DEBUG_MODE == 2) { // Blurred Luma
        outputRGB = blurredL.xxx;
    }
    else if (DEBUG_MODE == 3) { // Shadow Mask 
        outputRGB = lerp(origRGB, float3(1.0, 0.0, 0.0), shadowMask * 0.8);
    }
    else if (DEBUG_MODE == 4) { // Highlight Mask
        outputRGB = lerp(origRGB, float3(0.0, 0.5, 1.0), highlightMask * 0.8);
    }

    return outputRGB;
}

// ==========================================================================
// TECHNIQUES
// ==========================================================================

technique MV_Gemini_PS_ShadowsHighlights <
    ui_tooltip = "Advanced Shadows/Highlights tool simulating professional photo editors.\n"
                 "Utilizes Bilateral Edge-Aware Filtering and Oklab Perceptual Color Space.";
>
{
    pass PrecomputeLuma {
        VertexShader = PostProcessVS;
        PixelShader  = PS_PrecomputeLuma;
        RenderTarget = texLuma;
    }
    pass MainPass {
        VertexShader = PostProcessVS;
        PixelShader  = PS_ShadowsHighlights;
    }
}