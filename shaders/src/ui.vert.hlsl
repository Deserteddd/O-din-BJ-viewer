struct Input {
    float2 position : TEXCOORD0; // in GL clip space (-1..1)
    float2 uv : TEXCOORD1;
};

struct Output {
    float4 clip_position : SV_Position;
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

cbuffer UBO : register(b0, space1) {
    float4 xywh;         // x, y, width, height in pixels
    float2 screen_size;  // screen width, height in pixels
};

Output main(Input input) {
    Output output;

    // Compute center and half-size in clip space
    float2 center_clip = (xywh.xy + xywh.zw * 0.5f) / screen_size * 2.0f - 1.0f;
    float2 half_size_clip = (xywh.zw / screen_size);

    // Apply transform
    float2 clip_pos = center_clip + input.position * half_size_clip;

    // Flip Y if needed (depends on coordinate system)
    clip_pos.y = -clip_pos.y;

    output.clip_position = float4(clip_pos, 0.0f, 1.0f);
    output.position = input.position;
    output.uv = input.uv;

    return output;
}