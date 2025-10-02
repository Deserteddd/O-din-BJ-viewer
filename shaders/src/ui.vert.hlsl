struct Input {
    float2 position : TEXCOORD0;
};

struct Output {
    float2 position : texcoord0;
};

Output main(Input input) {
    Output output;
    output.position = input.position;
    return output;
}