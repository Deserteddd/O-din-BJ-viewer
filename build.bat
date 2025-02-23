glslc ./shaders/triangle.glsl.vert -o ./shaders/spv/triangle.vert.spv
if %errorlevel% neq 0 exit /b 1
glslc ./shaders/triangle.glsl.frag -o ./shaders/spv/triangle.frag.spv
if %errorlevel% neq 0 exit /b 1

odin run ./src

