#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include "flutter_window.h"
#include "utils.h"

// Windows AppUserModelID (the "package namespace" Win32 uses to group
// taskbar icons, route toast notifications, and populate jump lists).
// Must be set BEFORE the first top-level window is created - setting it
// afterwards leaves the first window grouped under the default identity
// (derived from the .exe name) and breaks per-window taskbar grouping
// for that instance. Keep this in sync with kAppAppUserModelId in
// lib/src/app_info.dart.
static const wchar_t* kAppUserModelId = L"com.sudo8.octodo";

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Pin the Windows AppUserModelID for this process. Returns S_OK on
  // success; failure here is non-fatal (Windows falls back to a derived
  // ID), so we deliberately don't bail.
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"octodo", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
