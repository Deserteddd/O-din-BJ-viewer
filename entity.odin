package obj_viewer

import "core:fmt"
import "core:slice"
import lg "core:math/linalg"
import rand "core:math/rand"
import rd "../Redef"

EntityID :: distinct u32


Entity :: struct {
    id:         EntityID,
    name:       string,
    asset_name: string,
    renderable: ^Renderable,
    mesh:       ^Mesh,

    material_overrides: struct {
        color: vec4,
        metallic: f32,
        roughness: f32,
        attributes: bit_set[MaterialAttribute; u32],
    },
    physics:    PhysicsComponent,
    in_frustum: bool
}

MaterialID :: distinct u32

MaterialAttribute :: enum {
    Color,
    Metallic,
    Roughness,
}

MaterialCollection :: struct {
    id:             MaterialID,
    params:         []Material,
    params_buffer:  rd.StructuredBuffer,
    textures:       rd.TextureBuffer,
}

Renderable :: struct {
    vbo:            rd.VertexBuffer,
    ibo:            rd.IndexBuffer,
    materials:      MaterialCollection,
    aabb:           rd.VertexBuffer,
    primitives:     []Primitive,
}

AABB :: struct {
    min: vec3,
    max: vec3
}



Mesh :: struct {
    tris: [][3]vec3
}

used_ids: map[EntityID]bool

spawn_entity :: proc(scene: ^Scene, asset: string, under_player: bool, shoot: bool) -> (index: int) {
    index = entity_from_asset(scene, asset)
    if index == -1 do return
    entity := scene.entities[index]
    defer scene.entities[index] = entity
    if under_player {
        entity.physics.position = get_player_translation().x - {0, get_entity_aabb(entity).max.y, 0}
    } else {
        screen_size := rd.get_window_size()
        origin, dir := ray_from_screen(screen_size/2, screen_size)
        entity.physics.position = origin
        if shoot {
            entity.physics.speed = 20*dir
            entity.physics.dyn = true
        } else {
            entity.physics.position += 10*dir
        }
    }
    add_physics_body(&entity)
    return
}


remove_entity :: proc(scene: ^Scene, id: EntityID) -> bool {
    index := entity_index(scene, id)
    return remove_entity_by_index(scene, index)
}

remove_entity_by_index :: proc(scene: ^Scene, index: int) -> bool {
    if index < 0 || index >= len(scene.entities) do return false
    entity := scene.entities[index]
    id := entity.id
    assert(used_ids[id] == true)
    destroy_physics_body(&entity)
    ordered_remove_soa(&scene.entities, index)
    used_ids[id] = false
    return true
}

entity_index :: proc(scene: ^Scene, id: EntityID) -> int {
    if id == 0 do return -1
    for e, i in scene.entities {
        if e.id == id do return i
    }
    return -1
}

// Returns: index in entities array, -1 on failure
entity_from_asset :: proc(scene: ^Scene, asset_name: string, entity_name: string = "") -> (index: int) {
    entity: Entity
    for asset, i in scene.assets {
        if asset.name == asset_name {
            entity.renderable = &scene.renderables[i]
            entity.mesh = &scene.meshes[i]
            entity.physics.aabb = asset.data.header.aabb
            entity.asset_name = asset.name
            break
        }
    }
    if entity == {} do return -1
    ids := slice.from_ptr(scene.entities.id, len(scene.entities))
    id := lowest_free_id(scene)

    if entity_name == "" do entity.name = fmt.aprintf("%v-%v", asset_name, id)
    else do entity.name = entity_name

    entity.id = id
    entity.physics.scale = 1
    entity.physics.rotation = lg.QUATERNIONF32_IDENTITY

    assert(used_ids[id] == false)
    append_soa(&scene.entities, entity)
    used_ids[id] = true
    index = len(scene.entities)-1
    return
}

get_entity_aabb :: #force_inline proc(entity: Entity) -> AABB {
    return AABB {
        min = entity.physics.aabb.min * entity.physics.scale + entity.physics.position,
        max = entity.physics.aabb.max * entity.physics.scale + entity.physics.position
    }
}


@(private = "file")
lowest_free_id :: proc(scene: ^Scene) -> EntityID {
    for {
        id := EntityID(rand.uint32())
        if used_ids[id] do continue
        return id
    }
}
