from __future__ import annotations

import shutil
import sys
from datetime import datetime
from pathlib import Path

FIELD_ANCHOR = '''      mainWebView*: pointer
'''
FIELD_REPLACEMENT = '''      mainWebView*: pointer
      compositedForeignPath*: string
      compositedShellInstalled*: bool
'''

FORWARD_ANCHOR = '''          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime)
'''
FORWARD_REPLACEMENT = '''          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime)
          proc syncPlasticCompositedApplicationShell(
            desktop: PlasticLinuxDesktopRuntime
          )
'''

UPDATE_STATUS_SIGNATURE = '''          proc updateForeignHostStatus(
            desktop: PlasticLinuxDesktopRuntime;
            path, status: string
          ) =
'''
UPDATE_STATUS_REPLACEMENT = '''          proc updateForeignHostStatus(
            desktop: PlasticLinuxDesktopRuntime;
            path, status: string
          ) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            let script = """
              (() => {
                const path = """ & $(%path) & """;
                const status = """ & $(%status) & """;
                const root =
                  window.__glaucoplasticShellRoot ||
                  document;
                const element = Array.from(
                  root.querySelectorAll('[data-glauco-foreign]')
                ).find(item => item.dataset.glaucoForeign === path);
                if (element) element.dataset.status = status;
                return true;
              })()
            """
            executeNativeJsAsync(desktop.mainWebView, script)

'''

MAIN_TERMINATED_SIGNATURE = '''          proc onPlasticMainWebProcessTerminated(
            webView: pointer;
            reason: cint;
            userData: pointer
          ) {.cdecl.} =
'''
MAIN_TERMINATED_REPLACEMENT = '''          proc onPlasticMainWebProcessTerminated(
            webView: pointer;
            reason: cint;
            userData: pointer
          ) {.cdecl.} =
            plasticUiTrace("web-process-terminated")
            let desktop =
              cast[PlasticLinuxDesktopRuntime](userData)

            stderr.writeLine(
              "[GlaucoPlastic] WebKit principal terminou, reason=" &
              $reason
            )

            if desktop.isNil or not desktop.running:
              return

            let path = desktop.compositedForeignPath
            if path.len > 0 and
                desktop.application.foreignValue.elements.hasKey(path):
              let element =
                desktop.application.foreignValue.elements[path]
              let targetUrl =
                if element.currentUrl.len > 0:
                  element.currentUrl
                else:
                  element.url
              if targetUrl.len > 0:
                webkit_web_view_load_uri(
                  desktop.mainWebView,
                  targetUrl.cstring
                )
                return

            desktop.reloadLinuxDesktop()

'''

URI_CHANGED_SIGNATURE = '''          proc onPlasticForeignUriChanged(
            webView, parameterSpec, userData: pointer
          ) {.cdecl.} =
'''
URI_CHANGED_REPLACEMENT = '''          proc onPlasticForeignUriChanged(
            webView, parameterSpec, userData: pointer
          ) {.cdecl.} =
            let element = cast[PlasticForeignElementRuntime](userData)
            if element.isNil:
              return

            let currentUri = webkit_web_view_get_uri(webView)
            if currentUri.isNil:
              return

            let desktop = cast[PlasticLinuxDesktopRuntime](element.desktopOwner)
            # A URL pertence ao mesmo documento que hospeda o shell.
            if not desktop.isNil:
              desktop.application.foreignValue.notifyUrlChanged(
                element.path,
                $currentUri
              )

'''

LOAD_CHANGED_SIGNATURE = '''          proc onPlasticForeignLoadChanged(
            webView: pointer;
            loadEvent: cint;
            userData: pointer
          ) {.cdecl.} =
'''
LOAD_CHANGED_REPLACEMENT = '''          proc onPlasticForeignLoadChanged(
            webView: pointer;
            loadEvent: cint;
            userData: pointer
          ) {.cdecl.} =
            let element = cast[PlasticForeignElementRuntime](userData)
            if element.isNil:
              return

            let desktop =
              cast[PlasticLinuxDesktopRuntime](element.desktopOwner)

            case loadEvent
            of 0:
              element.status = pfsLoading
              if not desktop.isNil:
                desktop.compositedShellInstalled = false
              plasticDebugTrace(
                "foreign.loadChanged loading path=" & element.path &
                " uri=" & $webkit_web_view_get_uri(webView)
              )
              if not element.eventHandler.isNil:
                element.eventHandler(element.path, "loading")
            of 2:
              # O documento externo já existe. Instala o shell antes do
              # término visual da navegação para reduzir o flash da página.
              if not desktop.isNil:
                desktop.syncPlasticCompositedApplicationShell()
            of 3:
              element.status = pfsReady
              plasticDebugTrace(
                "foreign.loadChanged ready path=" & element.path &
                " uri=" & $webkit_web_view_get_uri(webView)
              )
              if not desktop.isNil:
                desktop.syncPlasticCompositedApplicationShell()
                desktop.updateForeignHostStatus(element.path, "ready")
              if not element.eventHandler.isNil:
                element.eventHandler(element.path, "loaded")
            else:
              discard

'''

