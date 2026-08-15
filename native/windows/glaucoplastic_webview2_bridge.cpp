
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <dcomp.h>
#include <d3d11.h>
#include <dxgi.h>

#include <WebView2.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "glaucoplastic_webview2_bridge.h"

template <typename T>
void safe_release(T*& value) {
  if (value) {
    value->Release();
    value = nullptr;
  }
}

std::wstring utf8_to_wide(const char* text) {
  if (!text || !*text) {
    return std::wstring();
  }

  const int required = MultiByteToWideChar(
    CP_UTF8,
    MB_ERR_INVALID_CHARS,
    text,
    -1,
    nullptr,
    0
  );

  if (required <= 0) {
    return std::wstring();
  }

  std::wstring out;
  out.resize(static_cast<size_t>(required));

  const int written = MultiByteToWideChar(
    CP_UTF8,
    MB_ERR_INVALID_CHARS,
    text,
    -1,
    out.data(),
    required
  );

  if (written <= 0) {
    return std::wstring();
  }

  if (!out.empty() && out.back() == L'\0') {
    out.pop_back();
  }

  return out;
}

std::string wide_to_utf8(const wchar_t* text) {
  if (!text || !*text) {
    return std::string();
  }

  const int required = WideCharToMultiByte(
    CP_UTF8,
    WC_ERR_INVALID_CHARS,
    text,
    -1,
    nullptr,
    0,
    nullptr,
    nullptr
  );

  if (required <= 0) {
    return std::string();
  }

  std::string out;
  out.resize(static_cast<size_t>(required));

  const int written = WideCharToMultiByte(
    CP_UTF8,
    WC_ERR_INVALID_CHARS,
    text,
    -1,
    out.data(),
    required,
    nullptr,
    nullptr
  );

  if (written <= 0) {
    return std::string();
  }

  if (!out.empty() && out.back() == '\0') {
    out.pop_back();
  }

return out;
}

template <typename Interface>
const IID& webview2_interface_iid();

