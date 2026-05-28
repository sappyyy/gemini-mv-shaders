/*
    Blurred Borders for SDR Movies (v1.5)
    Author: Assistant
    Description: Masks letterbox (2.35:1) or pillarbox (4:3) black bars 
    with a high-quality blurred and stretched copy of the active video frame.
    Added Subtitle/OSD Protection blending modes.
*/

#include "ReShade.fxh"

namespace BlurredBorders
{
    // ==========================================
    // UI PARAMETERS
    // ==========================================

    uniform float SourceAspectRatio <
        ui_type = "slider";
        ui_category = "Dimensions";
        ui_label = "Source Video Aspect Ratio";
        ui_tooltip = "Set to the original ratio of the film.\nTypical values:\n4:3 Classic = 1.33\n16:9 Standard = 1.77\nMovie Widescreen = 2.35 or 2.40";
        ui_min = 1.0; ui_max = 3.0; ui_step = 0.01;
    > = 2.35;

    uniform int BgFillMode <
        ui_type = "combo";
        ui_category = "Dimensions";
        ui_label = "Background Fill Mode";
        ui_items = "Uniform Zoom (Preserve Aspect Ratio)\0Stretch Whole Frame to Fill\0Mirror Video Edges (Seamless Bleed)\0Edge Extrusion (SVP Ambilight Lights)\0";
    > = 3;

    uniform int EdgeExtrusionPixels <
        ui_type = "slider";
        ui_category = "Dimensions";
        ui_label = "Extrusion Stretch Band (Px)";
        ui_tooltip = "(For Fill Mode 3) How many outer pixels of the video are stretched into the void.\n0 = Pure 1-pixel streak (Harsh SVP).\n15+ = Smoother blended light band.";
        ui_min = 0; ui_max = 200; ui_step = 1;
    > = 5;

    uniform int EdgeCropPixels <
        ui_type = "slider";
        ui_category = "Dimensions";
        ui_label = "Edge Crop / Safe Zone (Px)";
        ui_tooltip = "Steps slightly inwards from the video edge to start sampling.\nPrevents blurry black borders if your movie file has encoded dirty edges.";
        ui_min = 0; ui_max = 50; ui_step = 1;
    > = 2;

    uniform float BorderSoftness <
        ui_type = "slider";
        ui_category = "Dimensions";
        ui_label = "Border Softness";
        ui_tooltip = "Feathers the edge between the sharp video and the blurred background.";
        ui_min = 0.0; ui_max = 0.1; ui_step = 0.001;
    > = 0.005;

    uniform int BlurDirection <
        ui_type = "combo";
        ui_category = "Blur Quality";
        ui_label = "Blur Direction";
        ui_tooltip = "Auto matches the SVP method: Horizontal streaks for 4:3, Vertical streaks for 2.35:1.";
        ui_items = "Both (Standard 2D Blur)\0Horizontal Only (Anamorphic Streak)\0Vertical Only\0Auto (SVP Style: H for 4:3, V for 2.35)\0";
    > = 3;

    uniform float BlurRadius <
        ui_type = "slider";
        ui_category = "Blur Quality";
        ui_label = "Blur Radius";
        ui_min = 1.0; ui_max = 10.0; ui_step = 0.1;
    > = 6.0;

    uniform int BgFlipMode <
        ui_type = "combo";
        ui_category = "Background Adjustments";
        ui_label = "Flip / Invert Background";
        ui_tooltip = "Flips the entire blurred background image.";
        ui_items = "None\0Flip Horizontally\0Flip Vertically\0Flip Both\0";
    > = 0;

    uniform float BgBrightness <
        ui_type = "slider";
        ui_category = "Background Adjustments";
        ui_label = "Background Brightness";
        ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
    > = 0.8;

    uniform float BgSaturation <
        ui_type = "slider";
        ui_category = "Background Adjustments";
        ui_label = "Background Saturation";
        ui_min = 0.0; ui_max = 3.0; ui_step = 0.05;
    > = 1.3;

    // --- NEW: Subtitle & OSD Protection ---
    uniform int SubtitleBlendMode <
        ui_type = "combo";
        ui_category = "Subtitle & OSD Protection";
        ui_label = "Border Blend Mode";
        ui_tooltip = "Determines how the original screen (Subtitles) blends with the blurred bars.\n'Lighten' or 'Screen' is usually best for white/yellow subtitles.";
        ui_items = "Overwrite (Cover Subtitles)\0Lighten (Keep Brightest Pixels)\0Screen (Smooth Glow Blend)\0Addition (Adds brightness)\0Luma Key (Threshold)\0";
    > = 1;

