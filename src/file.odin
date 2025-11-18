package obj_viewer

import "core:strings"
import "base:runtime"
import "core:slice"
import "core:os"
import "core:encoding/json"
import "core:log"
import "core:fmt"
import stbi "vendor:stb/image"
import sdl "vendor:sdl3"


AssetInstance :: struct {
    asset:    string,
    position,
    scale:    vec3   
}

SaveFile :: struct {
    checkpoint: [2]vec3,
    assets:    map[string]string,
    instances: []AssetInstance
}

write_save_file :: proc(state: AppState) {
    save: SaveFile = {
        instances = make([]AssetInstance, len(state.entities), context.temp_allocator),
        assets = make(map[string]string, context.temp_allocator)
    }
    save.checkpoint = state.player.checkpoint
    for a in state.models {
        save.assets[a.name] = a.path
    }
    for e, i in state.entities {
        save.instances[i] = AssetInstance {
            asset    = e.model.name,
            position = e.transform.translation,
            scale    = e.transform.scale
        }
    }
    json_data, err := json.marshal(
        save, 
        opt = {
            pretty = true,
            mjson_keys_use_quotes = true
        },
        allocator = context.temp_allocator
    )
    assert(err == nil)
    ok := os.write_entire_file("savefile.json", json_data)
    assert(ok)
    log.logf(.Info, "Saved successfully")
}

load_scene :: proc(state: ^AppState, save_file: string) {
    save_file := load_save_file("savefile")
    defer free_save_file(save_file)
    state.player.checkpoint = save_file.checkpoint
    reset_player_pos(&state.player)
    for asset in save_file.assets {
        model := load_obj_model(save_file.assets[asset])
        append(&state.models, model)
        for instance in save_file.instances {
            if instance.asset == asset {
                entity, ok := entity_from_model(state, asset); assert(ok)
                set_entity_transform(state, entity, instance.position, instance.scale)
            }
        }
    }
}

load_save_file :: proc(path: string) -> SaveFile {
    json_filename := strings.concatenate({path, ".json"}, context.temp_allocator)
    json_data, ok := os.read_entire_file_from_filename(json_filename, context.temp_allocator)
    assert(ok)

    result: SaveFile
    err := json.unmarshal(json_data, &result)
    assert(err == nil)

    return result
}

free_save_file :: proc(savefile: SaveFile) {
    delete(savefile.assets)
    delete(savefile.instances)
}

load_height_map :: proc(path: string) -> HeightMap {
    height_path   := strings.concatenate({path, "/height_map.png"})
    diffuse_path  := strings.concatenate({path, "/diffuse.png"})
    pixels, size  :=  load_pixels_u16(height_path); defer free_pixels(pixels)
    colors, dsize := load_pixels_byte(diffuse_path);          defer free_pixels(colors)
    assert(size == dsize)

    min: u16 = 1 << 15;
    for pixel in pixels {
        if pixel < min do min = pixel
    }

    vertices := make([]HeightMapVertex, size.x*size.y)
    defer delete(vertices)
    indices:  [dynamic]u32
    defer delete(indices)
    // First pass to add a vertex for every pixel
    for pixel, i in pixels {
        row := i32(i) / size.x
        col := i32(i) % size.x
        x := f32(row-size.x/2)
        y := f32(col-size.y/2)
        height := f32(pixel-min)
        vert := HeightMapVertex {
            position = {x, height, y},
            color = get_pixel_color(colors, row, col, size.x)
        }
        vertices[i] = vert
    }
    assert(i32(len(vertices)) == size.x * size.y)

    // Second pass to create indices for a triangulated mesh
    for i in 0..<len(pixels) {
        if i32(i) % size.x == size.x - 1 do continue // Second to last column
        if i32(i) / size.x == size.y - 1 do break    // Second to last line
        this_idx := u32(i)
        r_idx    := u32(i+1)
        d_idx    := u32(i32(i)+size.x)
        rd_idx   := u32(i32(i)+size.x+1)
        append_elems(&indices, this_idx, r_idx, d_idx, d_idx, r_idx, rd_idx)
    }
    copy_commands := sdl.AcquireGPUCommandBuffer(g.gpu); assert(copy_commands != nil)
    copy_pass := sdl.BeginGPUCopyPass(copy_commands); assert(copy_pass != nil)
    len_bytes := u32(len(vertices) * size_of(HeightMapVertex))
    transfer_buffer := sdl.CreateGPUTransferBuffer(g.gpu, {
        usage = sdl.GPUTransferBufferUsage.UPLOAD,
        size = len_bytes,
    }); assert(transfer_buffer != nil)
    vbo := create_buffer_with_data(transfer_buffer, copy_pass, {.VERTEX}, vertices[:])
    ibo := create_buffer_with_data(transfer_buffer, copy_pass, {.INDEX}, indices[:])

    sdl.ReleaseGPUTransferBuffer(g.gpu, transfer_buffer)
    sdl.EndGPUCopyPass(copy_pass)
    ok := sdl.SubmitGPUCommandBuffer(copy_commands); assert(ok)
    pipeline := create_render_pipeline(
        "heightmap.vert",
        "heightmap.frag",
        HeightMapVertex,
        {.FLOAT3, .FLOAT3},
        true,
    )
    height_map: HeightMap
    height_map.num_indices  = u32(len(indices))
    height_map.vbo = vbo
    height_map.ibo = ibo
    return height_map
}


load_pixels_byte :: proc(path: string) -> (pixels: []byte, size: [2]i32) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator);
    pixel_data := stbi.load(path_cstr, &size.x, &size.y, nil, 4)
    assert(pixel_data != nil)
    pixels = slice.bytes_from_ptr(pixel_data, int(size.x * size.y * 4))
    assert(pixels != nil)
    return
}

free_pixels_byte :: proc (pixels: []byte) {stbi.image_free(raw_data(pixels))}
free_pixels_u16  :: proc (pixels: []u16)  {stbi.image_free(raw_data(pixels))}
free_pixels :: proc {free_pixels_byte, free_pixels_u16}

load_cubemap_texture :: proc(
    copy_pass: ^sdl.GPUCopyPass, 
    paths: [sdl.GPUCubeMapFace]string
) -> ^sdl.GPUTexture {
    pixels: [sdl.GPUCubeMapFace][]byte
    size: u32
    for path, side in paths {
        side_pixels, img_size := load_pixels_byte(path)
        assert(side_pixels != nil)
        pixels[side] = side_pixels
        assert(img_size.x == img_size.y)
        if size == 0 do size = u32(img_size.x) 
        else do assert(u32(img_size.x) == size)
    }
    texture := upload_cubemap_texture_sides(copy_pass, pixels, size)
    for side_pixels in pixels do free_pixels(side_pixels)
    return texture
}


load_pixels_u16 :: proc(path: string) -> (pixels: []u16, size: [2]i32) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator);
    pixel_data := stbi.load_16(path_cstr, &size.x, &size.y, nil, 1); assert(pixel_data != nil)
    pixels = slice.from_ptr(pixel_data, int(size.x * size.y))
    assert(pixels != nil)
    return
}