template <typename Interface>
class ComHandlerBase : public Interface {
public:
  ULONG STDMETHODCALLTYPE AddRef() override {
    return ++refs_;
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG value = --refs_;
    if (value == 0) {
      delete this;
    }
    return value;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(
    REFIID iid,
    void** object
  ) override {
    if (!object) {
      return E_POINTER;
    }

    if (
      iid == IID_IUnknown ||
      iid == webview2_interface_iid<Interface>()
    ) {
      *object = static_cast<Interface*>(this);
      AddRef();
      return S_OK;
    }

    *object = nullptr;
    return E_NOINTERFACE;
  }

protected:
  virtual ~ComHandlerBase() = default;

private:
  std::atomic<ULONG> refs_{1};
};

template <typename Interface>
const IID& webview2_interface_iid();

template <>
const IID& webview2_interface_iid<
  ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
>() {
  return IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
}

template <>
const IID& webview2_interface_iid<
  ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler
>() {
  return IID_ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler;
}

template <>
const IID& webview2_interface_iid<
  ICoreWebView2ExecuteScriptCompletedHandler
>() {
  return IID_ICoreWebView2ExecuteScriptCompletedHandler;
}

template <>
const IID& webview2_interface_iid<
  ICoreWebView2WebMessageReceivedEventHandler
>() {
  return IID_ICoreWebView2WebMessageReceivedEventHandler;
}

template <>
const IID& webview2_interface_iid<
  ICoreWebView2SourceChangedEventHandler
>() {
  return IID_ICoreWebView2SourceChangedEventHandler;
}

class EnvironmentCompletedHandler final
  : public ComHandlerBase<
      ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
    > {
public:
  explicit EnvironmentCompletedHandler(
    std::function<HRESULT(HRESULT, ICoreWebView2Environment*)> callback
  )
    : callback_(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE Invoke(
    HRESULT errorCode,
    ICoreWebView2Environment* environment
  ) override {
    return callback_(errorCode, environment);
  }

private:
  std::function<HRESULT(HRESULT, ICoreWebView2Environment*)> callback_;
};

class CompositionControllerCompletedHandler final
  : public ComHandlerBase<
      ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler
    > {
public:
  explicit CompositionControllerCompletedHandler(
    std::function<
      HRESULT(
        HRESULT,
        ICoreWebView2CompositionController*
      )
    > callback
  )
    : callback_(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE Invoke(
    HRESULT errorCode,
    ICoreWebView2CompositionController* controller
  ) override {
    return callback_(errorCode, controller);
  }

private:
  std::function<
    HRESULT(
      HRESULT,
      ICoreWebView2CompositionController*
    )
  > callback_;
};

class ExecuteScriptCompletedHandler final
  : public ComHandlerBase<
      ICoreWebView2ExecuteScriptCompletedHandler
    > {
public:
  explicit ExecuteScriptCompletedHandler(
    std::function<HRESULT(HRESULT, LPCWSTR)> callback
  )
    : callback_(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE Invoke(
    HRESULT errorCode,
    LPCWSTR resultObjectAsJson
  ) override {
    return callback_(errorCode, resultObjectAsJson);
  }

private:
  std::function<HRESULT(HRESULT, LPCWSTR)> callback_;
};

class WebMessageReceivedHandler final
  : public ComHandlerBase<
      ICoreWebView2WebMessageReceivedEventHandler
    > {
public:
  explicit WebMessageReceivedHandler(
    std::function<
      HRESULT(
        ICoreWebView2*,
        ICoreWebView2WebMessageReceivedEventArgs*
      )
    > callback
  )
    : callback_(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE Invoke(
    ICoreWebView2* sender,
    ICoreWebView2WebMessageReceivedEventArgs* args
  ) override {
    return callback_(sender, args);
  }

private:
  std::function<
    HRESULT(
      ICoreWebView2*,
      ICoreWebView2WebMessageReceivedEventArgs*
    )
  > callback_;
};

class SourceChangedHandler final
  : public ComHandlerBase<
      ICoreWebView2SourceChangedEventHandler
    > {
public:
  explicit SourceChangedHandler(
    std::function<
      HRESULT(
        ICoreWebView2*,
        ICoreWebView2SourceChangedEventArgs*
      )
    > callback
  )
    : callback_(std::move(callback)) {}

  HRESULT STDMETHODCALLTYPE Invoke(
    ICoreWebView2* sender,
    ICoreWebView2SourceChangedEventArgs* args
  ) override {
    return callback_(sender, args);
  }

private:
  std::function<
    HRESULT(
      ICoreWebView2*,
      ICoreWebView2SourceChangedEventArgs*
    )
  > callback_;
};

struct GPWV2Surface {
  ICoreWebView2CompositionController* composition = nullptr;
  ICoreWebView2Controller* controller = nullptr;
  ICoreWebView2* webview = nullptr;
  IDCompositionVisual* visual = nullptr;

  EventRegistrationToken messageToken{};
  EventRegistrationToken sourceToken{};

  RECT bounds{0, 0, 1, 1};
  bool ready = false;
  bool visible = true;
};

using CreateEnvironmentWithOptionsFn = HRESULT (STDAPICALLTYPE*)(
  PCWSTR,
  PCWSTR,
  ICoreWebView2EnvironmentOptions*,
  ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*
);

struct GPWV2Host {
  HWND hwnd = nullptr;
  HMODULE loaderModule = nullptr;
  bool comInitialized = false;

  ID3D11Device* d3dDevice = nullptr;
  IDXGIDevice* dxgiDevice = nullptr;
  IDCompositionDevice* dcompDevice = nullptr;
  IDCompositionTarget* dcompTarget = nullptr;
  IDCompositionVisual* rootVisual = nullptr;

  ICoreWebView2Environment* environment = nullptr;
  ICoreWebView2Environment3* environment3 = nullptr;

  GPWV2Surface foreignSurface;
  GPWV2Surface shellSurface;

  std::vector<RECT> foreignInputRegions;

  GPWV2MessageCallback messageCallback = nullptr;
  GPWV2SourceCallback sourceCallback = nullptr;
  GPWV2LogCallback logCallback = nullptr;
  void* userData = nullptr;

  std::wstring title;
  std::wstring userDataFolder;

  int width = 1280;
  int height = 800;

  bool ready = false;
  bool failed = false;
  HRESULT failureCode = S_OK;
  bool running = false;
};

constexpr wchar_t kWindowClassName[] =
  L"GlaucoPlasticWebView2CompositionHost";

const char* kWebKitCompatibilityShim = R"JS(
(() => {
  if (window.__glaucoplasticWebView2BridgeInstalled) {
    return;
  }

  if (
    !window.chrome ||
    !window.chrome.webview ||
    typeof window.chrome.webview.postMessage !== 'function'
  ) {
    return;
  }

  window.__glaucoplasticWebView2BridgeInstalled = true;

  const post = (channel, payload) => {
    try {
      window.chrome.webview.postMessage(
        JSON.stringify({
          channel,
          payload
        })
      );
    } catch (_) {}
  };

  const existingWebKit =
    window.webkit && typeof window.webkit === 'object'
      ? window.webkit
      : {};

  const handlers =
    existingWebKit.messageHandlers &&
    typeof existingWebKit.messageHandlers === 'object'
      ? existingWebKit.messageHandlers
      : {};

  const ensureHandler = channel => {
    if (
      handlers[channel] &&
      typeof handlers[channel].postMessage === 'function'
    ) {
      return;
    }

    handlers[channel] = {
      postMessage(payload) {
        post(channel, payload);
      }
    };
  };

  ensureHandler('glaucoplasticEvent');
  ensureHandler('glaucoplasticLayout');

  existingWebKit.messageHandlers = handlers;
  window.webkit = existingWebKit;
})();
)JS";

void host_log(
  GPWV2Host* host,
  const std::string& message
) {
  if (
    host &&
    host->logCallback
  ) {
    host->logCallback(
      message.c_str(),
      host->userData
    );
  }
}

bool point_in_rect(
  const RECT& rectangle,
  POINT point
) {
  return (
    point.x >= rectangle.left &&
    point.x < rectangle.right &&
    point.y >= rectangle.top &&
    point.y < rectangle.bottom
  );
}

COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS virtual_keys_from_wparam(
  WPARAM wParam
) {
  UINT value = 0;

  if (wParam & MK_CONTROL) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_CONTROL;
  }
  if (wParam & MK_SHIFT) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_SHIFT;
  }
  if (wParam & MK_LBUTTON) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON;
  }
  if (wParam & MK_MBUTTON) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_MIDDLE_BUTTON;
  }
  if (wParam & MK_RBUTTON) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_RIGHT_BUTTON;
  }
  if (wParam & MK_XBUTTON1) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_X_BUTTON1;
  }
  if (wParam & MK_XBUTTON2) {
    value |= COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_X_BUTTON2;
  }

  return static_cast<
    COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS
  >(value);
}

