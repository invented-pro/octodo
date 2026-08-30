#include "notifications.h"

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <Windows.UI.Notifications.h>
#include <flutter/encodable_value.h>
#include <objbase.h>
#include <propkey.h>
#include <propsys.h>
#include <roapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/implements.h>
#include <wrl/wrappers/corewrappers.h>

#include <cmath>
#include <string>

// WRL (Windows Runtime C++ Template Library) + the SDK's ABI headers
// — the classic "toast from a desktop Win32 app" path. No C++/WinRT
// NuGet package, no new pub deps; links only runtimeobject.lib (see
// CMakeLists.txt).

using ABI::Windows::Data::Xml::Dom::IXmlDocument;
using ABI::Windows::Data::Xml::Dom::IXmlNode;
using ABI::Windows::Data::Xml::Dom::IXmlNodeList;
using ABI::Windows::Data::Xml::Dom::IXmlText;
using ABI::Windows::UI::Notifications::IToastNotification;
using ABI::Windows::UI::Notifications::IToastNotification2;
using ABI::Windows::UI::Notifications::IToastNotificationFactory;
using ABI::Windows::UI::Notifications::IToastNotificationHistory;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics2;
using ABI::Windows::UI::Notifications::IToastNotifier;
using ABI::Windows::UI::Notifications::ToastNotification;
using ABI::Windows::UI::Notifications::ToastTemplateType;
using ABI::Windows::UI::Notifications::ToastTemplateType_ToastText02;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;

namespace octodo {

namespace {

// Mirrors kAppAppUserModelId (lib/src/app_info.dart), pinned to the
// process in main.cpp via SetCurrentProcessExplicitAppUserModelID
// BEFORE any window is created — toasts are attributed to that
// identity and grouped with the taskbar button.
constexpr wchar_t kAumid[] = L"com.sudo8.octodo";

// Activation message marshaling WinRT thread-pool threads → the UI
// thread. LPARAM is a heap std::wstring (the toast tag / Dart id)
// owned by the receiver.
constexpr UINT kActivationMessage = WM_APP + 0x4F;

flutter::MethodChannel<flutter::EncodableValue>* g_channel = nullptr;
HWND g_hwnd = nullptr;
ITaskbarList3* g_taskbar = nullptr;
HICON g_dot_icon = nullptr;

std::wstring EncodableToString(const flutter::EncodableValue* v) {
  if (!v || !std::holds_alternative<std::string>(*v)) return L"";
  const auto& s = std::get<std::string>(*v);
  if (s.empty()) return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring out(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), len);
  return out;
}

// EncodableValue carries UTF-8 std::string, not wstring.
std::string WideStringToUtf8(const std::wstring& ws) {
  if (ws.empty()) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, ws.data(), (int)ws.size(),
                                nullptr, 0, nullptr, nullptr);
  std::string out(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, ws.data(), (int)ws.size(), out.data(),
                      len, nullptr, nullptr);
  return out;
}

// HSTRING for the AUMID constant. Two-arg constructor form — the
// single-arg array template is explicit and does not bind a
// constexpr pointer.
HStringReference AumidRef() {
  return HStringReference(
      kAumid, (UINT32)(sizeof(kAumid) / sizeof(kAumid[0]) - 1));
}

