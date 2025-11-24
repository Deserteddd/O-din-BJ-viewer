struct Input {
    float2 position : TEXCOORD0;   // 0..1 quad
    float2 uv  : TEXCOORD1;  // 0..1 quad
};

struct Output {
    float4 clip_position : SV_Position;
    float2 uv : TEXCOORD0;
};

cbuffer SpriteCBGlobal : register(b0, space1)
{
    float4 dstRect; // x, y, w, h
    float4 srcRect; // x, y, w, h in pixels
    float4 texSize; // W, H, 1/W, 1/H
    float2 screenSize;
};

Output main(Input input)
{
    Output o;

    float2 center_clip = (dstRect.xy + dstRect.zw * 0.5f) / screenSize * 2.0f - 1.0f;
    float2 half_size_clip = (dstRect.zw / screenSize);

    float2 clip_pos = center_clip + input.position * half_size_clip;
    clip_pos.y = -clip_pos.y;

    o.clip_position = float4(clip_pos, 0.0f, 1.0f);


    // Source UV mapping
    float2 uvPixel = srcRect.xy + input.uv * srcRect.zw;
    o.uv = uvPixel * texSize.zw;
    return o;
}