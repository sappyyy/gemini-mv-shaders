/*
    Self-Blend Shader for ReShade
    Blends the original image with a copy (or inverted copy) of itself
    using standard Photoshop blend modes.
*/

#include "ReShade.fxh"

// ========================================== //
//                  UI CONTROLS               //
// ========================================== //

uniform bool bInvertCopy <
    ui_label = "Invert Copy Layer";
    ui_tooltip = "If enabled, the shader blends the original image with an INVERTED version of itself.";
> = false;

uniform int iBlendMode <
    ui_type = "combo";
    ui_label = "Blend Mode";
    ui_tooltip = "Select the Photoshop-style blend mode.";
    ui_items = "Normal\0Multiply\0Screen\0Overlay\0Soft Light\0Hard Light\0Color Dodge\0Color Burn\0Linear Dodge (Add)\0Linear Burn\0Difference\0Exclusion\0";
> = 3; // Defaults to Overlay

uniform float fOpacity <
    ui_type = "slider";
    ui_label = "Opacity";
    ui_tooltip = "Adjust the strength of the blended layer.";
    ui_min = 0.0; 
    ui_max = 1.0;
> = 1.0;

// ========================================== //
//                 PIXEL SHADER               //
// ========================================== //

float4 PS_SelfBlend(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    // Sample the original image (Base Layer)
    float3 baseColor = tex2D(ReShade::BackBuffer, texcoord).rgb;
    
    // Create the copy (Blend Layer)
    float3 blendColor = baseColor;
    
    // Invert the copy if the user checked the box
    if (bInvertCopy)
    {
        blendColor = 1.0 - blendColor;
    }

    float3 result = baseColor;

    // Apply the selected Blend Mode
    switch (iBlendMode)
    {
        case 0: // Normal
            result = blendColor;
            break;
            
        case 1: // Multiply
            result = baseColor * blendColor;
            break;
            
        case 2: // Screen
            result = 1.0 - (1.0 - baseColor) * (1.0 - blendColor);
            break;
            
        case 3: // Overlay
            // If base < 0.5, multiply. Otherwise, screen.
            result = lerp(2.0 * baseColor * blendColor, 
                          1.0 - 2.0 * (1.0 - baseColor) * (1.0 - blendColor), 
                          step(0.5, baseColor));
            break;
            
        case 4: // Soft Light (Pegtop approximation, matching Photoshop)
            result = lerp((2.0 * blendColor - 1.0) * (baseColor - baseColor * baseColor) + baseColor, 
                          (2.0 * blendColor - 1.0) * (sqrt(baseColor) - baseColor) + baseColor, 
                          step(0.5, blendColor));
            break;
            
        case 5: // Hard Light (Overlay with base/blend swapped)
            result = lerp(2.0 * baseColor * blendColor, 
                          1.0 - 2.0 * (1.0 - baseColor) * (1.0 - blendColor), 
                          step(0.5, blendColor));
            break;
            
        case 6: // Color Dodge
            // max() is used to prevent dividing by zero
            result = saturate(baseColor / max(1.0 - blendColor, 0.000001));
            break;
            
        case 7: // Color Burn
            result = 1.0 - saturate((1.0 - baseColor) / max(blendColor, 0.000001));
            break;
            
        case 8: // Linear Dodge (Add)
            result = saturate(baseColor + blendColor);
            break;
            
        case 9: // Linear Burn
            result = saturate(baseColor + blendColor - 1.0);
            break;
            
        case 10: // Difference
            result = abs(baseColor - blendColor);
            break;
            
        case 11: // Exclusion
            result = baseColor + blendColor - 2.0 * baseColor * blendColor;
            break;
    }

    // Apply Opacity slider
    result = lerp(baseColor, result, fOpacity);

    return float4(result, 1.0);
}

// ========================================== //
//                  TECHNIQUE                 //
// ========================================== //

technique MV_Gemini_Overlay1
<
    ui_tooltip = "Overlays the screen with a copy (or inverted copy) of itself using Photoshop blend modes.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_SelfBlend;
    }
}