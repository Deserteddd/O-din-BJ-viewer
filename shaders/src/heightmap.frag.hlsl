TextureCube<float4> cubeMap : register(t0, space2);
SamplerState cubeSmp : register(s0, space2);

struct Input {
    float3 worldPosition: TEXCOORD0;
    float3 normal : TEXCOORD1;
    float4 color : TEXCOORD2;
};

float4 main(Input input) : SV_Target0 {
    
    float3 envColor = cubeMap.Sample(cubeSmp, input.normal).rgb;
    float3 color = envColor; //+ max(input.worldPosition.y, 0) * 0.05;
    return float4(color, 0.4);
}