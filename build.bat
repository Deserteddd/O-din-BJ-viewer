shadercross ./shaders/shader.vert.hlsl -o ./shaders/spv/shader.vert.spv
if %errorlevel% neq 0 exit /b 1
shadercross ./shaders/shader.frag.hlsl -o ./shaders/spv/shader.frag.spv
if %errorlevel% neq 0 exit /b 1

odin run ./src

