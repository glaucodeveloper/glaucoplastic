
#pragma once

#ifdef _WIN32
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
  #define GPWV2_API __declspec(dllexport)
#else
  #define GPWV2_API
#endif

typedef struct GPWV2Host GPWV2Host;

typedef struct GPWV2Rect {
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
} GPWV2Rect;

typedef void (__cdecl *GPWV2MessageCallback)(
  int32_t surface,
  const char* messageUtf8,
  void* userData
);

typedef void (__cdecl *GPWV2SourceCallback)(
  const char* urlUtf8,
  void* userData
);

typedef void (__cdecl *GPWV2LogCallback)(
  const char* messageUtf8,
  void* userData
);

GPWV2_API GPWV2Host* __cdecl gpwv2_create(
  const char* titleUtf8,
  const char* userDataFolderUtf8,
  int32_t width,
  int32_t height,
  GPWV2MessageCallback messageCallback,
  GPWV2SourceCallback sourceCallback,
  GPWV2LogCallback logCallback,
  void* userData
);

GPWV2_API int32_t __cdecl gpwv2_wait_ready(
  GPWV2Host* host,
  int32_t timeoutMs
);

GPWV2_API int32_t __cdecl gpwv2_run(
  GPWV2Host* host
);

GPWV2_API void __cdecl gpwv2_close(
  GPWV2Host* host
);

GPWV2_API void __cdecl gpwv2_destroy(
  GPWV2Host* host
);

GPWV2_API int32_t __cdecl gpwv2_shell_set_html(
  GPWV2Host* host,
  const char* htmlUtf8
);

GPWV2_API int32_t __cdecl gpwv2_foreign_navigate(
  GPWV2Host* host,
  const char* urlUtf8
);

GPWV2_API int32_t __cdecl gpwv2_foreign_add_document_script(
  GPWV2Host* host,
  const char* scriptUtf8
);

GPWV2_API char* __cdecl gpwv2_foreign_execute_sync(
  GPWV2Host* host,
  const char* scriptUtf8,
  int32_t timeoutMs
);

GPWV2_API void __cdecl gpwv2_free_string(
  char* value
);

GPWV2_API void __cdecl gpwv2_set_foreign_bounds(
  GPWV2Host* host,
  int32_t x,
  int32_t y,
  int32_t width,
  int32_t height
);

GPWV2_API void __cdecl gpwv2_set_foreign_visible(
  GPWV2Host* host,
  int32_t visible
);

GPWV2_API void __cdecl gpwv2_set_foreign_input_regions(
  GPWV2Host* host,
  const GPWV2Rect* rects,
  int32_t count
);

GPWV2_API void __cdecl gpwv2_present(
  GPWV2Host* host
);

#ifdef __cplusplus
}
#endif
#endif
