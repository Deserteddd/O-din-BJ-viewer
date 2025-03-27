package obj_viewer

import sdl "vendor:sdl3"

Entity :: struct {
    id: u32,
    position: vec3,
    rotation: vec3,
    model: Model,
}

Model :: struct {
    textures: []^sdl.GPUTexture,
    vbo: ^sdl.GPUBuffer,
    material_buffer: ^sdl.GPUBuffer,
    mesh_bounds: []u32,
}
