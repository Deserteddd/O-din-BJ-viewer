struct Input {
    float2 position : TEXCOORD0;
};

struct Output {
    float4 clip_position : SV_Position;
    float2 position : TEXCOORD0;
};

Output main(Input input) {
    Output output;
    output.clip_position = float4(input.position, 0.0f, 1.0f);
    output.position = input.position;

    return output;
}