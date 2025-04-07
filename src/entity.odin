package obj_viewer

import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

/*
Constant entity id's:
    0: Player
*/
Entity :: struct {
    id: u32,
    model: Model,
    bbox_vbo: ^sdl.GPUBuffer,
}

Model :: struct {
    textures: []^sdl.GPUTexture,
    vbo: ^sdl.GPUBuffer,
    material_buffer: ^sdl.GPUBuffer,
    mesh_boundary_indices: []u32,
}

move_entity :: proc(physics: ^Physics, bbox: ^AABB, by: vec3) {
    physics.position += by
    bbox.min += by
    bbox.max += by
}

print_entities :: proc(entities: [dynamic]Entity, physics: [dynamic]Physics) {
    for e, i in entities {
        assert(len(entities) == len(physics))
        fmt.printfln("Entity {} - has_model: {}", e.id, e.model.vbo != nil)
        fmt.println(physics[i].flags)
        fmt.println()
    }
}

CreateEntity :: proc(data: ObjectData, state: ^AppState, physics_flags: PhysicsFlags) {
    entity: Entity
    entity.id = u32(len(state.entities))
    physics: Physics
    physics.flags = physics_flags
    // Create and upload texture
    using state.renderer
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
            format = .R8G8B8A8_UNORM,
            usage = {.SAMPLER},
            width = u32(size.x),
            height = u32(size.y),
            layer_count_or_depth = 1,
            num_levels = 1
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
    entity.model.textures = textures[:]

    // Create and upload buffers
    len_bytes, num_vertices: u32
    vertices: [dynamic]Vertex; defer delete(vertices)
    bbox_vertices: [24]vec3
    mesh_boundary_indices := make([]u32, len(data.vertex_groups))
    bbox: AABB = {
        min = max(f32),
        max = min(f32)
    }
    for group, i in data.vertex_groups {
        len_bytes += u32(len(group)*size_of(Vertex))
        count: f32

        for vert, v in group {
            using vert
            num_vertices += 1
            count += 1
            if .COLLIDER in physics_flags {
                if (position.x < bbox.min.x) do bbox.min.x = position.x;
                if (position.y < bbox.min.y) do bbox.min.y = position.y;
                if (position.z < bbox.min.z) do bbox.min.z = position.z;

                if (position.x > bbox.max.x) do bbox.max.x = position.x;
                if (position.y > bbox.max.y) do bbox.max.y = position.y;
                if (position.z > bbox.max.z) do bbox.max.z = position.z;
            }
            append(&vertices, vert)
        }
        mesh_boundary_indices[i] = num_vertices
    }

    if .COLLIDER in physics_flags {
        bbox_vertices = get_bbox_vertices(bbox)
    }

    material_matrices := make([dynamic][4]vec4, 0, len(data.materials)); defer delete(material_matrices)
    for material in data.materials do append(&material_matrices, material_matrix(material))
    // fmt.println(bbox_vertices)
    transfer_buffer := sdl.CreateGPUTransferBuffer(gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    copy_commands := sdl.AcquireGPUCommandBuffer(gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    vbo              := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
    bounding_box_vbo := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.VERTEX}, bbox_vertices[:])
    material_buffer  := create_buffer_with_data(gpu, transfer_buffer, copy_pass, {.GRAPHICS_STORAGE_READ}, material_matrices[:])
    for j in 0..<i {
        sdl.UploadToGPUTexture(copy_pass, 
            {transfer_buffer = tex_transfer_buffers[j]},
            {texture = entity.model.textures[j], w = u32(img_sizes[j].x), h = u32(img_sizes[j].y), d = 1},
            false
        )
    }

    // End copy pass
    sdl.ReleaseGPUTransferBuffer(gpu, transfer_buffer)
    for j in 0..<i do sdl.ReleaseGPUTransferBuffer(gpu, tex_transfer_buffers[j])
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)

    // Assignments
    entity.model.vbo = vbo
    fmt.println(bbox_vertices)
    entity.bbox_vbo = bounding_box_vbo
    entity.model.material_buffer = material_buffer
    entity.model.mesh_boundary_indices = mesh_boundary_indices
    append(&state.entity_bounds, bbox)
    append(&state.entities, entity)
    append(&state.entity_physics, physics)
}

CreatePlayer :: proc(state: ^AppState) {
    physics := Physics{
        flags = {.PLAYER, .COLLIDER, .DYNAMIC},
        position = {0, 11, 0}
    }
    bbox := AABB {
        min = physics.position + {-0.2, 0, -0.2},
        max = physics.position + {0.2, 2.1, 0.2}
    }

    entity := Entity { id = 0 }

    append(&state.entities, entity)
    append(&state.entity_physics, physics)
    append(&state.entity_bounds, bbox)
}

get_bbox_vertices :: proc(bbox: AABB) -> [24]vec3 {
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