    uniform float LumaThreshold <
        ui_type = "slider";
        ui_category = "Subtitle & OSD Protection";
        ui_label = "Luma Key Threshold";
        ui_tooltip = "Only used if Blend Mode is set to 'Luma Key'. Determines how bright a subtitle pixel must be to show up.";
        ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    > = 0.1;

    // ==========================================
    // TEXTURES & SAMPLERS
    // ==========================================

    texture TexBlurH { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA8; };
    sampler SamplerBlurH { Texture = TexBlurH; AddressU = CLAMP; AddressV = CLAMP; };

    texture TexBlurV { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA8; };
    sampler SamplerBlurV { Texture = TexBlurV; AddressU = CLAMP; AddressV = CLAMP; };

    // ==========================================
    // HELPER FUNCTIONS
    // ==========================================

    float2 GetActiveVideoScale()
    {
        float displayAR = (float)BUFFER_WIDTH / (float)BUFFER_HEIGHT;
        float sourceAR = SourceAspectRatio;
        float2 scale = float2(1.0, 1.0);

        if (sourceAR > displayAR) {
            scale.y = displayAR / sourceAR; 
        } else {
            scale.x = sourceAR / displayAR; 
        }
        return scale;
    }

    float2 GetSourceCoord(float2 uv)
    {
        float2 activeScale = GetActiveVideoScale();
        float2 coord = uv;

        float2 trueMin = (1.0 - activeScale) * 0.5;
        float2 trueMax = 1.0 - trueMin;
        
        float2 crop = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * EdgeCropPixels;
        float2 minBound = trueMin + crop;
        float2 maxBound = trueMax - crop;

        if (BgFillMode == 0) // Uniform Zoom
        {
            coord -= 0.5;
            float displayAR = (float)BUFFER_WIDTH / (float)BUFFER_HEIGHT;
            float sourceAR = SourceAspectRatio;
            
            if (sourceAR > displayAR)
                coord *= (displayAR / sourceAR);
            else
                coord *= (sourceAR / displayAR);
            coord += 0.5;
        }
        else if (BgFillMode == 1) // Stretch Whole Frame
        {
            coord = lerp(minBound, maxBound, coord);
        }
        else if (BgFillMode == 2) // Mirror Video Edges
        {
            coord = minBound + abs(coord - minBound);
            coord = maxBound - abs(coord - maxBound);
        }
        else if (BgFillMode == 3) // Edge Extrusion
        {
            float2 depth = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * EdgeExtrusionPixels;
            
            if (trueMin.x > 0.001) 
            {
                if (coord.x < trueMin.x) coord.x = lerp(minBound.x + depth.x, minBound.x, coord.x / trueMin.x);
                else if (coord.x > trueMax.x) coord.x = lerp(maxBound.x, maxBound.x - depth.x, (coord.x - trueMax.x) / (1.0 - trueMax.x));
                else coord.x = clamp(coord.x, minBound.x, maxBound.x);
            } else { coord.x = clamp(coord.x, minBound.x, maxBound.x); }
            
            if (trueMin.y > 0.001) 
            {
                if (coord.y < trueMin.y) coord.y = lerp(minBound.y + depth.y, minBound.y, coord.y / trueMin.y);
                else if (coord.y > trueMax.y) coord.y = lerp(maxBound.y, maxBound.y - depth.y, (coord.y - trueMax.y) / (1.0 - trueMax.y));
                else coord.y = clamp(coord.y, minBound.y, maxBound.y);
            } else { coord.y = clamp(coord.y, minBound.y, maxBound.y); }
        }

        if (BgFlipMode == 1 || BgFlipMode == 3) coord.x = 1.0 - coord.x;
        if (BgFlipMode == 2 || BgFlipMode == 3) coord.y = 1.0 - coord.y;

        return coord;
    }

    // ==========================================
    // SHADER PASSES
    // ==========================================

    #define BLUR_SAMPLES 12

