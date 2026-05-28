/*
    Auto-Levels SDR (V7)
    
    New Feature:
    - Selectable Detection Modes: You can now independently choose whether the 
      Shadows and Highlights are detected using Luminance (Overall Perceptual Brightness) 
      or RGB Channels (Strict color boundaries). 
*/

#include "ReShade.fxh"

// ==============================================================================
// 1. DETECTION & CROP (BLACK BARS)
// ==============================================================================

uniform float UI_CropTopBottom <
    ui_type = "slider";
    ui_category = "1. Detection & Crop";
    ui_label = "Ignore Top & Bottom Borders";
    ui_min = 0.0; ui_max = 0.45;
    ui_tooltip = "Crops the top/bottom of the screen from detection.\nSet this so the red debug tint covers the movie's black bars.";
> = 0.12;

uniform float UI_CropLeftRight <
    ui_type = "slider";
    ui_category = "1. Detection & Crop";
    ui_label = "Ignore Left & Right Borders";
    ui_min = 0.0; ui_max = 0.45;
> = 0.00;

// ==============================================================================
// 2. BLACK POINT CONTROL (SHADOWS)
// ==============================================================================

uniform int UI_BlackDetectMode <
    ui_type = "combo";
    ui_category = "2. Black Point Control";
    ui_label = "Shadow Detection Mode";
    ui_items = "RGB Channels (Strict: Leaves deep vibrant colors untouched)\0Luminance (Perceptual: Better at crushing murky scenes)\0";
> = 1;

uniform float UI_BlackStrength <
    ui_type = "slider";
    ui_category = "2. Black Point Control";
    ui_label = "Shadow Fix Strength";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Pulls the darkest pixel in the image down to pure black (0).\nIf the image already has pure black, this slider does absolutely nothing.";
> = 1.0;

uniform float UI_BlackLimit <
    ui_type = "slider";
    ui_category = "2. Black Point Control";
    ui_label = "Black Detection Cap";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Prevents the shader from crushing mostly bright scenes to pure black.\n0.3 = Safe. 1.0 = Aggressive.";
> = 0.3;

uniform float UI_BlackClip <
    ui_type = "slider";
    ui_category = "2. Black Point Control";
    ui_label = "Black Clipping Offset";
    ui_min = 0.0; ui_max = 0.1;
    ui_tooltip = "Forces the shader to ignore the darkest X% of pixels.\nLeave at 0.0 unless you have a specific noisy pixel you want to ignore.";
> = 0.00;

uniform float UI_BlackAdaptSpeed <
    ui_type = "slider";
    ui_category = "2. Black Point Control";
    ui_label = "Adaptation Speed";
    ui_min = 0.1; ui_max = 10.0;
> = 2.0;

// ==============================================================================
// 3. WHITE POINT CONTROL (HIGHLIGHTS)
// ==============================================================================

uniform int UI_WhiteDetectMode <
    ui_type = "combo";
    ui_category = "3. White Point Control";
    ui_label = "Highlight Detection Mode";
    ui_items = "RGB Channels (Strict: Prevents neon/colored lights from blowing out)\0Luminance (Perceptual: Aggressively brightens colors)\0";
> = 0;

uniform float UI_WhiteStrength <
    ui_type = "slider";
    ui_category = "3. White Point Control";
    ui_label = "Highlight Fix Strength";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Pulls the brightest pixel in the image up to pure white (255).\nIf the image already has pure white, this slider does absolutely nothing.";
> = 1.0;

uniform float UI_WhiteLimit <
    ui_type = "slider";
    ui_category = "3. White Point Control";
    ui_label = "White Detection Cap";
    ui_min = 0.0; ui_max = 1.0;
    ui_tooltip = "Prevents the shader from brightening ultra-dark scenes to pure white.\n0.6 = Safe. 0.0 = Aggressively brightens dark rooms.";
> = 0.6;

uniform float UI_WhiteClip <
    ui_type = "slider";
    ui_category = "3. White Point Control";
    ui_label = "White Clipping Offset";
    ui_min = 0.0; ui_max = 0.2;
    ui_tooltip = "Ignores the brightest X% of pixels (Subtitles, HUD, Sparks).\nLeave at 0.0 unless subtitles are ruining the detection.";
> = 0.00;

uniform float UI_WhiteAdaptSpeed <
    ui_type = "slider";
    ui_category = "3. White Point Control";
    ui_label = "Adaptation Speed";
    ui_min = 0.1; ui_max = 10.0;
> = 3.0;

