struct Input {
    float3 worldPosition: TEXCOORD0;
    float4 color : TEXCOORD1;
};

float4 main(Input input) : SV_Target0 {
    
    float3 color = input.color.rgb + max(input.worldPosition.y, 0) * 0.05;
    return float4(color, 1);
}