CREATE_START = '''            result.create = proc(element: PlasticForeignElementRuntime) =
'''
CREATE_END = '''            proc plasticNavigateRequestCompleted(
'''
CREATE_REPLACEMENT = '''            result.create = proc(element: PlasticForeignElementRuntime) =
              if not element.nativeHandle.isNil:
                return

              if desktop.mainWebView.isNil:
                raise newException(
                  PlasticForeignBackendError,
                  "WebView principal ainda não foi criado"
                )

              if desktop.compositedForeignPath.len > 0 and
                  desktop.compositedForeignPath != element.path:
                raise newException(
                  PlasticForeignBackendError,
                  "A composição em uma única WebView aceita um foreign " &
                  "principal por janela. Já está ativo: " &
                  desktop.compositedForeignPath
                )

              desktop.compositedForeignPath = element.path
              desktop.compositedShellInstalled = false
              element.nativeHandle = desktop.mainWebView
              element.nativeContainer = nil
              element.desktopOwner = cast[pointer](desktop)
              element.status = pfsIdle

              let manager =
                webkit_web_view_get_user_content_manager(
                  desktop.mainWebView
                )
              if manager.isNil:
                raise newException(
                  PlasticForeignBackendError,
                  "WebKitGTK não forneceu o gerenciador de conteúdo " &
                  "da WebView composta"
                )

              discard g_signal_connect_data(
                desktop.mainWebView,
                "load-changed",
                cast[pointer](onPlasticForeignLoadChanged),
                cast[pointer](element),
                nil,
                0
              )
              discard g_signal_connect_data(
                desktop.mainWebView,
                "notify::uri",
                cast[pointer](onPlasticForeignUriChanged),
                cast[pointer](element),
                nil,
                0
              )

              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                plasticUiTrace(
                  "foreign.composition single-webview path=" &
                  element.path
                )

            proc plasticNavigateRequestCompleted(
'''

PLACE_SIGNATURE = '''          proc placePlasticForeignBelowApplication(
            desktop: PlasticLinuxDesktopRuntime;
            element: PlasticForeignElementRuntime
          ) =
'''
PLACE_REPLACEMENT = '''          proc placePlasticForeignBelowApplication(
            desktop: PlasticLinuxDesktopRuntime;
            element: PlasticForeignElementRuntime
          ) =
            # A página foreign e o shell pertencem à mesma WebKitWebView.
            # Não existe ordem nativa entre superfícies GTK para ajustar.
            discard desktop
            discard element

'''

SURFACE_SIGNATURE = '''          proc syncPlasticForeignSurfaceGeometry(
            desktop: PlasticLinuxDesktopRuntime;
            element: PlasticForeignElementRuntime;
            x, y, width, height: int
          ) =
'''
SURFACE_REPLACEMENT = '''          proc syncPlasticForeignSurfaceGeometry(
            desktop: PlasticLinuxDesktopRuntime;
            element: PlasticForeignElementRuntime;
            x, y, width, height: int
          ) =
            # O foreign ocupa o documento principal inteiro. O placeholder
            # existe somente para organizar o shell no DOM injetado.
            discard desktop
            discard element
            discard x
            discard y
            discard width
            discard height

'''

SHOW_SIGNATURE = '''          proc showPlasticForeignSurface(
            element: PlasticForeignElementRuntime
          ) =
'''
SHOW_REPLACEMENT = '''          proc showPlasticForeignSurface(
            element: PlasticForeignElementRuntime
          ) =
            if element.isNil or element.nativeHandle.isNil:
              return
            gtk_widget_show(element.nativeHandle)

'''

HIDE_SIGNATURE = '''          proc hidePlasticForeignSurface(
            element: PlasticForeignElementRuntime
          ) =
'''
HIDE_REPLACEMENT = '''          proc hidePlasticForeignSurface(
            element: PlasticForeignElementRuntime
          ) =
            # Ocultar o placeholder não pode ocultar a WebView única.
            discard element

'''