bool map_mouse_kind(
  UINT message,
  COREWEBVIEW2_MOUSE_EVENT_KIND& kind,
  UINT32& mouseData
) {
  mouseData = 0;

  switch (message) {
    case WM_MOUSEMOVE:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
      return true;

    case WM_LBUTTONDOWN:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN;
      return true;

    case WM_LBUTTONUP:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
      return true;

    case WM_LBUTTONDBLCLK:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOUBLE_CLICK;
      return true;

    case WM_RBUTTONDOWN:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_DOWN;
      return true;

    case WM_RBUTTONUP:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_UP;
      return true;

    case WM_RBUTTONDBLCLK:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_DOUBLE_CLICK;
      return true;

    case WM_MBUTTONDOWN:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_DOWN;
      return true;

    case WM_MBUTTONUP:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_UP;
      return true;

    case WM_MBUTTONDBLCLK:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_DOUBLE_CLICK;
      return true;

    case WM_XBUTTONDOWN:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_X_BUTTON_DOWN;
      return true;

    case WM_XBUTTONUP:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_X_BUTTON_UP;
      return true;

    case WM_XBUTTONDBLCLK:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_X_BUTTON_DOUBLE_CLICK;
      return true;

    case WM_MOUSEWHEEL:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL;
      return true;

    case WM_MOUSEHWHEEL:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_HORIZONTAL_WHEEL;
      return true;

    case WM_MOUSELEAVE:
      kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE;
      return true;

    default:
      return false;
  }
}

void apply_surface_bounds(
  GPWV2Host* host,
  GPWV2Surface& surface,
  const RECT& bounds
) {
  surface.bounds = bounds;

  if (surface.controller) {
    surface.controller->put_Bounds(bounds);
    surface.controller->put_IsVisible(
      surface.visible ? TRUE : FALSE
    );
  }

  if (host && host->dcompDevice) {
    host->dcompDevice->Commit();
  }
}

void resize_shell_to_client(
  GPWV2Host* host
) {
  if (!host || !host->hwnd) {
    return;
  }

  RECT client{};
  GetClientRect(
    host->hwnd,
    &client
  );

  host->width =
    std::max(1L, client.right - client.left);

  host->height =
    std::max(1L, client.bottom - client.top);

  apply_surface_bounds(
    host,
    host->shellSurface,
    client
  );
}

GPWV2Surface* choose_surface_for_point(
  GPWV2Host* host,
  POINT point
) {
  if (!host) {
    return nullptr;
  }

  if (
    !host->foreignSurface.visible ||
    !host->foreignSurface.ready
  ) {
    return &host->shellSurface;
  }

  if (!host->foreignInputRegions.empty()) {
    for (const RECT& rectangle :
         host->foreignInputRegions) {
      if (point_in_rect(rectangle, point)) {
        return &host->foreignSurface;
      }
    }
    return &host->shellSurface;
  }

  if (
    point_in_rect(
      host->foreignSurface.bounds,
      point
    )
  ) {
    return &host->foreignSurface;
  }

  return &host->shellSurface;
}

void forward_mouse_message(
  GPWV2Host* host,
  UINT message,
  WPARAM wParam,
  LPARAM lParam
) {
  if (!host) {
    return;
  }

  COREWEBVIEW2_MOUSE_EVENT_KIND kind{};
  UINT32 mouseData = 0;

  if (!map_mouse_kind(
        message,
        kind,
        mouseData
      )) {
    return;
  }

  POINT point{};

  if (
    message == WM_XBUTTONDOWN ||
    message == WM_XBUTTONUP ||
    message == WM_XBUTTONDBLCLK
  ) {
    mouseData =
      static_cast<UINT32>(
        GET_XBUTTON_WPARAM(wParam)
      );
  }

  if (
    message == WM_MOUSEWHEEL ||
    message == WM_MOUSEHWHEEL
  ) {
    point.x =
      GET_X_LPARAM(lParam);
    point.y =
      GET_Y_LPARAM(lParam);

    ScreenToClient(
      host->hwnd,
      &point
    );

    mouseData =
      static_cast<UINT32>(
        GET_WHEEL_DELTA_WPARAM(wParam)
      );
  } else {
    point.x =
      GET_X_LPARAM(lParam);
    point.y =
      GET_Y_LPARAM(lParam);
  }

  GPWV2Surface* surface =
    choose_surface_for_point(
      host,
      point
    );

  if (
    !surface ||
    !surface->composition
  ) {
    return;
  }

  POINT localPoint =
    point;

  if (surface == &host->foreignSurface) {
    localPoint.x -=
      surface->bounds.left;
    localPoint.y -=
      surface->bounds.top;
  }

  if (
    message == WM_LBUTTONDOWN ||
    message == WM_RBUTTONDOWN ||
    message == WM_MBUTTONDOWN ||
    message == WM_XBUTTONDOWN
  ) {
    if (surface->controller) {
      surface->controller->MoveFocus(
        COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC
      );
    }
  }

  surface->composition->SendMouseInput(
    kind,
    virtual_keys_from_wparam(wParam),
    mouseData,
    localPoint
  );
}

