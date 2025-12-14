package obj_viewer

import "core:strings"
import "base:runtime"
import "core:slice"
import "core:fmt"
import "core:log"
import "core:os"
import "core:encoding/json"
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

write_save_file :: proc(scene: Scene, loc := #caller_location) {
    save: SaveFile = {
        instances = make([]AssetInstance, len(scene.entities), context.temp_allocator),
        assets = make(map[string]string, context.temp_allocator)
    }
    save.checkpoint = g.player.checkpoint
    for a in scene.models {
        save.assets[a.name] = a.path
    }
    for e, i in scene.entities {
        save.instances[i] = AssetInstance {
            asset    = e.model.name,
            position = e.transform.translation,
            scale    = e.transform.scale
        }
    }
    json_data, err := json.marshal(
        save, 
        opt = {
            // pretty = true,
            mjson_keys_use_quotes = true
        },
        allocator = context.temp_allocator
    )
    assert(err == nil)
    ok := os.write_entire_file("savefile.json", json_data)
    assert(ok)
    fmt.printfln("%v: Save file writing successful", loc)
}

load_sprite :: proc(path: string, copy_pass: ^sdl.GPUCopyPass) -> Sprite {
    pixels, size := load_pixels_byte(path); assert(pixels != nil)
    size_u32: [2]u32 = {u32(size.x), u32(size.y)}
    texture := upload_texture(copy_pass, pixels, size_u32)
    assert(texture != nil)
    free_pixels(pixels)

    file_name  := strings.split(path, "/", context.temp_allocator)
    name_split := strings.split(file_name[len(file_name)-1], ".", context.temp_allocator)
    name       := strings.clone(name_split[0])

    return Sprite {
        name,
        texture,
        size
    }
}

load_sprite_sheet :: proc(path: string, copy_pass: ^sdl.GPUCopyPass) -> SpriteSheet {
    pixels, size := load_pixels_byte(path)
    defer stbi.image_free(raw_data(pixels))
    width  := size.x
    height := size.y

    horizontal_segments: [dynamic][2]i32
    defer delete(horizontal_segments)
    {
        non_empty_streak: i32
        start: i32
        for row: i32 = 0; row < height; row += 1 {
            row_is_empty := true

            row_start := row * width * 4

            for col: i32 = 0; col < width; col += 1 {
                alpha := pixels[row_start + col*4 + 3]

                if alpha > 2 {
                    row_is_empty = false
                    break
                }
            }

            if !row_is_empty {
                if non_empty_streak == 0 do start = row
                non_empty_streak += 1
            } else {
                if non_empty_streak > 3 {
                    segment: [2]i32 = {start, row}
                    append(&horizontal_segments, segment)
                }
                non_empty_streak = 0
            }
        }
    }
    rects: [dynamic]Rect
    for segment, i in horizontal_segments {
        start: i32 = -1
        end: i32   = -1
        empty_streak: int
        for col in 0..<width {
            empty_column := true
            for row in segment.x..<segment.y {
                index := (row * width + col) * 4
                alpha := pixels[index+3]
                if alpha > 5 {
                    empty_column = false
                    break
                } 
            }
            if empty_column {
                if start != -1 && end != -1 && empty_streak > 12 || (col == width - 1 && end == -1 && start != -1) {
                    // if i == 2 do log.debugf("upper: %d, lower: %d, left: %d, right: %d", segment.x, segment.y, start, end)
                    append(&rects, Rect{
                        f32(start),
                        f32(segment.x),
                        f32(end - start),
                        f32(segment.y - segment.x)
                    })
                    start = -1
                    end   = -1
                }
                if empty_streak == 0 do end = col
                empty_streak += 1
            } else {
                if start == -1 do start = col
                empty_streak = 0
            }


        }
    }

    sheet: SpriteSheet
    sheet.texture = upload_texture(copy_pass, pixels, {u32(size.x), u32(size.y)})
    assert(sheet.texture != nil)
    sheet.rects = rects[:]
    sheet.size = {width, height}
    return sheet
}

load_scene :: proc(savefile_path: string) -> Scene {
    save_file := load_save_file(savefile_path)
    defer free_save_file(save_file)
    g.player.checkpoint = save_file.checkpoint
    reset_player_pos()
    scene: Scene
    for asset in save_file.assets {
        model := load_obj_model(save_file.assets[asset])
        append(&scene.models, model)
        for instance in save_file.instances {
            if instance.asset == asset {
                entity_id, ok := entity_from_model(&scene, asset); assert(ok)
                set_entity_transform(&scene, entity_id, instance.position, instance.scale)
            }
        }
    }
    return scene
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
    // height_path   := strings.concatenate({path, "/height_map.png"})
    // diffuse_path  := strings.concatenate({path, "/diffuse.png"})
    // pixels, size  := load_pixels_u16(height_path);   defer free_pixels(pixels)
    // colors, dsize := load_pixels_byte(diffuse_path); defer free_pixels(colors)
    // assert(size == dsize)
    // fmt.println(len(pixels), size)
    size: [2]int = 2048
    // min: u16 = 1 << 15;
    // for pixel in pixels {
        // if pixel < min do min = pixel
    // }

    vertices := make([]HeightMapVertex, size.x*size.y)
    defer delete(vertices)
    indices:  [dynamic]u32
    defer delete(indices)
    // First pass to add a vertex for every pixel
    for &vert, i in vertices {
        row := i / size.x
        col := i % size.x
        x := f32(row-size.x/2)
        y := f32(col-size.y/2)
        // height := f32(pixel-min)
        vert = HeightMapVertex {
            position = {x, 0, y},
            color    = {0, 0, 0.4}
            // color = get_pixel_color(colors, row, col, size.x)
        }
        // vertices[i] = vert
    }
    // assert(i32(len(vertices)) == size.x * size.y)

    // Second pass to create indices for a triangulated mesh
    for i in 0..<len(vertices) {
        if i % size.x == size.x - 1 do continue // Second to last column
        if i / size.x == size.y - 1 do break    // Second to last line
        this_idx := u32(i)
        r_idx    := u32(i+1)
        d_idx    := u32(i+size.x)
        rd_idx   := u32(i+size.x+1)
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
    height_map: HeightMap
    height_map.num_indices  = u32(len(indices))
    height_map.vbo = vbo
    height_map.ibo = ibo
    height_map.scale = 1
    return height_map
}


load_pixels_byte :: proc(path: string, loc := #caller_location) -> (pixels: []byte, size: [2]i32) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator);
    pixel_data := stbi.load(path_cstr, &size.x, &size.y, nil, 4)
    if pixel_data == nil {
        log.errorf("%v: Pixel data nill", loc)
        panic("")
    }
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

@(private = "file")
get_pixel_color :: proc(pixels: []byte, row, col: i32, width: i32) -> vec3 {
    index := (row * width + col) * 4

    r := f32(pixels[index + 0]) / 255.0
    g := f32(pixels[index + 1]) / 255.0
    b := f32(pixels[index + 2]) / 255.0

    return vec3{r, g, b}
}