SYNC_GEOMETRY_SIGNATURE = '''          proc syncPlasticForeignGeometry(data: pointer): cint {.cdecl.} =
'''
SYNC_GEOMETRY_REPLACEMENT = '''          proc syncPlasticForeignGeometry(data: pointer): cint {.cdecl.} =
            let desktop = cast[PlasticLinuxDesktopRuntime](data)
            if desktop.isNil or not desktop.running or
                desktop.mainWebView.isNil:
              return 0

            # A composição agora é DOM dentro da própria página foreign.
            # O timer permanece somente para transportar eventos e snapshots.
            desktop.drainPlasticUiEvents()
            desktop.publishPlasticAssistantSnapshot()
            return 1

'''

DESTROY_SIGNATURE = '''          proc onPlasticWindowDestroyed(widget, userData: pointer) {.cdecl.} =
'''
DESTROY_REPLACEMENT = '''          proc onPlasticWindowDestroyed(widget, userData: pointer) {.cdecl.} =
            plasticUiTrace("window-destroyed")
            let desktop = cast[PlasticLinuxDesktopRuntime](userData)
            if not desktop.isNil:
              closeWebKitDeveloperTools(desktop.mainWebView)
              desktop.running = false
              for _, element in desktop.application.foreignValue.elements:
                element.nativeContainer = nil
                element.nativeHandle = nil
                element.status = pfsClosed
              if not desktop.consoleReplState.isNil:
                desktop.consoleReplState.running = false
              desktop.application.uiPropertyWriterValue = nil
              if not desktop.assistantOverlayWebView.isNil:
                gtk_widget_hide(desktop.assistantOverlayWebView)
              if not desktop.assistantOverlayWindow.isNil:
                gtk_widget_destroy(desktop.assistantOverlayWindow)
              desktop.assistantOverlayWindow = nil
              desktop.assistantOverlayWebView = nil
            gtk_main_quit()

'''

UNMAP_SIGNATURE = '''          proc onPlasticWindowUnmapped(widget, userData: pointer) {.cdecl.} =
'''
UNMAP_REPLACEMENT = '''          proc onPlasticWindowUnmapped(widget, userData: pointer) {.cdecl.} =
            plasticUiTrace("window-unmapped")
            # A WebView única é ocultada e restaurada pelo próprio GtkWindow.
            let desktop =
              cast[PlasticLinuxDesktopRuntime](userData)
            if not desktop.isNil and
                not desktop.assistantOverlayWindow.isNil:
              gtk_widget_hide(
                desktop.assistantOverlayWindow
              )

'''

SET_PROPERTY_SIGNATURE = '''          proc setDesktopIdentityProperty(
            desktop: PlasticLinuxDesktopRuntime;
            path, propertyName: string;
            value: JsonNode
          ) =
'''
SET_PROPERTY_REPLACEMENT = '''          proc setDesktopIdentityProperty(
            desktop: PlasticLinuxDesktopRuntime;
            path, propertyName: string;
            value: JsonNode
          ) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            let script = """
              (() => {
                const path = """ & $(%path) & """;
                const propertyName = """ & $(%propertyName) & """;
                const value = """ & $value & """;
                const root =
                  window.__glaucoplasticShellRoot ||
                  document;
                const element = Array.from(
                  root.querySelectorAll('[data-glauco-identity]')
                ).find(item => item.dataset.glaucoIdentity === path);
                if (!element) return false;
                if (propertyName === 'textContent' || propertyName === 'innerHTML') {
                  element[propertyName] = typeof value === 'string'
                    ? value
                    : JSON.stringify(value);
                } else {
                  element[propertyName] = value;
                }
                return true;
              })()
            """
            executeNativeJsAsync(desktop.mainWebView, script)

'''

TRANSPARENT_SIGNATURE = '''          proc plasticTransparentApplicationHtml(
            html: string
          ): string =
'''

