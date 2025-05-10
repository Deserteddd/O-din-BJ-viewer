package obj_viewer

import "core:fmt"
import "core:mem"
import "core:math/linalg"
import sdl "vendor:sdl3"

Entity :: struct {
    id: int,
    model: ^Model,
    position: vec3,
    aabb: AABB
}

EntitySOA :: #soa [dynamic]Entity

Model :: struct {
    textures:        []^sdl.GPUTexture,
    vbo:             ^sdl.GPUBuffer,
    material_buffer: ^sdl.GPUBuffer,
    num_vertices:    u32,
    bbox:            AABB
}

Player :: struct {
    position: vec3,
    speed: vec3,
    rotation: vec3,
    bbox: AABB,
    airborne: bool
}

create_entity :: proc(state: ^AppState, model: u32) -> int {
    entity: Entity
    entity.id = len(state.entities)
    entity.model = &state.models[model]
    entity.aabb = entity.model.bbox
    append_soa(&state.entities, entity)
    return entity.id
}

set_entity_position :: proc(state: ^AppState, id: int, pos: vec3) {
    entity := &state.entities[id]
    entity.position = pos
    state.entities[id].aabb = AABB {
        min = entity.model.bbox.min + entity.position,
        max = entity.model.bbox.max + entity.position
    }
}

add_obj_model :: proc(data: ObjectData, state: ^AppState) {
    // Create and upload texture
    using state.renderer
    model: Model
    tex_transfer_buffers: [4]^sdl.GPUTransferBuffer
    img_sizes: [4][2]i32
    i: int
    textures: [dynamic]^sdl.GPUTexture; defer if len(textures) == 0 do delete(textures)
    for i<len(data.texture_data.textures) {
        defer i += 1
        img_sizes[i] = data.texture_data.sizes[i]
        size := img_sizes[i]
        assert(size.x >= 1)
        assert(size.y >= 1)
        pixels := data.texture_data.textures[i]
        
        pixels_byte_size := u32(size.x * size.y * 4)
        texture := sdl.CreateGPUTexture(gpu, {
            type = .D2,
            format = .R8G8B8A8_UNORM_SRGB,
            usage = {.SAMPLER},
            width = u32(size.x),
            height = u32(size.y),
            layer_count_or_depth = 1,
            num_levels = 1,
        })

        append(&textures, texture)
        tex_transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
            usage = sdl.GPUTransferBufferUsage.UPLOAD,
            size = pixels_byte_size,
        }); assert(tex_transfer_buffer != nil)

        tex_transfer_mem := sdl.MapGPUTransferBuffer(gpu, tex_transfer_buffer, false); assert(tex_transfer_mem != nil)
        mem.copy(tex_transfer_mem, pixels, int(pixels_byte_size))
        sdl.UnmapGPUTransferBuffer(gpu, tex_transfer_buffer)
        tex_transfer_buffers[i] = tex_transfer_buffer
    }
    model.textures = textures[:]

    // Create and upload buffers
    len_bytes := u32(len(data.vertices) * size_of(Vertex))
    num_vertices: u32

    material_matrices := make([dynamic][4]vec4, 0, len(data.materials)); defer delete(material_matrices)
    for material in data.materials do append(&material_matrices, material_matrix(material))
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo              := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, data.vertices[:])
    material_buffer  := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_matrices[:])
    bbox: AABB = {min = max(f32), max = min(f32)}
    for vert, v in data.vertices {
        using vert
        if (position.x < bbox.min.x) do bbox.min.x = position.x;
        if (position.y < bbox.min.y) do bbox.min.y = position.y;
        if (position.z < bbox.min.z) do bbox.min.z = position.z;
        if (position.x > bbox.max.x) do bbox.max.x = position.x;
        if (position.y > bbox.max.y) do bbox.max.y = position.y;
        if (position.z > bbox.max.z) do bbox.max.z = position.z;
    }

    model.num_vertices = u32(len(data.vertices))
    model.bbox = bbox

    for j in 0..<i {
        sdl.UploadToGPUTexture(copy_pass, 
            {transfer_buffer = tex_transfer_buffers[j]},
            {texture = model.textures[j], w = u32(img_sizes[j].x), h = u32(img_sizes[j].y), d = 1},
            false
        )
    }

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    for j in 0..<i do sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffers[j])
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    // Assignments
    model.vbo = vbo
    model.material_buffer = material_buffer
    append(&state.models, model)
}

create_player :: proc() -> Player {
    position: vec3 = {0, 0, 0}
    return Player {
        position = position,
        bbox = AABB {
            min = position + {-0.2, 0, -0.2},
            max = position + {0.2, 2.1, 0.2}
        },
    }
}

_get_bbox_vertices :: proc(bbox: AABB) -> [24]vec3 {
    using bbox
    return {
        vec3{min.x, min.y, min.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{min.x, min.y, min.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{min.x, min.y, max.z},

        vec3{max.x, max.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, min.y, min.z},

        vec3{max.x, max.y, min.z},
        vec3{max.x, max.y, max.z},

        vec3{min.x, max.y, min.z},
        vec3{min.x, max.y, max.z},
        
        // Vertical bars
        vec3{min.x, min.y, min.z},
        vec3{min.x, max.y, min.z},

        vec3{max.x, min.y, min.z},
        vec3{max.x, max.y, min.z},

        vec3{min.x, min.y, max.z},
        vec3{min.x, max.y, max.z},

        vec3{max.x, min.y, max.z},
        vec3{max.x, max.y, max.z},
    }
}