// Windows only displays toasts posted under an AUMID when that AUMID
// resolves to a Start Menu shortcut carrying
// System.AppUserModel.ID (or to a packaged app identity). Unpackaged
// dev builds have no installer to make one, and Windows then drops
// every toast silently — so the runner maintains the shortcut itself:
// created when missing, repointed when the running exe moves (Debug ↔
// Release trees). Same approach as Microsoft's desktop-toast compat
// library. Best-effort — a failure here never blocks startup.
void EnsureAumidShortcut() {
  wchar_t exe[MAX_PATH] = {};
  if (!GetModuleFileNameW(nullptr, exe, MAX_PATH)) return;

  PWSTR programs_raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_DEFAULT,
                                  nullptr, &programs_raw)) ||
      !programs_raw) {
    return;
  }
  const std::wstring lnk =
      std::wstring(programs_raw) + L"\\Octodo.lnk";
  CoTaskMemFree(programs_raw);

  // Already pointing at this exe? Nothing to do.
  if (GetFileAttributesW(lnk.c_str()) != INVALID_FILE_ATTRIBUTES) {
    ComPtr<IPersistFile> reader;
    if (SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&reader))) &&
        reader && SUCCEEDED(reader->Load(lnk.c_str(), STGM_READ))) {
      ComPtr<IShellLinkW> existing;
      wchar_t target[MAX_PATH] = {};
      if (SUCCEEDED(reader.As(&existing)) && existing &&
          SUCCEEDED(existing->GetPath(target, MAX_PATH, nullptr,
                                      SLGP_RAWPATH)) &&
          _wcsicmp(target, exe) == 0) {
        return;
      }
    }
  }

  ComPtr<IShellLinkW> link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&link))) ||
      !link) {
    return;
  }
  link->SetPath(exe);
  link->SetDescription(L"Octodo");
  ComPtr<IPropertyStore> store;
  if (SUCCEEDED(link.As(&store)) && store) {
    PROPVARIANT pv = {};
    pv.vt = VT_LPWSTR;
    pv.pwszVal = const_cast<PWSTR>(kAumid);
    store->SetValue(PKEY_AppUserModel_ID, pv);
    store->Commit();
  }
  ComPtr<IPersistFile> file;
  if (SUCCEEDED(link.As(&file)) && file) {
    file->Save(lnk.c_str(), TRUE);
  }
}

// ── Toast content ─────────────────────────────────────────────────

ComPtr<IToastNotificationManagerStatics> ToastStatics() {
  ComPtr<IToastNotificationManagerStatics> mgr;
  RoGetActivationFactory(
      HStringReference(
          RuntimeClass_Windows_UI_Notifications_ToastNotificationManager)
          .Get(),
      IID_PPV_ARGS(&mgr));
  return mgr;
}

void SetXmlText(IXmlDocument* xml, IXmlNodeList* nodes, UINT32 idx,
                const std::wstring& value) {
  ComPtr<IXmlNode> node;
  if (FAILED(nodes->Item(idx, &node)) || !node) return;
  ComPtr<IXmlText> text;
  if (FAILED(xml->CreateTextNode(
          HStringReference(value.data(), (UINT32)value.size()).Get(),
          &text))) {
    return;
  }
  ComPtr<IXmlNode> text_node;
  if (FAILED(text.As(&text_node))) return;
  ComPtr<IXmlNode> appended;
  node->AppendChild(text_node.Get(), &appended);
}

// ToastText02 template: two <text> nodes — first renders bold (the
// notification title), second the body.
void ShowToast(const std::wstring& id, const std::wstring& title,
               const std::wstring& body) {
  if (id.empty()) return;
  ComPtr<IToastNotificationManagerStatics> mgr = ToastStatics();
  if (!mgr) return;

  ComPtr<IXmlDocument> xml;
  if (FAILED(mgr->GetTemplateContent(ToastTemplateType_ToastText02, &xml)) ||
      !xml) {
    return;
  }
  ComPtr<IXmlNodeList> texts;
  if (SUCCEEDED(xml->GetElementsByTagName(HStringReference(L"text").Get(),
                                          &texts)) &&
      texts) {
    UINT32 count = 0;
    texts->get_Length(&count);
    if (count >= 1) SetXmlText(xml.Get(), texts.Get(), 0, title);
    if (count >= 2) SetXmlText(xml.Get(), texts.Get(), 1, body);
  }

  ComPtr<IToastNotificationFactory> factory;
  RoGetActivationFactory(
      HStringReference(
          RuntimeClass_Windows_UI_Notifications_ToastNotification)
          .Get(),
      IID_PPV_ARGS(&factory));
  if (!factory) return;
  ComPtr<IToastNotification> toast;
  if (FAILED(factory->CreateToastNotification(xml.Get(), &toast)) || !toast) {
    return;
  }

  // Tag = Dart notification id → Activation handler / history Remove.
  ComPtr<IToastNotification2> toast2;
  if (SUCCEEDED(toast.As(&toast2)) && toast2) {
    HString tag;
    tag.Set(id.data(), (UINT32)id.size());
    toast2->put_Tag(tag.Get());
  }

  // In-process click handling (valid while this process lives — the
  // only time Octodo toasts exist). FtmBase lets the WinRT event fire
  // the handler on its thread-pool thread regardless of the
  // apartment the toast was created on.
  EventRegistrationToken token{};
  // NB: the delegate interface must be Implements' FIRST interface —
  // Callback extracts it via FirstInterface; with FtmBase first it
  // would grab FtmBase's CloakedIid<IMarshal> instead.
  auto on_activated = Callback<
      Microsoft::WRL::Implements<Microsoft::WRL::RuntimeClassFlags<
                                     Microsoft::WRL::ClassicCom>,
                                 ABI::Windows::Foundation::ITypedEventHandler<
                                     ToastNotification*, IInspectable*>,
                                 FtmBase>>(
      [](IToastNotification* sender, IInspectable* /*args*/) -> HRESULT {
        std::wstring tag;
        ComPtr<IToastNotification2> t2;
        if (sender &&
            SUCCEEDED(sender->QueryInterface(IID_PPV_ARGS(&t2))) && t2) {
          HString raw;
          if (SUCCEEDED(t2->get_Tag(raw.GetAddressOf())) && raw.IsValid()) {
            UINT32 len = 0;
            const wchar_t* buf = raw.GetRawBuffer(&len);
            tag.assign(buf, len);
          }
        }
        if (g_hwnd) {
          PostMessage(g_hwnd, kActivationMessage, 0,
                      reinterpret_cast<LPARAM>(new std::wstring(tag)));
        }
        return S_OK;
      });
  if (on_activated) {
    toast->add_Activated(on_activated.Get(), &token);
  }

  ComPtr<IToastNotifier> notifier;
  if (FAILED(mgr->CreateToastNotifierWithId(AumidRef().Get(), &notifier)) ||
      !notifier) {
    return;
  }
  notifier->Show(toast.Get());
}