// ==============================================================================
// 4. COLOR PROCESSING & DEBUG
// ==============================================================================

uniform int UI_ColorMode <
    ui_type = "combo";
    ui_category = "4. Color Processing";
    ui_label = "Color Scaling Mode";
    ui_items = "Standard RGB (Photoshop Default)\0Luminance Preserving (No Hue Shift)\0";
> = 1;

uniform bool UI_DebugView <
    ui_category = "5. Debugging";
    ui_label = "Show Debug Info";
    ui_tooltip = "Dims the cropped areas in RED so you can align the black-bar sliders perfectly.";
> = false;

uniform float Frametime < source = "frametime"; >;

// ==============================================================================
// TEXTURES & SAMPLERS
// ==============================================================================

texture texAL_Down1 { Width = 256; Height = 256; Format = RG16F; };
sampler sAL_Down1 { Texture = texAL_Down1; };

texture texAL_Down2 { Width = 16; Height = 16; Format = RG16F; };
sampler sAL_Down2 { Texture = texAL_Down2; };

texture texAL_Down3 { Width = 1; Height = 1; Format = RG16F; };
sampler sAL_Down3 { Texture = texAL_Down3; };

texture texAL_Smooth { Width = 1; Height = 1; Format = RG16F; };
sampler sAL_Smooth { Texture = texAL_Smooth; };

texture texAL_Prev { Width = 1; Height = 1; Format = RG16F; };
sampler sAL_Prev { Texture = texAL_Prev; };

// ==============================================================================
// HELPER FUNCTIONS
// ==============================================================================

float GetLuma(float3 color) { return dot(color, float3(0.2126, 0.7152, 0.0722)); }

// ==============================================================================
// SHADER PASSES
// ==============================================================================

// PASS 1: Screen to 256x256 (Applying Hard UV Mask for Crop)
void PS_Downsample1(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float2 outMinMax : SV_Target)
{
    float2 minmax = float2(1.0, 0.0);
    
    float2 texelSize = 1.0 / 256.0;
    float2 subTexelSize = texelSize / 4.0;
    float2 startUV = texcoord - (texelSize * 0.5) + (subTexelSize * 0.5);

    for(int x = 0; x < 4; x++) {
        for(int y = 0; y < 4; y++) {
            float2 uv = startUV + float2(x, y) * subTexelSize;
            
            // HARD MASK: Skip pixels inside the cropped black-bar area
            if (uv.x >= UI_CropLeftRight && uv.x <= 1.0 - UI_CropLeftRight &&
                uv.y >= UI_CropTopBottom && uv.y <= 1.0 - UI_CropTopBottom) 
            {
                float3 col = saturate(tex2D(ReShade::BackBuffer, uv).rgb);
                
                float luma = GetLuma(col);
                float minC = min(col.r, min(col.g, col.b));
                float maxC = max(col.r, max(col.g, col.b));
                
                // Select detection mode based on UI choice
                float currentShadow = (UI_BlackDetectMode == 0) ? minC : luma;
                float currentHighlight = (UI_WhiteDetectMode == 0) ? maxC : luma;
                
                minmax.x = min(minmax.x, currentShadow);
                minmax.y = max(minmax.y, currentHighlight);
            }
        }
    }
    outMinMax = minmax;
}

// PASS 2: 256x256 to 16x16
void PS_Downsample2(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float2 outMinMax : SV_Target)
{
    float2 minmax = float2(1.0, 0.0);
    float2 stepXY = 1.0 / 16.0;
    float2 startUV = texcoord - (stepXY * 0.5) + (stepXY / 32.0);

    for(int x = 0; x < 16; x++) {
        for(int y = 0; y < 16; y++) {
            float2 smp = tex2D(sAL_Down1, startUV + float2(x, y) * (stepXY / 16.0)).rg;
            minmax.x = min(minmax.x, smp.x);
            minmax.y = max(minmax.y, smp.y);
        }
    }
    outMinMax = minmax;
}

// PASS 3: 16x16 to 1x1
void PS_Downsample3(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float2 outMinMax : SV_Target)
{
    float2 minmax = float2(1.0, 0.0);
    for(int x = 0; x < 16; x++) {
        for(int y = 0; y < 16; y++) {
            float2 smp = tex2D(sAL_Down2, float2(x, y) / 16.0).rg;
            minmax.x = min(minmax.x, smp.x);
            minmax.y = max(minmax.y, smp.y);
        }
    }
    outMinMax = minmax;
}

