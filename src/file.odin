package obj_viewer

import "core:sys/windows"
import "core:strings"
import "base:runtime"
import "core:slice"
import "core:fmt"
import stbi "vendor:stb/image"
import sdl "vendor:sdl3"

open_file_window :: proc() -> (path: string) {
    file_path := make([^]u16, windows.MAX_PATH, context.temp_allocator)
    ofn: windows.OPENFILENAMEW = {
        lStructSize = u32(size_of(windows.OPENFILENAMEW)),
        lpstrFile = file_path,
        nMaxFile = windows.MAX_PATH,
    }
    ok := bool(windows.GetOpenFileNameW(&ofn));
    if !ok do return ""
    err: runtime.Allocator_Error
    path, err = windows.wstring_to_utf8(ofn.lpstrFile, -1); assert(err == nil)
    return
}

load_pixels :: proc(path: string) -> (pixels: []byte, size: [2]i32) {
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
    gpu: ^sdl.GPUDevice,
    copy_pass: ^sdl.GPUCopyPass, 
    paths: [sdl.GPUCubeMapFace]string
) -> ^sdl.GPUTexture {
    pixels: [sdl.GPUCubeMapFace][]byte
    size: u32
    for path, side in paths {
        side_pixels, img_size := load_pixels(path)
        assert(side_pixels != nil)
        pixels[side] = side_pixels
        assert(img_size.x == img_size.y)
        if size == 0 do size = u32(img_size.x) 
        else do assert(u32(img_size.x) == size)
    }
    texture := upload_cubemap_texture_sides(gpu, copy_pass, pixels, size)
    for side_pixels in pixels do free_pixels(side_pixels)
    return texture
}


load_height_map_pixels :: proc(path: string) -> (pixels: []u16, size: [2]i32) {
    path_cstr := strings.clone_to_cstring(path, context.temp_allocator);
    pixel_data := stbi.load_16(path_cstr, &size.x, &size.y, nil, 1); assert(pixel_data != nil)
    pixels = slice.from_ptr(pixel_data, int(size.x * size.y))
    assert(pixels != nil)
    return
}