struct Input {
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float3 tangent : TEXCOORD3;
};

struct Output {
    float4 clipPosition : SV_Position;
    float3 position : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float2 uv : TEXCOORD2;
    float3 tangent : TEXCOORD3;
};

cbuffer UBO : register(b0, space1) {
    float4x4 vp;
};

cbuffer PROJ : register(b1, space1) {
    float4x4 m;
};

Output main(Input input) {
    float4 worldPosition = mul(m, float4(input.position, 1));

    Output output;
    output.clipPosition = mul(vp, worldPosition);
    output.uv = input.uv;
    output.position = worldPosition.xyz;
    output.normal = normalize(mul(m, float4(input.normal, 0)).xyz);
    output.tangent = input.tangent;
    return output;
}