SHELL_HELPERS = r'''          proc plasticExtractHtmlScripts(
            html: string
          ): seq[string] =
            var cursor = 0
            while cursor < html.len:
              let openAt = html.find("<script", cursor)
              if openAt < 0:
                break
              let sourceAt = html.find(">", openAt)
              if sourceAt < 0:
                break
              let closeAt = html.find("</script>", sourceAt + 1)
              if closeAt < 0:
                break
              if closeAt > sourceAt + 1:
                result.add html[sourceAt + 1 ..< closeAt]
              cursor = closeAt + "</script>".len

          proc plasticCompositedShellJavaScript(
            desktop: PlasticLinuxDesktopRuntime
          ): string =
            if desktop.isNil:
              return ""

            let renderedHtml =
              plasticTransparentApplicationHtml(
                desktop.application.renderApplicationHtml()
              )
            let baseUri =
              "file://" &
              getCurrentDir().replace(" ", "%20") &
              "/"
            let scriptSources =
              plasticExtractHtmlScripts(renderedHtml)

            result = """
              (() => {
                const sourceHtml = """ & $(%renderedHtml) & """;
                const sourceBase = """ & $(%baseUri) & """;
                const parsed = new DOMParser().parseFromString(
                  sourceHtml,
                  'text/html'
                );

                parsed.querySelectorAll('script').forEach(node => {
                  node.remove();
                });

                const previous =
                  window.__glaucoplasticShellHost ||
                  document.getElementById('__glaucoplastic-shell-host');
                if (previous) previous.remove();

                const host = document.createElement('div');
                host.id = '__glaucoplastic-shell-host';
                host.style.position = 'fixed';
                host.style.inset = '0';
                host.style.width = '100vw';
                host.style.height = '100dvh';
                host.style.zIndex = '2147483647';
                host.style.pointerEvents = 'none';
                host.style.background = 'transparent';
                host.style.overflow = 'visible';
                host.style.contain = 'layout style';

                const root = host.attachShadow({mode: 'open'});
                const shellBody = document.createElement('div');
                shellBody.id = '__glaucoplastic-shell-body';
                shellBody.style.position = 'absolute';
                shellBody.style.inset = '0';
                shellBody.style.width = '100%';
                shellBody.style.height = '100%';
                shellBody.style.pointerEvents = 'none';
                shellBody.style.background = 'transparent';
                shellBody.style.overflow = 'visible';
                shellBody.style.fontFamily =
                  'system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif';
                shellBody.style.color = '#0f172a';

                const css = [
                  ':host { all: initial; color-scheme: light dark; }',
                  '#__glaucoplastic-shell-body { box-sizing: border-box; }',
                  '#__glaucoplastic-shell-body *,',
                  '#__glaucoplastic-shell-body *::before,',
                  '#__glaucoplastic-shell-body *::after { box-sizing: border-box; }',
                  '#glaucoplastic-application {',
                  '  position: fixed !important;',
                  '  inset: 0 !important;',
                  '  z-index: 2147483647 !important;',
                  '  width: 100vw !important;',
                  '  height: 100dvh !important;',
                  '  pointer-events: none;',
                  '  background: transparent !important;',
                  '}',
                  '.glauco-foreign, [data-glauco-foreign] {',
                  '  visibility: hidden !important;',
                  '  opacity: 0 !important;',
                  '  pointer-events: none !important;',
                  '  background: transparent !important;',
                  '}',
                  Array.from(parsed.head.querySelectorAll('style'))
                    .map(node => node.textContent || '')
                    .join('\\n')
                ].join('\\n');

                if (
                  typeof CSSStyleSheet !== 'undefined' &&
                  'adoptedStyleSheets' in root &&
                  CSSStyleSheet.prototype.replaceSync
                ) {
                  try {
                    const sheet = new CSSStyleSheet();
                    sheet.replaceSync(css);
                    root.adoptedStyleSheets = [sheet];
                  } catch (_) {
                    const style = document.createElement('style');
                    style.textContent = css;
                    root.appendChild(style);
                  }
                } else {
                  const style = document.createElement('style');
                  style.textContent = css;
                  root.appendChild(style);
                }

                for (const sourceLink of parsed.head.querySelectorAll(
                  'link[rel="stylesheet"]'
                )) {
                  const href = sourceLink.getAttribute('href') || '';
                  if (!href) continue;
                  const link = document.createElement('link');
                  link.rel = 'stylesheet';
                  try {
                    link.href = new URL(href, sourceBase).href;
                  } catch (_) {
                    link.href = href;
                  }
                  root.appendChild(link);
                }

                const sourceApplication =
                  parsed.getElementById('glaucoplastic-application');

                if (sourceApplication) {
                  for (const node of sourceApplication.querySelectorAll(
                    '[src],[href],[poster],[action]'
                  )) {
                    for (const attribute of ['src', 'href', 'poster', 'action']) {
                      if (!node.hasAttribute(attribute)) continue;
                      const value = node.getAttribute(attribute) || '';
                      if (!value || value.startsWith('#') ||
                          value.startsWith('data:') ||
                          value.startsWith('javascript:')) continue;
                      try {
                        node.setAttribute(
                          attribute,
                          new URL(value, sourceBase).href
                        );
                      } catch (_) {}
                    }
                  }
                  shellBody.innerHTML = sourceApplication.outerHTML;
                } else {
                  shellBody.innerHTML = parsed.body.innerHTML;
                }

                root.appendChild(shellBody);
                document.documentElement.appendChild(host);

                const escapeIdentifier = value => {
                  const text = String(value);
                  if (window.CSS && CSS.escape) return CSS.escape(text);
                  return text.replace(/[^a-zA-Z0-9_-]/g, character =>
                    '\\' + character
                  );
                };

                const shellDocument = new Proxy(document, {
                  get(target, property) {
                    if (property === 'body' || property === 'documentElement') {
                      return shellBody;
                    }
                    if (property === 'head') return root;
                    if (property === 'getElementById') {
                      return identifier => root.querySelector(
                        '#' + escapeIdentifier(identifier)
                      );
                    }
                    if (property === 'querySelector') {
                      return selector => root.querySelector(selector);
                    }
                    if (property === 'querySelectorAll') {
                      return selector => root.querySelectorAll(selector);
                    }
                    if (property === 'addEventListener') {
                      return root.addEventListener.bind(root);
                    }
                    if (property === 'removeEventListener') {
                      return root.removeEventListener.bind(root);
                    }
                    if (property === 'dispatchEvent') {
                      return root.dispatchEvent.bind(root);
                    }
                    const value = Reflect.get(target, property, target);
                    return typeof value === 'function'
                      ? value.bind(target)
                      : value;
                  }
                });

                window.__glaucoplasticShellHost = host;
                window.__glaucoplasticShellRoot = root;
                window.__glaucoplasticShellBody = shellBody;
                window.__glaucoplasticShellDocument = shellDocument;
                window.__glaucoplasticForeignLayoutObserverInstalled = true;
                window.__glaucoplasticForeignLayoutScheduled = false;
                window.__glaucoplasticForeignLayoutSnapshot = [];

                const application = root.querySelector(
                  '#glaucoplastic-application'
                );
                if (application) {
                  application.style.pointerEvents = 'none';
                }

                for (const foreign of root.querySelectorAll(
                  '[data-glauco-foreign]'
                )) {
                  foreign.style.visibility = 'hidden';
                  foreign.style.opacity = '0';
                  foreign.style.pointerEvents = 'none';

                  let branch = foreign;
                  while (
                    branch &&
                    branch !== application &&
                    branch !== shellBody
                  ) {
                    branch.style.pointerEvents = 'none';
                    const parent = branch.parentElement;
                    if (!parent) break;
                    for (const sibling of parent.children) {
                      if (sibling !== branch) {
                        sibling.style.pointerEvents = 'auto';
                      }
                    }
                    branch = parent;
                  }
                }

                for (const overlay of root.querySelectorAll([
                  '.rpa-topbar',
                  '.rpa-sidebar',
                  '.rpa-chat-panel',
                  '.rpa-message-list',
                  '.rpa-composer-shell',
                  '.assistant-sidebar',
                  '.assistant-header',
                  '.assistant-messages',
                  '.assistant-composer-shell',
                  '[data-glaucoplastic-foreign-overlay]'
                ].join(','))) {
                  overlay.style.pointerEvents = 'auto';
                }

                return true;
              })();
            """

            for source in scriptSources:
              if source.strip.len == 0:
                continue
              result.add """
                (() => {
                  const document =
                    window.__glaucoplasticShellDocument ||
                    window.document;
              """
              result.add source
              result.add """
                })();
              """

          proc syncPlasticCompositedApplicationShell(
            desktop: PlasticLinuxDesktopRuntime
          ) =
            if desktop.isNil or desktop.mainWebView.isNil or
                desktop.compositedForeignPath.len == 0:
              return

            let script =
              desktop.plasticCompositedShellJavaScript()
            if script.len == 0:
              return

            try:
              executeNativeJsAsync(
                desktop.mainWebView,
                script
              )
              desktop.compositedShellInstalled = true
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                plasticUiTrace(
                  "foreign.shell injected path=" &
                  desktop.compositedForeignPath &
                  " htmlLen=" &
                  $desktop.application.renderApplicationHtml().len
                )
            except CatchableError as error:
              desktop.compositedShellInstalled = false
              if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
                plasticUiTrace(
                  "foreign.shell injection failed: " &
                  error.msg
                )

'''

