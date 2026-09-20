#define _POSIX_C_SOURCE 200809L

#include <GL/glew.h>
#include <SDL2/SDL.h>
#include <ctype.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DORY_WIDTH 960
#define DORY_HEIGHT 600

static uint64_t monotonic_nanoseconds(void)
{
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static uint64_t fnv1a(const void *bytes, size_t count, uint64_t hash)
{
    const uint8_t *cursor = bytes;
    for (size_t index = 0; index < count; index++) {
        hash ^= cursor[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static int contains_ignoring_case(const char *text, const char *needle)
{
    size_t needle_count = strlen(needle);
    for (; *text; text++) {
        size_t index = 0;
        while (index < needle_count && text[index] &&
               tolower((unsigned char)text[index]) ==
                   tolower((unsigned char)needle[index]))
            index++;
        if (index == needle_count)
            return 1;
    }
    return 0;
}

static void print_json_string(const char *value)
{
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
        switch (*cursor) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*cursor < 0x20)
                printf("\\u%04x", *cursor);
            else
                putchar(*cursor);
        }
    }
    putchar('"');
}

#define GLYPH(a, b, c, d, e, f, g) \
    ((uint64_t)(a) | ((uint64_t)(b) << 5) | ((uint64_t)(c) << 10) | \
     ((uint64_t)(d) << 15) | ((uint64_t)(e) << 20) | \
     ((uint64_t)(f) << 25) | ((uint64_t)(g) << 30))

static uint64_t glyph(char character)
{
    switch ((char)toupper((unsigned char)character)) {
    case 'A': return GLYPH(14, 17, 17, 31, 17, 17, 17);
    case 'B': return GLYPH(30, 17, 17, 30, 17, 17, 30);
    case 'C': return GLYPH(14, 17, 16, 16, 16, 17, 14);
    case 'D': return GLYPH(30, 17, 17, 17, 17, 17, 30);
    case 'E': return GLYPH(31, 16, 16, 30, 16, 16, 31);
    case 'F': return GLYPH(31, 16, 16, 30, 16, 16, 16);
    case 'G': return GLYPH(14, 17, 16, 23, 17, 17, 15);
    case 'H': return GLYPH(17, 17, 17, 31, 17, 17, 17);
    case 'I': return GLYPH(14, 4, 4, 4, 4, 4, 14);
    case 'J': return GLYPH(7, 2, 2, 2, 18, 18, 12);
    case 'K': return GLYPH(17, 18, 20, 24, 20, 18, 17);
    case 'L': return GLYPH(16, 16, 16, 16, 16, 16, 31);
    case 'M': return GLYPH(17, 27, 21, 21, 17, 17, 17);
    case 'N': return GLYPH(17, 25, 21, 19, 17, 17, 17);
    case 'O': return GLYPH(14, 17, 17, 17, 17, 17, 14);
    case 'P': return GLYPH(30, 17, 17, 30, 16, 16, 16);
    case 'Q': return GLYPH(14, 17, 17, 17, 21, 18, 13);
    case 'R': return GLYPH(30, 17, 17, 30, 20, 18, 17);
    case 'S': return GLYPH(15, 16, 16, 14, 1, 1, 30);
    case 'T': return GLYPH(31, 4, 4, 4, 4, 4, 4);
    case 'U': return GLYPH(17, 17, 17, 17, 17, 17, 14);
    case 'V': return GLYPH(17, 17, 17, 17, 17, 10, 4);
    case 'W': return GLYPH(17, 17, 17, 21, 21, 21, 10);
    case 'X': return GLYPH(17, 17, 10, 4, 10, 17, 17);
    case 'Y': return GLYPH(17, 17, 10, 4, 4, 4, 4);
    case 'Z': return GLYPH(31, 1, 2, 4, 8, 16, 31);
    case '0': return GLYPH(14, 17, 19, 21, 25, 17, 14);
    case '1': return GLYPH(4, 12, 4, 4, 4, 4, 14);
    case '2': return GLYPH(14, 17, 1, 2, 4, 8, 31);
    case '3': return GLYPH(30, 1, 1, 14, 1, 1, 30);
    case '4': return GLYPH(2, 6, 10, 18, 31, 2, 2);
    case '5': return GLYPH(31, 16, 16, 30, 1, 1, 30);
    case '6': return GLYPH(14, 16, 16, 30, 17, 17, 14);
    case '7': return GLYPH(31, 1, 2, 4, 8, 8, 8);
    case '8': return GLYPH(14, 17, 17, 14, 17, 17, 14);
    case '9': return GLYPH(14, 17, 17, 15, 1, 1, 14);
    case ':': return GLYPH(0, 4, 4, 0, 4, 4, 0);
    case '-': return GLYPH(0, 0, 0, 31, 0, 0, 0);
    case '_': return GLYPH(0, 0, 0, 0, 0, 0, 31);
    case '.': return GLYPH(0, 0, 0, 0, 0, 12, 12);
    case '/': return GLYPH(1, 2, 2, 4, 8, 8, 16);
    case ' ': return 0;
    default: return GLYPH(14, 17, 2, 4, 4, 0, 4);
    }
}

static GLuint compile_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[2048] = {0};
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "dory-gl-probe: shader compile failed: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint create_program(void)
{
    static const char *vertex_source =
        "#version 330 core\n"
        "layout(location=0) in vec2 position;\n"
        "layout(location=1) in vec2 uv_in;\n"
        "uniform vec2 scale; uniform vec2 offset; uniform float angle;\n"
        "out vec2 uv;\n"
        "void main(){mat2 r=mat2(cos(angle),-sin(angle),sin(angle),cos(angle));"
        "gl_Position=vec4(r*(position*scale)+offset,0,1);uv=uv_in;}\n";
    static const char *fragment_source =
        "#version 330 core\n"
        "in vec2 uv; out vec4 color; uniform sampler2D image; uniform vec4 tint;\n"
        "void main(){color=texture(image,uv)*tint;}\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    if (!vertex || !fragment)
        return 0;
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[2048] = {0};
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "dory-gl-probe: program link failed: %s\n", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

static GLuint create_pattern_texture(void)
{
    uint8_t pixels[64 * 64 * 4];
    for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 64; x++) {
            int checker = ((x / 8) ^ (y / 8)) & 1;
            size_t offset = (size_t)(y * 64 + x) * 4;
            pixels[offset + 0] = checker ? 40 : 245;
            pixels[offset + 1] = checker ? 190 : 90;
            pixels[offset + 2] = checker ? 245 : 210;
            pixels[offset + 3] = checker ? 180 : 220;
        }
    }
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, pixels);
    return texture;
}