// PASS 4: Temporal Smoothing
void PS_TemporalAdapt(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float2 outMinMax : SV_Target)
{
    float2 curr = tex2D(sAL_Down3, float2(0.5, 0.5)).rg;
    float2 prev = tex2D(sAL_Prev, float2(0.5, 0.5)).rg;
    
    float timeDelta = Frametime * 0.001; 
    
    float bLerp = 1.0 - exp(-timeDelta * UI_BlackAdaptSpeed);
    float wLerp = 1.0 - exp(-timeDelta * UI_WhiteAdaptSpeed);
    
    outMinMax.x = lerp(prev.x, curr.x, saturate(bLerp));
    outMinMax.y = lerp(prev.y, curr.y, saturate(wLerp));
}

// PASS 5: Apply Auto Levels
void PS_ApplyAutoLevels(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 outColor : SV_Target)
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float2 minmax = tex2D(sAL_Smooth, float2(0.5, 0.5)).rg;
    
    float rawMin = minmax.x;
    float rawMax = minmax.y;
    
    if (rawMin > rawMax) { rawMin = 0.0; rawMax = 1.0; } // Failsafe
    
    // 1. Calculate clipping and Caps. 
    float clipMin = min(rawMin + UI_BlackClip, UI_BlackLimit);
    float clipMax = max(rawMax - UI_WhiteClip, UI_WhiteLimit);
    
    // 2. THE STRENGTH LERP:
    float finalMin = lerp(0.0, clipMin, UI_BlackStrength);
    float finalMax = lerp(1.0, clipMax, UI_WhiteStrength);
    
    finalMax = max(finalMax, finalMin + 0.0001); // Prevent division by zero
    
    float3 finalColor;

    if (UI_ColorMode == 1) {
        // LUMINANCE MODE (Preserves Hue and Saturation perfectly)
        float luma = GetLuma(color);
        float newLuma = saturate((luma - finalMin) / (finalMax - finalMin));
        
        finalColor = color * (newLuma / max(luma, 0.000001));
        
        // Soft-clip overflow to prevent color channels exceeding 1.0
        float maxChan = max(finalColor.r, max(finalColor.g, finalColor.b));
        if (maxChan > 1.0) finalColor /= maxChan;
    } else {
        // STANDARD RGB MODE (Identical to Photoshop Auto-Levels)
        finalColor = saturate((color - finalMin) / (finalMax - finalMin));
    }
    
    // ================= DEBUG VIEW =================
    if (UI_DebugView) {
        // Draw Red Tint over the cropped (ignored) areas
        if (texcoord.x < UI_CropLeftRight || texcoord.x > 1.0 - UI_CropLeftRight ||
            texcoord.y < UI_CropTopBottom || texcoord.y > 1.0 - UI_CropTopBottom) 
        {
            finalColor *= 0.3;     // Dim the ignored area
            finalColor.r += 0.35;  // Add translucent red
        }

        // Draw Luma Bar at the top 
        if (texcoord.y < 0.02) {
            if (texcoord.x < finalMin) finalColor = float3(0.0, 0.0, 1.0); 
            else if (texcoord.x > finalMax) finalColor = float3(1.0, 0.0, 0.0); 
            else finalColor = float3(1.0, 1.0, 1.0); 
        }
    }
    
    outColor = float4(finalColor, 1.0);
}

// PASS 6: Save Current
void PS_CopyPrev(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float2 outMinMax : SV_Target)
{
    outMinMax = tex2D(sAL_Smooth, float2(0.5, 0.5)).rg;
}

technique MV_Gemini_AutoLevelsSDR <
    ui_tooltip = "V7: Added independent detection modes so you can perfectly customize how shadows and highlights are analyzed.";
>
{
    pass P_Down1 { VertexShader = PostProcessVS; PixelShader = PS_Downsample1; RenderTarget = texAL_Down1; }
    pass P_Down2 { VertexShader = PostProcessVS; PixelShader = PS_Downsample2; RenderTarget = texAL_Down2; }
    pass P_Down3 { VertexShader = PostProcessVS; PixelShader = PS_Downsample3; RenderTarget = texAL_Down3; }
    pass P_Smooth{ VertexShader = PostProcessVS; PixelShader = PS_TemporalAdapt; RenderTarget = texAL_Smooth; }
    pass P_Apply { VertexShader = PostProcessVS; PixelShader = PS_ApplyAutoLevels; }
    pass P_Copy  { VertexShader = PostProcessVS; PixelShader = PS_CopyPrev; RenderTarget = texAL_Prev; }
}