RELOAD_SIGNATURE = '''          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime) =
'''
RELOAD_REPLACEMENT = '''          proc reloadLinuxDesktop(desktop: PlasticLinuxDesktopRuntime) =
            if desktop.isNil or desktop.mainWebView.isNil:
              return
            if not desktop.application.assistantValue.isNil:
              acquire(desktop.application.assistantValue.dataLock)
              desktop.application.assistantValue.publishedRevision = -1
              release(desktop.application.assistantValue.dataLock)

            if desktop.compositedForeignPath.len > 0:
              desktop.syncPlasticCompositedApplicationShell()
              return

            let html =
              plasticTransparentApplicationHtml(
                desktop.application.renderApplicationHtml()
              )
            if plasticEnvEnabled("GLAUCOPLASTIC_UI_DEBUG"):
              plasticUiTrace(
                "reloadLinuxDesktop htmlLen=" & $html.len &
                " composition=local"
              )
            let baseUri = "file://" & getCurrentDir().replace(" ", "%20") & "/"
            webkit_web_view_load_html(
              desktop.mainWebView,
              html.cstring,
              baseUri.cstring
            )

'''

CLOSE_OLD = '''            result.close = proc(element: PlasticForeignElementRuntime) =
              if not element.nativeHandle.isNil:
                gtk_widget_destroy(
                  element.nativeHandle
                )
                element.nativeHandle = nil
              element.nativeContainer = nil
              element.status = pfsClosed
'''
CLOSE_NEW = '''            result.close = proc(element: PlasticForeignElementRuntime) =
              if element.isNil:
                return
              element.nativeHandle = nil
              element.nativeContainer = nil
              element.status = pfsClosed
              if desktop.compositedForeignPath == element.path:
                desktop.compositedForeignPath = ""
                desktop.compositedShellInstalled = false
'''

