struct Input {
    float4 p_color : TEXCOORD0;
};

float4 main(Input input) : SV_Target0 {
    return input.p_color;
}