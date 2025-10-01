struct Input {
    float3 position : TEXCOORD0;
};

struct Output {
    float4 clip_position : sv_position;
    float4 p_color : TEXCOORD0;
};

cbuffer UBO : register(b0, space1) {
    float4x4 vp;
};

cbuffer PROJ : register(b1, space1) {
    float4x4 m;
};

Output main(Input input) {
    Output output;
    float4 worldPosition = mul(m, float4(input.position, 1));
    output.clip_position = mul(vp, worldPosition);
    output.p_color = float4(1, 0, 0, 1);
    return output;
}