void DismissToast(const std::wstring& id) {
  if (id.empty()) return;
  ComPtr<IToastNotificationManagerStatics2> mgr2;
  RoGetActivationFactory(
      HStringReference(
          RuntimeClass_Windows_UI_Notifications_ToastNotificationManager)
          .Get(),
      IID_PPV_ARGS(&mgr2));
  if (!mgr2) return;
  ComPtr<IToastNotificationHistory> history;
  // get_History() resolves "calling app", which is not reliable for a
  // classic Win32 process posting under an explicit AUMID; the WithId
  // remove variants pass the AUMID explicitly (same pattern as
  // Microsoft's desktop-toast compat library).
  if (FAILED(mgr2->get_History(&history)) || !history) {
    return;
  }
  history->RemoveGroupedTagWithId(
      HStringReference(id.data(), (UINT32)id.size()).Get(),
      HStringReference(L"").Get(), AumidRef().Get());
}

// ── Taskbar overlay badge ─────────────────────────────────────────

// 64x64 32-bpp ARGB dot — solid red (#FF3B30, the conventional
// "unread" notification red) with ~1px analytic anti-aliasing. The
// taskbar draws overlays at the small-icon metric scaled by DPI
// (~20-40 device px), so a 64px source is always DOWNscaled — a
// hard-edged 16px bitmap instead got upscaled on high-DPI displays
// and looked jagged. No white ring: at taskbar size a ring dominated
// the dot and read as a white blob. Built at runtime — no bundled
// icon resource to manage.
HICON BuildDotIcon() {
  constexpr int kSize = 64;
  constexpr double kRadius = 28.0;  // red dot outer edge
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = kSize;
  bmi.bmiHeader.biHeight = -kSize;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP color =
      CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, screen);
  if (!color || !bits) return nullptr;

  // Fractional coverage of a disc of [radius] at distance [d],
  // feathered over 1px so the edge lands on partial alpha.
  auto cover = [](double d, double radius) {
    double c = radius - d + 0.5;
    return c < 0.0 ? 0.0 : (c > 1.0 ? 1.0 : c);
  };

  auto* px = static_cast<DWORD*>(bits);
  const double c = (kSize - 1) / 2.0;
  for (int y = 0; y < kSize; y++) {
    for (int x = 0; x < kSize; x++) {
      const double d = sqrt((x - c) * (x - c) + (y - c) * (y - c));
      const double alpha = cover(d, kRadius);
      DWORD argb;
      if (alpha <= 0.0) {
        px[y * kSize + x] = 0;  // transparent
        continue;
      }
      const double r = 255.0;
      const double g = 59.0;
      const double b = 48.0;
      argb = ((DWORD)(alpha * 255.0) << 24) |
             ((DWORD)(r + 0.5) << 16) | ((DWORD)(g + 0.5) << 8) |
             (DWORD)(b + 0.5);
      px[y * kSize + x] = argb;  // ARGB dword == BGRA byte order
    }
  }

  // CreateIconIndirect requires a monochrome mask bitmap even for
  // 32-bpp icons with alpha; an all-zero mask is ignored when the
  // color bitmap carries per-pixel alpha.
  HBITMAP mask = CreateBitmap(kSize, kSize, 1, 1, nullptr);
  ICONINFO ii = {};
  ii.fIcon = TRUE;
  ii.hbmColor = color;
  ii.hbmMask = mask;
  HICON icon = CreateIconIndirect(&ii);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