NAV_PLACE_BLOCKS = (
'''                if not requestDesktop.isNil:
                  requestDesktop.placePlasticForeignBelowApplication(
                    request.element
                  )

''',
'''                desktop.placePlasticForeignBelowApplication(
                  element
                )
''',
)

DRAIN_TOGGLE_OLD = '''                    "(() => { const toggle = " &
                      "document.getElementById('rpa-chat-toggle'); " &
                      "if (toggle) { toggle.checked = true; " &
'''
DRAIN_TOGGLE_NEW = '''                    "(() => { const root = " &
                      "window.__glaucoplasticShellRoot || document; " &
                      "const toggle = root.querySelector('#rpa-chat-toggle'); " &
                      "if (toggle) { toggle.checked = true; " &
'''


CUSTOM_ELEMENTS_QUERY_OLD = """                const items = Array.from(
                  document.querySelectorAll('[data-glauco-identity]')
                );
"""
CUSTOM_ELEMENTS_QUERY_NEW = """                const root =
                  window.__glaucoplasticShellRoot ||
                  document;
                const items = Array.from(
                  root.querySelectorAll('[data-glauco-identity]')
                );
"""

BOOT_FINALIZE_QUERY_OLD = """                const items = Array.from(
                  document.querySelectorAll('[data-glauco-identity]')
                );
"""
BOOT_FINALIZE_QUERY_NEW = """                const shellRoot =
                  window.__glaucoplasticShellRoot ||
                  document;
                const items = Array.from(
                  shellRoot.querySelectorAll('[data-glauco-identity]')
                );
"""

STARTUP_OLD = '''                plasticUiTrace("startup: after executeProgram")
                desktop.reloadLinuxDesktop()
                plasticUiTrace("startup: after reload")

                for path in app.foreignValue.elements.keys.toSeq.sorted:
                  app.foreignValue.create(path)
                plasticUiTrace("startup: after foreign create")
'''
STARTUP_NEW = '''                plasticUiTrace("startup: after executeProgram")

                for path in app.foreignValue.elements.keys.toSeq.sorted:
                  app.foreignValue.create(path)
                plasticUiTrace("startup: after foreign create")

                desktop.reloadLinuxDesktop()
                plasticUiTrace("startup: after reload")
'''

ENV_OLD = '''            if application.webViewValue.safeGraphics or
                backend == "x11" or problematicWaylandEnvironment:
              putEnv("GLAUCOPLASTIC_DISABLE_DMABUF", "1")
              putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
              putEnv("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
              putEnv("LIBGL_ALWAYS_SOFTWARE", "1")
'''
ENV_NEW = '''            if application.webViewValue.safeGraphics or
                backend == "x11":
              putEnv("GLAUCOPLASTIC_DISABLE_DMABUF", "1")
              putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
              putEnv("WEBKIT_DISABLE_COMPOSITING_MODE", "1")
              putEnv("LIBGL_ALWAYS_SOFTWARE", "1")
            elif problematicWaylandEnvironment:
              # Em Wayland, a composição permanece ativa porque página e
              # shell pertencem à mesma WebKitWebView. Desativa somente DMABUF.
              putEnv("GLAUCOPLASTIC_DISABLE_DMABUF", "1")
              putEnv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
              delEnv("WEBKIT_DISABLE_COMPOSITING_MODE")
              delEnv("LIBGL_ALWAYS_SOFTWARE")
'''