LRESULT CALLBACK host_window_proc(
  HWND hwnd,
  UINT message,
  WPARAM wParam,
  LPARAM lParam
) {
  GPWV2Host* host =
    reinterpret_cast<GPWV2Host*>(
      GetWindowLongPtrW(
        hwnd,
        GWLP_USERDATA
      )
    );

  switch (message) {
    case WM_NCCREATE: {
      auto* create =
        reinterpret_cast<CREATESTRUCTW*>(
          lParam
        );

      auto* newHost =
        reinterpret_cast<GPWV2Host*>(
          create->lpCreateParams
        );

      SetWindowLongPtrW(
        hwnd,
        GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(
          newHost
        )
      );

      return TRUE;
    }

    case WM_SIZE:
      if (host) {
        resize_shell_to_client(host);
      }
      return 0;

    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MBUTTONDBLCLK:
    case WM_XBUTTONDOWN:
    case WM_XBUTTONUP:
    case WM_XBUTTONDBLCLK:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
    case WM_MOUSELEAVE:
      forward_mouse_message(
        host,
        message,
        wParam,
        lParam
      );
      return 0;

    case WM_CLOSE:
      DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY:
      if (host) {
        host->running = false;
      }
      PostQuitMessage(0);
      return 0;
  }

  return DefWindowProcW(
    hwnd,
    message,
    wParam,
    lParam
  );
}

bool register_window_class() {
  static bool registered = false;

  if (registered) {
    return true;
  }

  WNDCLASSEXW windowClass{};
  windowClass.cbSize =
    sizeof(windowClass);
  windowClass.style =
    CS_HREDRAW |
    CS_VREDRAW |
    CS_DBLCLKS;
  windowClass.lpfnWndProc =
    host_window_proc;
  windowClass.hInstance =
    GetModuleHandleW(nullptr);
  windowClass.hCursor =
    LoadCursorW(
      nullptr,
      IDC_ARROW
    );
  windowClass.hbrBackground =
    reinterpret_cast<HBRUSH>(
      COLOR_WINDOW + 1
    );
  windowClass.lpszClassName =
    kWindowClassName;

  registered =
    RegisterClassExW(
      &windowClass
    ) != 0 ||
    GetLastError() ==
      ERROR_CLASS_ALREADY_EXISTS;

  return registered;
}