void SetBadge(int count) {
  if (!g_hwnd) return;
  if (!g_taskbar) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_taskbar))) ||
        !g_taskbar) {
      return;
    }
    g_taskbar->HrInit();
  }
  if (count > 0) {
    if (!g_dot_icon) g_dot_icon = BuildDotIcon();
    if (g_dot_icon) g_taskbar->SetOverlayIcon(g_hwnd, g_dot_icon, L"unread");
  } else {
    // Passing nullptr clears the overlay. Safe before the window is
    // shown / has no taskbar button yet — the call just fails, the
    // next setBadge retries.
    g_taskbar->SetOverlayIcon(g_hwnd, nullptr, nullptr);
  }
}

// ── Activation ────────────────────────────────────────────────────

void ActivateApp() {
  if (!g_hwnd) return;
  if (IsIconic(g_hwnd)) ShowWindow(g_hwnd, SW_RESTORE);
  // Foreground permission was granted by the user's toast click; if
  // the OS still refuses, the window at least flashes in the taskbar.
  SetForegroundWindow(g_hwnd);
}

// ── Method channel ────────────────────────────────────────────────

const flutter::EncodableValue* FlutterEncodableMapFind(
    const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

void OnMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                      result) {
  const auto* args = call.arguments();
  const flutter::EncodableMap empty;
  const auto& map = args && std::holds_alternative<flutter::EncodableMap>(*args)
                        ? std::get<flutter::EncodableMap>(*args)
                        : empty;

  const std::string& method = call.method_name();
  if (method == "requestAuth") {
    // Windows has no runtime authorization for toasts — the OS-level
    // per-app setting silently governs delivery.
    result->Success();
  } else if (method == "show") {
    ShowToast(EncodableToString(FlutterEncodableMapFind(map, "id")),
              EncodableToString(FlutterEncodableMapFind(map, "title")),
              EncodableToString(FlutterEncodableMapFind(map, "body")));
    result->Success();
  } else if (method == "dismiss") {
    DismissToast(EncodableToString(FlutterEncodableMapFind(map, "id")));
    result->Success();
  } else if (method == "setBadge") {
    const auto* count = FlutterEncodableMapFind(map, "count");
    SetBadge(count && std::holds_alternative<int32_t>(*count)
                 ? std::get<int32_t>(*count)
                 : 0);
    result->Success();
  } else if (method == "activate") {
    ActivateApp();
    result->Success();
  } else if (method == "openSettings") {
    // Open the modern Settings notifications page — the per-app
    // toast controls live there. Best-effort: launch-and-continue.
    ShellExecuteW(nullptr, L"open", L"ms-settings:notifications", nullptr,
                  nullptr, SW_SHOWNORMAL);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterNotifications(flutter::FlutterEngine* engine, HWND hwnd) {
  g_hwnd = hwnd;
  // The platform thread needs a COM apartment for the WinRT
  // activation-factory calls. S_FALSE (already initialized) and
  // RPC_E_CHANGED_MODE (already STA) are both fine — an apartment
  // exists either way.
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  EnsureAumidShortcut();
  g_channel = new flutter::MethodChannel<flutter::EncodableValue>(
      engine->messenger(), "octodo/notifications",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(OnMethodCall);
}

bool HandleNotificationsWindowMessage(UINT message, LPARAM lparam) {
  if (message != kActivationMessage) return false;
  auto* id = reinterpret_cast<std::wstring*>(lparam);
  ActivateApp();
  if (g_channel && id) {
    g_channel->InvokeMethod(
        "onActivation",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {"id", flutter::EncodableValue(WideStringToUtf8(*id))},
        }));
  }
  delete id;
  return true;
}

}  // namespace octodo
