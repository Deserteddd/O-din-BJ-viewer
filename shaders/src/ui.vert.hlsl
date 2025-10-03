struct Input {
    float2 position : TEXCOORD0;
};

struct Output {
    float4 position : SV_Position;
};

Output main(Input input) {
    Output output;
    output.position = float4(input.position, 0, 1);
    return output;
}