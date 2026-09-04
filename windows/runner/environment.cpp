#include "environment.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <userenv.h>

#include <string>

// CreateEnvironmentBlock (userenv.lib) rebuilds the environment the
// way a freshly logged-on process for the current user would see it:
// HKLM Session Manager Environment + HKCU Environment (PATH becomes
// system PATH + user PATH), REG_EXPAND_SZ values expanded, plus —
// with bInherit=TRUE — the volatile per-session variables
// (SESSIONNAME, TEMP, …) carried over from the calling process.
// Registry-defined names always come from the registry, which is
// exactly what "latest env" means here. This is also how Windows
// Terminal refreshes the environment for new tabs.

namespace octodo {

namespace {

std::string WideToUtf8(const std::wstring& ws) {
  if (ws.empty()) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, ws.data(), (int)ws.size(),
                                nullptr, 0, nullptr, nullptr);
  std::string out(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws.data(), (int)ws.size(), out.data(),
                      len, nullptr, nullptr);
  return out;
}

flutter::EncodableValue BuildFreshEnvironment() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(),
                        TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE,
                        &token)) {
    return flutter::EncodableValue();
  }

  void* block = nullptr;
  if (!CreateEnvironmentBlock(&block, token, TRUE)) {
    CloseHandle(token);
    return flutter::EncodableValue();
  }
  CloseHandle(token);

  flutter::EncodableMap map;
  const wchar_t* cursor = static_cast<const wchar_t*>(block);
  while (*cursor != L'\0') {
    const wchar_t* eq = wcschr(cursor, L'=');
    // Entries with an empty or '='-prefixed name (the hidden
    // per-drive cwd vars like "=C:") are not real environment
    // variables — drop them.
    if (eq != nullptr && eq != cursor && cursor[0] != L'=') {
      std::wstring name(cursor, eq);
      std::wstring value(eq + 1);
      map[flutter::EncodableValue(WideToUtf8(name))] =
          flutter::EncodableValue(WideToUtf8(value));
    }
    cursor += wcslen(cursor) + 1;
  }

  DestroyEnvironmentBlock(block);
  return flutter::EncodableValue(map);
}

void OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "get") {
    result->Success(BuildFreshEnvironment());
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterEnvironmentChannel(flutter::FlutterEngine* engine) {
  auto* channel = new flutter::MethodChannel<flutter::EncodableValue>(
      engine->messenger(), "octodo/environment",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(OnMethodCall);
}

}  // namespace octodo
