struct Input {
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

Texture2D<float4> ts0 : register(t0, space2);

SamplerState smp0 : register(s0, space2);

float4 main(Input input) : SV_Target0 {
    return ts0.Sample(smp0, input.uv);
}