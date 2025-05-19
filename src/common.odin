package obj_viewer
import "core:math"
import "core:math/linalg"
import "core:math/rand"

vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

WORLD_SIZE: vec3 = {100, 40, 100}
ENTITY_COUNT: u32 = 1000
DEBUG :: true

TRANSFORM_IDENTITY :: Transform {
    translation = 0,
    scale = 1,
    rotation = linalg.QUATERNIONF32_IDENTITY
}
ModelType :: enum {
    OBJ,
    GLTF
}

to_vec4 :: proc(v: vec3, f: f32) -> vec4 { return vec4{v.x, v.y, v.z, f} }

norm :: proc(v: vec3) -> f32 { return math.sqrt_f32(v.x*v.x + v.y*v.y + v.z*v.z) }

random_range :: proc(min: f32, max: f32) -> f32 {
    return rand.float32() * (max - min) + min
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


decompose_trs :: proc(matrix_data: [16]f32) -> (translation: vec3, scale: vec3, rotation: quaternion128) {
    // Convert [16]f32 column-major to math.Mat4
    mat := matrix[4,4]f32{
        matrix_data[0],  matrix_data[1],  matrix_data[2],  matrix_data[3],
        matrix_data[4],  matrix_data[5],  matrix_data[6],  matrix_data[7],
        matrix_data[8],  matrix_data[9],  matrix_data[10], matrix_data[11],
        matrix_data[12], matrix_data[13], matrix_data[14], matrix_data[15],
    }

    // Extract translation from last column
    translation = vec3{mat[3].x, mat[3].y, mat[3].z}

    // Extract columns of upper-left 3x3 matrix (rotation * scale)
    col0 := vec3{mat[0].x, mat[0].y, mat[0].z}
    col1 := vec3{mat[1].x, mat[1].y, mat[1].z}
    col2 := vec3{mat[2].x, mat[2].y, mat[2].z}

    // Compute scale
    scale.x = linalg.length(col0)
    scale.y = linalg.length(col1)
    scale.z = linalg.length(col2)

    // Normalize columns to extract rotation matrix
    norm_col0 := col0 / scale.x
    norm_col1 := col1 / scale.y
    norm_col2 := col2 / scale.z

    // Construct rotation matrix
    rot_mat := matrix[3,3]f32{
        norm_col0.x, norm_col0.y, norm_col0.z,
        norm_col1.x, norm_col1.y, norm_col1.z,
        norm_col2.x, norm_col2.y, norm_col2.z,
    }

    // Convert to quaternion
    rotation = linalg.quaternion_from_matrix3(rot_mat)

    return
}
