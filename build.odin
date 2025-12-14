package build

import "core:log"
import "core:strings"
import "core:slice"
import "core:path/filepath"
import os "core:os/os2"
import "base:runtime"

main :: proc() {
    context.logger = log.create_console_logger()
    EXE :: "gaym.exe"
    if slice.contains(os.args, "bs") do build_shaders()
    b: strings.Builder
    strings.builder_init(&b)
    strings.write_string(&b, "odin build src")
    if slice.contains(os.args, "debug")    do strings.write_string(&b, " -debug")
    else do strings.write_string(&b, " -disable-assert")
    if slice.contains(os.args, "sanitize") do strings.write_string(&b, " -sanitize=address")
    strings.write_string(&b, " -out:"+EXE)
    run_str(strings.to_string(b))
    log.info("Args:", os.args)
    if slice.contains(os.args, "run") do run({EXE})
}

build_shaders :: proc() {
    log.info("Building shaders")
    files, err := os.read_all_directory_by_path("shaders/src", context.temp_allocator)
    if err != nil {
        log.errorf("Error reading shader sources: {}", err)
        os.exit(1)
    }
    for file in files {
        shadercross(file, "spv")
        shadercross(file, "json")
    }
}

shadercross :: proc(file: os.File_Info, format: string) {
    basename := filepath.stem(file.name)
    outfile := filepath.join({"shaders/out", strings.concatenate({basename, ".", format})})
    run({"shadercross", file.fullpath, "-o", outfile, "-I", "shaders/include"})
}

run_str :: proc(cmd: string) {
    run(strings.split(cmd, " "))
}

run :: proc(cmd: []string) {
    code, err := exec(cmd)
    if err != nil {
        log.errorf("Error executing process {}", err)
        os.exit(1)
    }
    if code != 0 {
        log.errorf("Process exited with non-zero code {}", code)
        os.exit(1)
    }
}

exec :: proc(cmd: []string) -> (code: int, error: os.Error) {
    process := os.process_start({command = cmd, stdout = os.stdout, stderr = os.stderr}) or_return
    state := os.process_wait(process) or_return
    os.process_close(process) or_return
    return state.exit_code, nil
}