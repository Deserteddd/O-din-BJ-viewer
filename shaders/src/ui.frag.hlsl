struct Input {
    float2 position : TEXCOORD0;
};
float4 main(Input input) : SV_Target0 {
    return float4(0, 1, 0, 1);
}