    void PS_BlurH(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD, out float4 color : SV_Target)
    {
        bool isLetterbox = SourceAspectRatio > ((float)BUFFER_WIDTH / (float)BUFFER_HEIGHT);
        if (BlurDirection == 2 || (BlurDirection == 3 && isLetterbox)) 
        {
            float2 sourceUV = GetSourceCoord(texcoord);
            color = float4(tex2D(ReShade::BackBuffer, sourceUV).rgb, 1.0);
            return;
        }

        float2 pixelSize = float2(BUFFER_RCP_WIDTH * 2.0, BUFFER_RCP_HEIGHT * 2.0) * BlurRadius;
        float3 result = 0.0;
        float totalWeight = 0.0;
        float sigma = BlurRadius * 2.0 + 0.001;

        for (int i = -BLUR_SAMPLES; i <= BLUR_SAMPLES; i++)
        {
            float weight = exp(-(i * i) / (2.0 * sigma * sigma));
            float2 tapUV = clamp(texcoord + float2(i * pixelSize.x, 0.0), 0.0, 1.0);
            float2 sourceUV = GetSourceCoord(tapUV);
            result += tex2D(ReShade::BackBuffer, sourceUV).rgb * weight;
            totalWeight += weight;
        }
        color = float4(result / totalWeight, 1.0);
    }

    void PS_BlurV(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD, out float4 color : SV_Target)
    {
        bool isLetterbox = SourceAspectRatio > ((float)BUFFER_WIDTH / (float)BUFFER_HEIGHT);
        if (BlurDirection == 1 || (BlurDirection == 3 && !isLetterbox)) 
        {
            color = float4(tex2D(SamplerBlurH, texcoord).rgb, 1.0);
            return;
        }

        float2 pixelSize = float2(BUFFER_RCP_WIDTH * 2.0, BUFFER_RCP_HEIGHT * 2.0) * BlurRadius;
        float3 result = 0.0;
        float totalWeight = 0.0;
        float sigma = BlurRadius * 2.0 + 0.001;

        for (int i = -BLUR_SAMPLES; i <= BLUR_SAMPLES; i++)
        {
            float weight = exp(-(i * i) / (2.0 * sigma * sigma));
            float2 tapUV = clamp(texcoord + float2(0.0, i * pixelSize.y), 0.0, 1.0);
            result += tex2D(SamplerBlurH, tapUV).rgb * weight;
            totalWeight += weight;
        }
        color = float4(result / totalWeight, 1.0);
    }

    void PS_Composite(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD, out float4 color : SV_Target)
    {
        float3 original = tex2D(ReShade::BackBuffer, texcoord).rgb;
        float3 background = tex2D(SamplerBlurV, texcoord).rgb;

        background *= BgBrightness;

        float luma = dot(background, float3(0.299, 0.587, 0.114));
        background = lerp(luma.xxx, background, BgSaturation);

        float2 activeScale = GetActiveVideoScale();
        float2 minBound = (1.0 - activeScale) * 0.5;
        float2 maxBound = 1.0 - minBound;

        float maskX = smoothstep(minBound.x - BorderSoftness, minBound.x, texcoord.x) 
                    * (1.0 - smoothstep(maxBound.x, maxBound.x + BorderSoftness, texcoord.x));
        
        float maskY = smoothstep(minBound.y - BorderSoftness, minBound.y, texcoord.y) 
                    * (1.0 - smoothstep(maxBound.y, maxBound.y + BorderSoftness, texcoord.y));

        // mask = 1.0 (inside movie frame), mask = 0.0 (inside black bars)
        float mask = maskX * maskY;

        // --- SUBTITLE & OSD BLENDING FOR BLACK BARS ---
        float3 borderArea;
        
        if (SubtitleBlendMode == 0) // Overwrite
        {
            borderArea = background;
        }
        else if (SubtitleBlendMode == 1) // Lighten (Best for standard white/yellow subtitles)
        {
            borderArea = max(background, original);
        }
        else if (SubtitleBlendMode == 2) // Screen
        {
            borderArea = 1.0 - (1.0 - background) * (1.0 - original);
        }
        else if (SubtitleBlendMode == 3) // Addition
        {
            borderArea = saturate(background + original);
        }
        else // Luma Key
        {
            float origLuma = dot(original, float3(0.299, 0.587, 0.114));
            // Create a soft mask for anti-aliased font edges
            float subMask = smoothstep(max(0.0, LumaThreshold - 0.05), min(1.0, LumaThreshold + 0.05), origLuma);
            borderArea = lerp(background, original, subMask);
        }

        // Final output: Keeps the movie frame exactly as-is, and applies the chosen blend to the black bars
        color = float4(lerp(borderArea, original, mask), 1.0);
    }

    // ==========================================
    // TECHNIQUES
    // ==========================================

    technique BlurredBorders3 < ui_tooltip = "Replaces black borders with an ambilight-style blurred background."; >
    {
        pass PassBlurH
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_BlurH;
            RenderTarget = TexBlurH;
        }
        pass PassBlurV
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_BlurV;
            RenderTarget = TexBlurV;
        }
        pass PassComposite
        {
            VertexShader = PostProcessVS;
            PixelShader = PS_Composite;
        }
    }
}