SELECT_OLD = '''            var selectedBackend = ""
            if hasX11:
              selectedBackend = "x11"
            elif hasWayland:
              selectedBackend = "wayland"
'''
SELECT_NEW = '''            var selectedBackend = ""
            if hasWayland and
                getEnv("XDG_SESSION_TYPE").toLowerAscii == "wayland":
              selectedBackend = "wayland"
            elif hasX11:
              selectedBackend = "x11"
            elif hasWayland:
              selectedBackend = "wayland"
'''


def backup(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = path.with_name(path.name + f".backup-single-webview-{stamp}")
    shutil.copy2(path, target)
    return target


def proc_range(text: str, signature: str) -> tuple[int, int]:
    start = text.find(signature)
    if start < 0:
        raise RuntimeError("Procedimento não encontrado: " + signature.strip().splitlines()[0])
    indent = signature.split("proc ", 1)[0].splitlines()[-1]
    cursor = start + len(signature)
    marker = indent + "proc "
    while cursor < len(text):
        end = text.find("\n", cursor)
        if end < 0:
            end = len(text)
        line = text[cursor:end]
        if line.startswith(marker):
            return start, cursor
        if end >= len(text):
            break
        cursor = end + 1
    return start, len(text)


def replace_proc(text: str, signature: str, replacement: str, marker: str, label: str) -> str:
    start, end = proc_range(text, signature)
    current = text[start:end]
    if marker in current:
        print(f"[ok] {label}")
        return text
    print(f"[fix] {label}")
    return text[:start] + replacement + text[end:]


def replace_exact(text: str, old: str, new: str, label: str, optional: bool = False) -> str:
    if new in text:
        print(f"[ok] {label}")
        return text
    if old not in text:
        if optional:
            print(f"[skip] {label}")
            return text
        raise RuntimeError(f"Bloco não encontrado: {label}")
    print(f"[fix] {label}")
    return text.replace(old, new, 1)


def insert_shell_helpers(text: str) -> str:
    if "          proc plasticCompositedShellJavaScript(\n" in text:
        print("[ok] compositor DOM da WebView única")
        return text
    start, end = proc_range(text, TRANSPARENT_SIGNATURE)
    print("[fix] compositor DOM da WebView única")
    return text[:end] + SHELL_HELPERS + text[end:]


def replace_create(text: str) -> str:
    if "foreign.composition single-webview path=" in text:
        print("[ok] backend foreign usa a WebView principal")
        return text
    start = text.find(CREATE_START)
    if start < 0:
        raise RuntimeError("result.create do backend foreign não encontrado")
    end = text.find(CREATE_END, start)
    if end < 0:
        raise RuntimeError("fim de result.create não encontrado")
    print("[fix] backend foreign usa a WebView principal")
    return text[:start] + CREATE_REPLACEMENT + text[end + len(CREATE_END):]


def validate(text: str) -> None:
    required = (
        "compositedForeignPath*: string",
        "proc plasticCompositedShellJavaScript(",
        "foreign.composition single-webview path=",
        "foreign.shell injected path=",
        "window.__glaucoplasticShellRoot",
        "const shellRoot =",
        "host.attachShadow({mode: 'open'})",
        "element.nativeHandle = desktop.mainWebView",
        "A composição em uma única WebView aceita um foreign",
        "composition=local",
        "selectedBackend = \"wayland\"",
    )
    missing = [item for item in required if item not in text]
    if missing:
        raise RuntimeError("Validação final falhou. Ausentes: " + ", ".join(missing))
    forbidden = (
        "let webView =\n                if desktop.webContext.isNil",
        "gtk_fixed_put(\n                desktop.fixed,\n                webView,",
        "foreign.stack shared-fixed-main-above",
        "desktop.schedulePlasticAssistantOverlayAfterForeignLoad(\n                \"uri-changed:",
        "for _, element in\n                  desktop.application.foreignValue.elements:\n                if not element.nativeHandle.isNil:\n                  gtk_widget_hide",
    )
    leftovers = [item for item in forbidden if item in text]
    if leftovers:
        raise RuntimeError("Composição nativa antiga ainda presente: " + ", ".join(leftovers))


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Uso: {Path(sys.argv[0]).name} /caminho/do/glaucoplastic", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).expanduser().resolve()
    source = root if root.is_file() else root / "src" / "glaucoplastic.nim"
    if not source.is_file():
        raise SystemExit(f"Arquivo não encontrado: {source}")
    original = source.read_text(encoding="utf-8")
    text = original

    text = replace_exact(text, FIELD_ANCHOR, FIELD_REPLACEMENT, "estado da composição")
    text = replace_exact(text, FORWARD_ANCHOR, FORWARD_REPLACEMENT, "declaração do sincronizador")
    text = replace_proc(text, UPDATE_STATUS_SIGNATURE, UPDATE_STATUS_REPLACEMENT, "__glaucoplasticShellRoot", "status no shell")
    text = replace_proc(text, MAIN_TERMINATED_SIGNATURE, MAIN_TERMINATED_REPLACEMENT, "compositedForeignPath", "recuperação do processo WebKit")
    text = replace_proc(text, URI_CHANGED_SIGNATURE, URI_CHANGED_REPLACEMENT, "A URL pertence ao mesmo documento que hospeda o shell", "URL do foreign composto")
    text = replace_proc(text, LOAD_CHANGED_SIGNATURE, LOAD_CHANGED_REPLACEMENT, "syncPlasticCompositedApplicationShell", "injeção após navegação")
    text = replace_create(text)

    for old in NAV_PLACE_BLOCKS:
        if old in text:
            text = text.replace(old, "", 1)
            print("[fix] removido restack durante navegação")

    text = replace_exact(text, CLOSE_OLD, CLOSE_NEW, "fechamento do foreign composto")
    text = replace_proc(text, PLACE_SIGNATURE, PLACE_REPLACEMENT, "mesma WebKitWebView", "restack nativo removido")
    text = replace_proc(text, SURFACE_SIGNATURE, SURFACE_REPLACEMENT, "documento principal inteiro", "geometria nativa removida")
    text = replace_proc(text, SHOW_SIGNATURE, SHOW_REPLACEMENT, "gtk_widget_show(element.nativeHandle)", "exibição da WebView única")
    text = replace_proc(text, HIDE_SIGNATURE, HIDE_REPLACEMENT, "não pode ocultar a WebView única", "ocultação do placeholder")
    text = replace_proc(text, SYNC_GEOMETRY_SIGNATURE, SYNC_GEOMETRY_REPLACEMENT, "timer permanece somente", "timer de eventos")
    text = replace_proc(text, DESTROY_SIGNATURE, DESTROY_REPLACEMENT, "for _, element in desktop.application.foreignValue.elements:\n                element.nativeContainer = nil", "destruição sem duplicar WebView")
    text = replace_proc(text, UNMAP_SIGNATURE, UNMAP_REPLACEMENT, "A WebView única é ocultada e restaurada", "unmap da janela")
    text = replace_proc(text, SET_PROPERTY_SIGNATURE, SET_PROPERTY_REPLACEMENT, "__glaucoplasticShellRoot", "propriedades no Shadow DOM")
    text = insert_shell_helpers(text)
    text = replace_proc(text, RELOAD_SIGNATURE, RELOAD_REPLACEMENT, "compositedForeignPath.len > 0", "reload preserva a URL foreign")
    text = replace_exact(text, DRAIN_TOGGLE_OLD, DRAIN_TOGGLE_NEW, "toggle de conversas no shell", optional=True)
    text = replace_exact(text, CUSTOM_ELEMENTS_QUERY_OLD, CUSTOM_ELEMENTS_QUERY_NEW, "custom elements no shell", optional=True)
    text = replace_exact(text, BOOT_FINALIZE_QUERY_OLD, BOOT_FINALIZE_QUERY_NEW, "boot no shell", optional=True)
    text = replace_exact(text, STARTUP_OLD, STARTUP_NEW, "ordem de inicialização")
    text = replace_exact(text, ENV_OLD, ENV_NEW, "composição ativa no Wayland")
    text = replace_exact(text, SELECT_OLD, SELECT_NEW, "preferência pelo Wayland nativo")

    validate(text)
    if text == original:
        print("[ok] nenhuma alteração necessária")
        return 0
    backup_path = backup(source)
    source.write_text(text, encoding="utf-8")
    print(f"[backup] {backup_path}")
    print(f"[write] {source}")
    print("[ok] foreign e shell agora usam uma única WebKitWebView")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
