struct Input {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    uint material : TEXCOORD3;
};

struct Output {
    float4 glPosition : SV_Position;
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    nointerpolation uint material : TEXCOORD3;
};

cbuffer UBO : register(b0, space1) {
    float4x4 modelview;
    float4 position_offset;
};

cbuffer PROJ : register(b1, space1) {
    float4x4 projection_matrix;
};

Output main(Input input) {
    Output output;
    float4 world_pos = float4(input.position + position_offset.xyz, 1.0);
    float4x4 mvp = mul(projection_matrix, modelview);
    output.glPosition = mul(mvp, float4(input.position, 1.0));
    output.position = world_pos.xyz;
    output.normal = input.normal;
    output.uv = input.uv;
    output.material = input.material;
    return output;
}