package obj_viewer

import "core:fmt"
import sdl "vendor:sdl3"

/*
Constant entity id's:
    0: Player
*/
Entity :: struct {
    id: u32,
    model: Model,
}

Model :: struct {
    textures: []^sdl.GPUTexture,
    vbo: ^sdl.GPUBuffer,
    material_buffer: ^sdl.GPUBuffer,
    mesh_bounds: []u32,
}

PhysicsFlag :: enum {
    STATIC,     // Isn't affected by gravity
    DYNAMIC,    // Is affected by gravity
    COLLIDER,   // Duh?
    AIRBORNE
}

PhysicsFlags :: distinct bit_set[PhysicsFlag]

Physics :: struct {
    position: vec3,
    speed: vec3,
    rotation: vec3,
    flags: PhysicsFlags,
}

print_entities :: proc(entities: [dynamic]Entity, physics: [dynamic]Physics) {
    for e, i in entities {
        assert(len(entities) == len(physics))
        fmt.printfln("Entity {} - has_model: {}", e.id, e.model.vbo != nil)
        fmt.println(physics[i].flags)
        fmt.println()
    }
}

