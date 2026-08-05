when defined(linux):
  const GtkLib = "libgtk-3.so(|.0)"

  proc gtk_init_check(argc: pointer; argv: pointer): cint
    {.cdecl, importc, dynlib: GtkLib.}
  proc gtk_window_new(windowType: cint): pointer
    {.cdecl, importc, dynlib: GtkLib.}
  proc gtk_window_set_title(window: pointer; title: cstring)
    {.cdecl, importc, dynlib: GtkLib.}
  proc gtk_window_set_default_size(window: pointer; width, height: cint)
    {.cdecl, importc, dynlib: GtkLib.}
  proc gtk_widget_show_all(widget: pointer)
    {.cdecl, importc, dynlib: GtkLib.}
  proc gtk_main()
    {.cdecl, importc, dynlib: GtkLib.}

  if gtk_init_check(nil, nil) == 0:
    quit("gtk_init_check failed", 1)

  let window = gtk_window_new(0)
  if window.isNil:
    quit("gtk_window_new failed", 2)

  gtk_window_set_title(window, "GlaucoPlastic GTK Probe")
  gtk_window_set_default_size(window, 640, 360)
  gtk_widget_show_all(window)
  gtk_main()
else:
  quit("probe only supports linux", 1)