static GLuint create_text_texture(const char *text, int *width)
{
    size_t length = strlen(text);
    if (length > 64)
        length = 64;
    *width = (int)(length * 6);
    uint8_t *pixels = calloc((size_t)*width * 7 * 4, 1);
    if (!pixels)
        return 0;
    for (size_t character = 0; character < length; character++) {
        uint64_t rows = glyph(text[character]);
        for (int y = 0; y < 7; y++) {
            uint8_t row = (uint8_t)((rows >> (y * 5)) & 31u);
            for (int x = 0; x < 5; x++) {
                if ((row & (1u << (4 - x))) == 0)
                    continue;
                size_t offset = ((size_t)y * (size_t)*width + character * 6 + x) * 4;
                pixels[offset + 0] = 255;
                pixels[offset + 1] = 255;
                pixels[offset + 2] = 255;
                pixels[offset + 3] = 255;
            }
        }
    }
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, *width, 7, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, pixels);
    free(pixels);
    return texture;
}

int main(int argc, char **argv)
{
    const char *nonce = "dory-gl-default";
    uint32_t frame_count = 120;
    uint32_t hold_milliseconds = 2000;
    for (int index = 1; index < argc; index++) {
        if (strncmp(argv[index], "--nonce=", 8) == 0 && argv[index][8]) {
            nonce = argv[index] + 8;
        } else if (strncmp(argv[index], "--frames=", 9) == 0) {
            frame_count = (uint32_t)strtoul(argv[index] + 9, NULL, 10);
            if (frame_count == 0 || frame_count > 10000)
                frame_count = 0;
        } else if (strncmp(argv[index], "--hold-ms=", 10) == 0) {
            hold_milliseconds = (uint32_t)strtoul(argv[index] + 10, NULL, 10);
            if (hold_milliseconds > 30000)
                hold_milliseconds = UINT32_MAX;
        } else {
            frame_count = 0;
        }
    }
    if (frame_count == 0 || hold_milliseconds == UINT32_MAX) {
        fprintf(stderr,
                "usage: %s [--nonce=VALUE] [--frames=1..10000] [--hold-ms=0..30000]\n",
                argv[0]);
        return 64;
    }

    uint64_t started = monotonic_nanoseconds();
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        fprintf(stderr, "dory-gl-probe: SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_Window *window = SDL_CreateWindow(
        "Dory OpenGL displayed-pixel probe", SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED, DORY_WIDTH, DORY_HEIGHT,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN);
    if (!window) {
        fprintf(stderr, "dory-gl-probe: SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_GLContext context = SDL_GL_CreateContext(window);
    if (!context) {
        fprintf(stderr, "dory-gl-probe: SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }
    glewExperimental = GL_TRUE;
    GLenum glew_status = glewInit();
    (void)glGetError();
    if (glew_status != GLEW_OK) {
        fprintf(stderr, "dory-gl-probe: glewInit failed: %s\n",
                glewGetErrorString(glew_status));
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    const char *vendor = (const char *)glGetString(GL_VENDOR);
    const char *version = (const char *)glGetString(GL_VERSION);
    if (!renderer || !vendor || !version ||
        contains_ignoring_case(renderer, "llvmpipe") ||
        contains_ignoring_case(renderer, "lavapipe") ||
        contains_ignoring_case(renderer, "software rasterizer")) {
        fprintf(stderr,
                "dory-gl-probe: a hardware OpenGL renderer is required; software fallback is rejected\n");
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    GLuint program = create_program();
    if (!program) {
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }
    const float vertices[] = {
        -1, -1, 0, 0,  1, -1, 1, 0,  1, 1, 1, 1,
        -1, -1, 0, 0,  1, 1, 1, 1, -1, 1, 0, 1,
    };
    GLuint vertex_array = 0;
    GLuint vertex_buffer = 0;
    glGenVertexArrays(1, &vertex_array);
    glGenBuffers(1, &vertex_buffer);
    glBindVertexArray(vertex_array);
    glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          (void *)(2 * sizeof(float)));

    char label[96];
    snprintf(label, sizeof(label), "FRAME:%06u NONCE:%.48s", frame_count, nonce);
    int text_width = 0;
    GLuint pattern_texture = create_pattern_texture();
    GLuint text_texture = create_text_texture(label, &text_width);
    (void)text_width;
    if (!pattern_texture || !text_texture) {
        fprintf(stderr, "dory-gl-probe: texture allocation failed\n");
        glDeleteProgram(program);
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    glUseProgram(program);
    GLint scale_location = glGetUniformLocation(program, "scale");
    GLint offset_location = glGetUniformLocation(program, "offset");
    GLint angle_location = glGetUniformLocation(program, "angle");
    GLint tint_location = glGetUniformLocation(program, "tint");
    glUniform1i(glGetUniformLocation(program, "image"), 0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glViewport(0, 0, DORY_WIDTH, DORY_HEIGHT);
    SDL_GL_SetSwapInterval(1);

    uint8_t *pixels = malloc((size_t)DORY_WIDTH * DORY_HEIGHT * 4);
    if (!pixels) {
        fprintf(stderr, "dory-gl-probe: readback allocation failed\n");
        return 1;
    }
    uint64_t render_started = monotonic_nanoseconds();
    uint32_t rendered = 0;
    for (; rendered < frame_count; rendered++) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT)
                frame_count = rendered + 1;
        }
        float phase = (float)rendered * 0.025f;
        glClearColor(0.035f, 0.045f, 0.075f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, pattern_texture);
        glUniform2f(scale_location, 0.54f, 0.72f);
        glUniform2f(offset_location, 0.0f, 0.08f);
        glUniform1f(angle_location, phase);
        glUniform4f(tint_location, 1.0f, 1.0f, 1.0f, 0.82f);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        glBindTexture(GL_TEXTURE_2D, text_texture);
        glUniform2f(scale_location, 0.88f, 0.075f);
        glUniform2f(offset_location, 0.0f, -0.82f);
        glUniform1f(angle_location, 0.0f);
        glUniform4f(tint_location, 0.55f, 0.94f, 1.0f, 1.0f);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        if (rendered + 1 == frame_count)
            glReadPixels(0, 0, DORY_WIDTH, DORY_HEIGHT, GL_RGBA,
                         GL_UNSIGNED_BYTE, pixels);
        SDL_GL_SwapWindow(window);
    }
    glFinish();
    uint64_t render_finished = monotonic_nanoseconds();
    if (hold_milliseconds)
        SDL_Delay(hold_milliseconds);

    uint64_t hash = fnv1a(nonce, strlen(nonce), UINT64_C(14695981039346656037));
    hash = fnv1a(pixels, (size_t)DORY_WIDTH * DORY_HEIGHT * 4, hash);
    uint64_t finished = monotonic_nanoseconds();
    fputs("{\"schema\":\"dev.dory.gpu-probe\",\"version\":1,", stdout);
    fputs("\"probe\":\"gl\",\"deviceName\":", stdout);
    print_json_string(renderer);
    fputs(",\"driver\":", stdout);
    print_json_string(vendor);
    fputs(",\"apiVersion\":", stdout);
    print_json_string(version);
    fputs(",\"extensionsUsed\":[\"GL_ARB_vertex_array_object\"],", stdout);
    printf("\"resultHash\":\"fnv1a64:%016" PRIx64 "\",", hash);
    printf("\"frameCount\":%u,\"nonce\":", rendered);
    print_json_string(nonce);
    printf(",\"timings\":{\"renderMilliseconds\":%.3f,\"totalMilliseconds\":%.3f},",
           (render_finished - render_started) / 1000000.0,
           (finished - started) / 1000000.0);
    printf("\"extent\":{\"width\":%d,\"height\":%d}}\n", DORY_WIDTH, DORY_HEIGHT);

    free(pixels);
    glDeleteTextures(1, &text_texture);
    glDeleteTextures(1, &pattern_texture);
    glDeleteBuffers(1, &vertex_buffer);
    glDeleteVertexArrays(1, &vertex_array);
    glDeleteProgram(program);
    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