bool initialize_direct_composition(
  GPWV2Host* host
) {
  if (!host) {
    return false;
  }

  D3D_FEATURE_LEVEL featureLevel{};

  HRESULT hr =
    D3D11CreateDevice(
      nullptr,
      D3D_DRIVER_TYPE_HARDWARE,
      nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      nullptr,
      0,
      D3D11_SDK_VERSION,
      &host->d3dDevice,
      &featureLevel,
      nullptr
    );

  if (FAILED(hr)) {
    hr =
      D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_WARP,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr,
        0,
        D3D11_SDK_VERSION,
        &host->d3dDevice,
        &featureLevel,
        nullptr
      );
  }

  if (FAILED(hr)) {
    host_log(
      host,
      "webview2.dcomp D3D11CreateDevice failed"
    );
    return false;
  }

  hr =
    host->d3dDevice->QueryInterface(
      IID_IDXGIDevice,
      reinterpret_cast<void**>(
        &host->dxgiDevice
      )
    );

  if (FAILED(hr)) {
    host_log(
      host,
      "webview2.dcomp IDXGIDevice unavailable"
    );
    return false;
  }

  hr =
    DCompositionCreateDevice(
      host->dxgiDevice,
      __uuidof(IDCompositionDevice),
      reinterpret_cast<void**>(
        &host->dcompDevice
      )
    );

  if (FAILED(hr)) {
    host_log(
      host,
      "webview2.dcomp DCompositionCreateDevice failed"
    );
    return false;
  }

  hr =
    host->dcompDevice->CreateTargetForHwnd(
      host->hwnd,
      TRUE,
      &host->dcompTarget
    );

  if (FAILED(hr)) {
    host_log(
      host,
      "webview2.dcomp CreateTargetForHwnd failed"
    );
    return false;
  }

  hr =
    host->dcompDevice->CreateVisual(
      &host->rootVisual
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->dcompDevice->CreateVisual(
      &host->foreignSurface.visual
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->dcompDevice->CreateVisual(
      &host->shellSurface.visual
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->rootVisual->AddVisual(
      host->foreignSurface.visual,
      FALSE,
      nullptr
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->rootVisual->AddVisual(
      host->shellSurface.visual,
      TRUE,
      host->foreignSurface.visual
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->dcompTarget->SetRoot(
      host->rootVisual
    );

  if (FAILED(hr)) {
    return false;
  }

  hr =
    host->dcompDevice->Commit();

  if (FAILED(hr)) {
    return false;
  }

  return true;
}

void notify_source(
  GPWV2Host* host
) {
  if (
    !host ||
    !host->sourceCallback ||
    !host->foreignSurface.webview
  ) {
    return;
  }

  LPWSTR value = nullptr;

  if (
    SUCCEEDED(
      host->foreignSurface.webview->get_Source(
        &value
      )
    ) &&
    value
  ) {
    const std::string utf8 =
      wide_to_utf8(value);

    CoTaskMemFree(value);

    host->sourceCallback(
      utf8.c_str(),
      host->userData
    );
  }
}

HRESULT configure_surface(
  GPWV2Host* host,
  GPWV2Surface& surface,
  ICoreWebView2CompositionController* composition,
  int surfaceId
) {
  if (
    !host ||
    !composition ||
    !surface.visual
  ) {
    return E_INVALIDARG;
  }

  surface.composition =
    composition;
  surface.composition->AddRef();

  HRESULT hr =
    surface.composition->QueryInterface(
      IID_ICoreWebView2Controller,
      reinterpret_cast<void**>(
        &surface.controller
      )
    );

  if (FAILED(hr)) {
    return hr;
  }

  hr =
    surface.controller->get_CoreWebView2(
      &surface.webview
    );

  if (FAILED(hr)) {
    return hr;
  }

  hr =
    surface.composition->put_RootVisualTarget(
      surface.visual
    );

  if (FAILED(hr)) {
    return hr;
  }

  ICoreWebView2Controller2* controller2 =
    nullptr;

  if (
    SUCCEEDED(
      surface.controller->QueryInterface(
        IID_ICoreWebView2Controller2,
        reinterpret_cast<void**>(
          &controller2
        )
      )
    ) &&
    controller2
  ) {
    COREWEBVIEW2_COLOR color{};

    if (surfaceId == 1) {
      color.A = 0;
      color.R = 0;
      color.G = 0;
      color.B = 0;
    } else {
      color.A = 255;
      color.R = 255;
      color.G = 255;
      color.B = 255;
    }

    controller2->put_DefaultBackgroundColor(
      color
    );

    controller2->Release();
  }

  auto* messageHandler =
    new WebMessageReceivedHandler(
      [host, surfaceId](
        ICoreWebView2*,
        ICoreWebView2WebMessageReceivedEventArgs* args
      ) -> HRESULT {
        if (
          !host ||
          !args ||
          !host->messageCallback
        ) {
          return S_OK;
        }

        LPWSTR value = nullptr;

        HRESULT messageHr =
          args->TryGetWebMessageAsString(
            &value
          );

        if (
          SUCCEEDED(messageHr) &&
          value
        ) {
          const std::string utf8 =
            wide_to_utf8(value);

          CoTaskMemFree(value);

          host->messageCallback(
            surfaceId,
            utf8.c_str(),
            host->userData
          );
        }

        return S_OK;
      }
    );

  surface.webview->add_WebMessageReceived(
    messageHandler,
    &surface.messageToken
  );

  messageHandler->Release();

  if (surfaceId == 0) {
    auto* sourceHandler =
      new SourceChangedHandler(
        [host](
          ICoreWebView2*,
          ICoreWebView2SourceChangedEventArgs*
        ) -> HRESULT {
          notify_source(host);
          return S_OK;
        }
      );

    surface.webview->add_SourceChanged(
      sourceHandler,
      &surface.sourceToken
    );

    sourceHandler->Release();
  }

  const std::wstring shim =
    utf8_to_wide(
      kWebKitCompatibilityShim
    );

  surface.webview->AddScriptToExecuteOnDocumentCreated(
    shim.c_str(),
    nullptr
  );

  surface.ready = true;

  if (surfaceId == 1) {
    RECT full{
      0,
      0,
      host->width,
      host->height
    };

    apply_surface_bounds(
      host,
      surface,
      full
    );
  } else {
    apply_surface_bounds(
      host,
      surface,
      surface.bounds
    );
  }

  if (
    host->foreignSurface.ready &&
    host->shellSurface.ready
  ) {
    host->ready = true;
    host_log(
      host,
      "webview2.composition ready=true"
    );
  }

  return S_OK;
}

HRESULT create_composition_surface(
  GPWV2Host* host,
  GPWV2Surface& surface,
  int surfaceId
) {
  if (
    !host ||
    !host->environment3
  ) {
    return E_FAIL;
  }

  auto* handler =
    new CompositionControllerCompletedHandler(
      [host, &surface, surfaceId](
        HRESULT errorCode,
        ICoreWebView2CompositionController* controller
      ) -> HRESULT {
        if (
          FAILED(errorCode) ||
          !controller
        ) {
          host->failed = true;
          host->failureCode =
            FAILED(errorCode)
              ? errorCode
              : E_FAIL;

          host_log(
            host,
            surfaceId == 0
              ? "webview2.foreign controller failed"
              : "webview2.shell controller failed"
          );

          return S_OK;
        }

        const HRESULT configureHr =
          configure_surface(
            host,
            surface,
            controller,
            surfaceId
          );

        if (FAILED(configureHr)) {
          host->failed = true;
          host->failureCode =
            configureHr;
        }

        return S_OK;
      }
    );

  HRESULT hr =
    host->environment3->
      CreateCoreWebView2CompositionController(
        host->hwnd,
        handler
      );

  handler->Release();

  return hr;
}

bool initialize_webview_environment(
  GPWV2Host* host
) {
  if (!host) {
    return false;
  }

  host->loaderModule =
    LoadLibraryW(
      L"WebView2Loader.dll"
    );

  if (!host->loaderModule) {
    host_log(
      host,
      "WebView2Loader.dll not found"
    );
    return false;
  }

  auto createEnvironment =
    reinterpret_cast<
      CreateEnvironmentWithOptionsFn
    >(
      GetProcAddress(
        host->loaderModule,
        "CreateCoreWebView2EnvironmentWithOptions"
      )
    );

  if (!createEnvironment) {
    host_log(
      host,
      "CreateCoreWebView2EnvironmentWithOptions not found"
    );
    return false;
  }

  auto* handler =
    new EnvironmentCompletedHandler(
      [host](
        HRESULT errorCode,
        ICoreWebView2Environment* environment
      ) -> HRESULT {
        if (
          FAILED(errorCode) ||
          !environment
        ) {
          host->failed = true;
          host->failureCode =
            FAILED(errorCode)
              ? errorCode
              : E_FAIL;

          host_log(
            host,
            "webview2.environment failed"
          );

          return S_OK;
        }

        host->environment =
          environment;
        host->environment->AddRef();

        HRESULT hr =
          environment->QueryInterface(
            IID_ICoreWebView2Environment3,
            reinterpret_cast<void**>(
              &host->environment3
            )
          );

        if (FAILED(hr)) {
          host->failed = true;
          host->failureCode = hr;

          host_log(
            host,
            "ICoreWebView2Environment3 unavailable"
          );

          return S_OK;
        }

        hr =
          create_composition_surface(
            host,
            host->foreignSurface,
            0
          );

        if (FAILED(hr)) {
          host->failed = true;
          host->failureCode = hr;
          return S_OK;
        }

        hr =
          create_composition_surface(
            host,
            host->shellSurface,
            1
          );

        if (FAILED(hr)) {
          host->failed = true;
          host->failureCode = hr;
        }

        return S_OK;
      }
    );

  const HRESULT hr =
    createEnvironment(
      nullptr,
      host->userDataFolder.empty()
        ? nullptr
        : host->userDataFolder.c_str(),
      nullptr,
      handler
    );

  handler->Release();

  return SUCCEEDED(hr);
}

void release_surface(
  GPWV2Surface& surface
) {
  if (
    surface.webview &&
    surface.messageToken.value != 0
  ) {
    surface.webview->remove_WebMessageReceived(
      surface.messageToken
    );
  }

  if (
    surface.webview &&
    surface.sourceToken.value != 0
  ) {
    surface.webview->remove_SourceChanged(
      surface.sourceToken
    );
  }

  if (surface.controller) {
    surface.controller->Close();
  }

  safe_release(
    surface.webview
  );
  safe_release(
    surface.controller
  );
  safe_release(
    surface.composition
  );
  safe_release(
    surface.visual
  );

  surface.ready = false;
}

void pump_pending_messages() {
  MSG message{};

  while (
    PeekMessageW(
      &message,
      nullptr,
      0,
      0,
      PM_REMOVE
    )
  ) {
    TranslateMessage(
      &message
    );
    DispatchMessageW(
      &message
    );
  }
}

extern "C" {

GPWV2Host* __cdecl gpwv2_create(
  const char* titleUtf8,
  const char* userDataFolderUtf8,
  int32_t width,
  int32_t height,
  GPWV2MessageCallback messageCallback,
  GPWV2SourceCallback sourceCallback,
  GPWV2LogCallback logCallback,
  void* userData
) {
  auto* host =
    new GPWV2Host();

  host_log(
    host,
    "bridge.gpwv2_create entry"
  );

  host->messageCallback =
    messageCallback;
  host->sourceCallback =
    sourceCallback;
  host->logCallback =
    logCallback;
  host->userData =
    userData;

  host->title =
    utf8_to_wide(
      titleUtf8
    );

  if (host->title.empty()) {
    host->title =
      L"GlaucoPlastic";
  }

  host->userDataFolder =
    utf8_to_wide(
      userDataFolderUtf8
    );

  host->width =
    std::max<int32_t>(
      320,
      width
    );

  host->height =
    std::max<int32_t>(
      240,
      height
    );

  const HRESULT comHr =
    CoInitializeEx(
      nullptr,
      COINIT_APARTMENTTHREADED
    );

  host_log(
    host,
    "bridge.gpwv2_create after CoInitializeEx"
  );

  host->comInitialized =
    SUCCEEDED(comHr) ||
    comHr == RPC_E_CHANGED_MODE;

  if (!register_window_class()) {
    host_log(
      host,
      "bridge.gpwv2_create register_window_class failed"
    );
    delete host;
    return nullptr;
  }

  host_log(
    host,
    "bridge.gpwv2_create register_window_class ok"
  );

  host->hwnd =
    CreateWindowExW(
      0,
      kWindowClassName,
      host->title.c_str(),
      WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      host->width,
      host->height,
      nullptr,
      nullptr,
      GetModuleHandleW(nullptr),
      host
    );

  if (!host->hwnd) {
    host_log(
      host,
      "bridge.gpwv2_create CreateWindowExW failed"
    );
    delete host;
    return nullptr;
  }

  host_log(
    host,
    "bridge.gpwv2_create window created"
  );

  if (
    !initialize_direct_composition(
      host
    )
  ) {
    host_log(
      host,
      "bridge.gpwv2_create initialize_direct_composition failed"
    );
    host->failed = true;
    host->failureCode = E_FAIL;
    return host;
  }

  host_log(
    host,
    "bridge.gpwv2_create direct composition ok"
  );

  if (
    !initialize_webview_environment(
      host
    )
  ) {
    host_log(
      host,
      "bridge.gpwv2_create initialize_webview_environment failed"
    );
    host->failed = true;
    host->failureCode = E_FAIL;
  }

  host_log(
    host,
    "bridge.gpwv2_create exit"
  );

  return host;
}

int32_t __cdecl gpwv2_wait_ready(
  GPWV2Host* host,
  int32_t timeoutMs
) {
  if (!host) {
    return 0;
  }

  const auto started =
    std::chrono::steady_clock::now();

  const int32_t safeTimeout =
    std::max<int32_t>(
      1000,
      timeoutMs
    );

  while (
    !host->ready &&
    !host->failed
  ) {
    pump_pending_messages();

    std::this_thread::sleep_for(
      std::chrono::milliseconds(5)
    );

    const auto elapsed =
      std::chrono::duration_cast<
        std::chrono::milliseconds
      >(
        std::chrono::steady_clock::now() -
        started
      ).count();

    if (elapsed >= safeTimeout) {
      host_log(
        host,
        "webview2.wait_ready timeout"
      );
      return 0;
    }
  }

  return host->ready ? 1 : 0;
}

int32_t __cdecl gpwv2_run(
  GPWV2Host* host
) {
  if (
    !host ||
    !host->hwnd ||
    !host->ready
  ) {
    return -1;
  }

  ShowWindow(
    host->hwnd,
    SW_SHOW
  );

  UpdateWindow(
    host->hwnd
  );

  SetForegroundWindow(
    host->hwnd
  );

  host->running =
    true;

  MSG message{};

  while (
    host->running &&
    GetMessageW(
      &message,
      nullptr,
      0,
      0
    ) > 0
  ) {
    TranslateMessage(
      &message
    );

    DispatchMessageW(
      &message
    );
  }

  return static_cast<int32_t>(
    message.wParam
  );
}

void __cdecl gpwv2_close(
  GPWV2Host* host
) {
  if (
    host &&
    host->hwnd
  ) {
    PostMessageW(
      host->hwnd,
      WM_CLOSE,
      0,
      0
    );
  }
}

void __cdecl gpwv2_destroy(
  GPWV2Host* host
) {
  if (!host) {
    return;
  }

  release_surface(
    host->shellSurface
  );

  release_surface(
    host->foreignSurface
  );

  safe_release(
    host->environment3
  );

  safe_release(
    host->environment
  );

  safe_release(
    host->rootVisual
  );

  safe_release(
    host->dcompTarget
  );

  safe_release(
    host->dcompDevice
  );

  safe_release(
    host->dxgiDevice
  );

  safe_release(
    host->d3dDevice
  );

  if (
    host->hwnd &&
    IsWindow(
      host->hwnd
    )
  ) {
    DestroyWindow(
      host->hwnd
    );
  }

  if (host->loaderModule) {
    FreeLibrary(
      host->loaderModule
    );
    host->loaderModule =
      nullptr;
  }

  if (host->comInitialized) {
    CoUninitialize();
  }

  delete host;
}

int32_t __cdecl gpwv2_shell_set_html(
  GPWV2Host* host,
  const char* htmlUtf8
) {
  if (
    !host ||
    !host->shellSurface.webview ||
    !htmlUtf8
  ) {
    return 0;
  }

  const std::wstring html =
    utf8_to_wide(
      htmlUtf8
    );

  return SUCCEEDED(
    host->shellSurface.webview->
      NavigateToString(
        html.c_str()
      )
  ) ? 1 : 0;
}

char* __cdecl gpwv2_shell_execute_sync(
  GPWV2Host* host,
  const char* scriptUtf8,
  int32_t timeoutMs
) {
  if (
    !host ||
    !host->shellSurface.webview ||
    !scriptUtf8
  ) {
    return nullptr;
  }

  struct ResultState {
    bool done = false;
    HRESULT hr = E_FAIL;
    std::string value;
  } state;

  const std::wstring script =
    utf8_to_wide(
      scriptUtf8
    );

  auto* handler =
    new ExecuteScriptCompletedHandler(
      [&state](
        HRESULT errorCode,
        LPCWSTR resultObjectAsJson
      ) -> HRESULT {
        state.hr =
          errorCode;

        state.value =
          wide_to_utf8(
            resultObjectAsJson
          );

        state.done =
          true;

        return S_OK;
      }
    );

  const HRESULT executeHr =
    host->shellSurface.webview->
      ExecuteScript(
        script.c_str(),
        handler
      );

  handler->Release();

  if (FAILED(executeHr)) {
    return nullptr;
  }

  const auto started =
    std::chrono::steady_clock::now();

  const int32_t safeTimeout =
    std::max<int32_t>(
      100,
      timeoutMs
    );

  while (!state.done) {
    pump_pending_messages();

    std::this_thread::sleep_for(
      std::chrono::milliseconds(1)
    );

    const auto elapsed =
      std::chrono::duration_cast<
        std::chrono::milliseconds
      >(
        std::chrono::steady_clock::now() -
        started
      ).count();

    if (elapsed >= safeTimeout) {
      return nullptr;
    }
  }

  if (FAILED(state.hr)) {
    return nullptr;
  }

  char* output =
    static_cast<char*>(
      std::malloc(
        state.value.size() + 1
      )
    );

  if (!output) {
    return nullptr;
  }

  std::memcpy(
    output,
    state.value.c_str(),
    state.value.size() + 1
  );

  return output;
}

int32_t __cdecl gpwv2_foreign_navigate(
  GPWV2Host* host,
  const char* urlUtf8
) {
  if (
    !host ||
    !host->foreignSurface.webview ||
    !urlUtf8
  ) {
    return 0;
  }

  const std::wstring url =
    utf8_to_wide(
      urlUtf8
    );

  return SUCCEEDED(
    host->foreignSurface.webview->
      Navigate(
        url.c_str()
      )
  ) ? 1 : 0;
}

int32_t __cdecl gpwv2_foreign_add_document_script(
  GPWV2Host* host,
  const char* scriptUtf8
) {
  if (
    !host ||
    !host->foreignSurface.webview ||
    !scriptUtf8
  ) {
    return 0;
  }

  const std::wstring script =
    utf8_to_wide(
      scriptUtf8
    );

  return SUCCEEDED(
    host->foreignSurface.webview->
      AddScriptToExecuteOnDocumentCreated(
        script.c_str(),
        nullptr
      )
  ) ? 1 : 0;
}

char* __cdecl gpwv2_foreign_execute_sync(
  GPWV2Host* host,
  const char* scriptUtf8,
  int32_t timeoutMs
) {
  if (
    !host ||
    !host->foreignSurface.webview ||
    !scriptUtf8
  ) {
    return nullptr;
  }

  struct ResultState {
    bool done = false;
    HRESULT hr = E_FAIL;
    std::string value;
  } state;

  const std::wstring script =
    utf8_to_wide(
      scriptUtf8
    );

  auto* handler =
    new ExecuteScriptCompletedHandler(
      [&state](
        HRESULT errorCode,
        LPCWSTR resultObjectAsJson
      ) -> HRESULT {
        state.hr =
          errorCode;

        state.value =
          wide_to_utf8(
            resultObjectAsJson
          );

        state.done =
          true;

        return S_OK;
      }
    );

  const HRESULT executeHr =
    host->foreignSurface.webview->
      ExecuteScript(
        script.c_str(),
        handler
      );

  handler->Release();

  if (FAILED(executeHr)) {
    return nullptr;
  }

  const auto started =
    std::chrono::steady_clock::now();

  const int32_t safeTimeout =
    std::max<int32_t>(
      100,
      timeoutMs
    );

  while (!state.done) {
    pump_pending_messages();

    std::this_thread::sleep_for(
      std::chrono::milliseconds(1)
    );

    const auto elapsed =
      std::chrono::duration_cast<
        std::chrono::milliseconds
      >(
        std::chrono::steady_clock::now() -
        started
      ).count();

    if (elapsed >= safeTimeout) {
      return nullptr;
    }
  }

  if (FAILED(state.hr)) {
    return nullptr;
  }

  char* output =
    static_cast<char*>(
      std::malloc(
        state.value.size() + 1
      )
    );

  if (!output) {
    return nullptr;
  }

  std::memcpy(
    output,
    state.value.c_str(),
    state.value.size() + 1
  );

  return output;
}

void __cdecl gpwv2_free_string(
  char* value
) {
  std::free(
    value
  );
}

void __cdecl gpwv2_set_foreign_bounds(
  GPWV2Host* host,
  int32_t x,
  int32_t y,
  int32_t width,
  int32_t height
) {
  if (!host) {
    return;
  }

  RECT bounds{
    x,
    y,
    x + std::max<int32_t>(1, width),
    y + std::max<int32_t>(1, height)
  };

  apply_surface_bounds(
    host,
    host->foreignSurface,
    bounds
  );
}

void __cdecl gpwv2_set_foreign_visible(
  GPWV2Host* host,
  int32_t visible
) {
  if (!host) {
    return;
  }

  host->foreignSurface.visible =
    visible != 0;

  if (host->foreignSurface.controller) {
    host->foreignSurface.controller->
      put_IsVisible(
        host->foreignSurface.visible
          ? TRUE
          : FALSE
      );
  }

  if (host->dcompDevice) {
    host->dcompDevice->Commit();
  }
}

void __cdecl gpwv2_set_foreign_input_regions(
  GPWV2Host* host,
  const GPWV2Rect* rects,
  int32_t count
) {
  if (!host) {
    return;
  }

  host->foreignInputRegions.clear();

  if (
    !rects ||
    count <= 0
  ) {
    return;
  }

  host->foreignInputRegions.reserve(
    static_cast<size_t>(
      count
    )
  );

  for (
    int32_t index = 0;
    index < count;
    ++index
  ) {
    const GPWV2Rect& item =
      rects[index];

    if (
      item.width <= 1 ||
      item.height <= 1
    ) {
      continue;
    }

    RECT rectangle{
      item.x,
      item.y,
      item.x + item.width,
      item.y + item.height
    };

    host->foreignInputRegions.push_back(
      rectangle
    );
  }
}

void __cdecl gpwv2_present(
  GPWV2Host* host
) {
  if (
    !host ||
    !host->hwnd
  ) {
    return;
  }

  ShowWindow(
    host->hwnd,
    SW_SHOW
  );

  UpdateWindow(
    host->hwnd
  );

  SetForegroundWindow(
    host->hwnd
  );
}

} // extern "C"
