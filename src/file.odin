package obj_viewer

import "core:sys/windows"
import "core:strings"
import "base:runtime"

open_file_window :: proc() -> (path: string) {
    using windows
    file_path := make([^]u16, MAX_PATH, context.temp_allocator)
    ofn: OPENFILENAMEW = {
        lStructSize = u32(size_of(OPENFILENAMEW)),
        lpstrFile = file_path,
        nMaxFile = MAX_PATH,
    }
    ok := bool(GetOpenFileNameW(&ofn));
    if !ok do return ""
    err: runtime.Allocator_Error
    path, err = windows.wstring_to_utf8(ofn.lpstrFile, -1); assert(err == nil)
    return
}