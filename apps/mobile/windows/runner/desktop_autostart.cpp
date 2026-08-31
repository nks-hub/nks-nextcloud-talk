#include "desktop_autostart.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kValueName[] = L"NKS Talk";

std::optional<std::wstring> ExecutableCommand() {
  std::vector<wchar_t> path(32768);
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
                                        static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) {
    return std::nullopt;
  }
  return L"\"" + std::wstring(path.data(), size) + L"\"";
}

LSTATUS ReadRegisteredCommand(std::optional<std::wstring>* command) {
  DWORD type = 0;
  DWORD byte_count = 0;
  LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kValueName,
                                RRF_RT_REG_SZ, &type, nullptr, &byte_count);
  if (status == ERROR_FILE_NOT_FOUND) {
    command->reset();
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS || byte_count < sizeof(wchar_t)) {
    return status == ERROR_SUCCESS ? ERROR_INVALID_DATA : status;
  }

  std::vector<wchar_t> value(byte_count / sizeof(wchar_t));
  status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kValueName,
                        RRF_RT_REG_SZ, &type, value.data(), &byte_count);
  if (status != ERROR_SUCCESS) {
    return status;
  }
  command->emplace(value.data());
  return ERROR_SUCCESS;
}

LSTATUS SetRegistered(bool enabled, const std::wstring& command) {
  if (!enabled) {
    HKEY key = nullptr;
    LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0,
                                   KEY_SET_VALUE, &key);
    if (status == ERROR_FILE_NOT_FOUND) {
      return ERROR_SUCCESS;
    }
    if (status != ERROR_SUCCESS) {
      return status;
    }
    status = RegDeleteValueW(key, kValueName);
    RegCloseKey(key);
    return status == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : status;
  }

  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                                   KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    return status;
  }
  const DWORD byte_count =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  status = RegSetValueExW(
      key, kValueName, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()), byte_count);
  RegCloseKey(key);
  return status;
}

bool IsRegistered(const std::wstring& expected, LSTATUS* status) {
  std::optional<std::wstring> registered;
  *status = ReadRegisteredCommand(&registered);
  return *status == ERROR_SUCCESS && registered.has_value() &&
         registered.value() == expected;
}

void RespondError(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    const char* code) {
  result->Error(code, "The desktop startup setting could not be changed.");
}

}  // namespace

DesktopAutostart::DesktopAutostart(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.nkshub.nextcloudtalk/desktop_autostart",
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "isSupported") {
          result->Success(flutter::EncodableValue(true));
          return;
        }

        const auto command = ExecutableCommand();
        if (!command.has_value()) {
          RespondError(std::move(result), "autostart-executable-unavailable");
          return;
        }
        if (call.method_name() == "isEnabled") {
          LSTATUS status = ERROR_SUCCESS;
          const bool enabled = IsRegistered(command.value(), &status);
          if (status != ERROR_SUCCESS) {
            RespondError(std::move(result), "autostart-read-failed");
            return;
          }
          result->Success(flutter::EncodableValue(enabled));
          return;
        }
        if (call.method_name() != "setEnabled") {
          result->NotImplemented();
          return;
        }

        const auto* arguments = std::get_if<flutter::EncodableMap>(
            call.arguments());
        if (arguments == nullptr) {
          RespondError(std::move(result), "autostart-invalid-arguments");
          return;
        }
        const auto value = arguments->find(flutter::EncodableValue("enabled"));
        if (value == arguments->end() ||
            !std::holds_alternative<bool>(value->second)) {
          RespondError(std::move(result), "autostart-invalid-arguments");
          return;
        }
        const bool requested = std::get<bool>(value->second);
        if (SetRegistered(requested, command.value()) != ERROR_SUCCESS) {
          RespondError(std::move(result), "autostart-write-failed");
          return;
        }
        LSTATUS status = ERROR_SUCCESS;
        const bool actual = IsRegistered(command.value(), &status);
        if (status != ERROR_SUCCESS) {
          RespondError(std::move(result), "autostart-read-failed");
          return;
        }
        result->Success(flutter::EncodableValue(actual));
      });
}

DesktopAutostart::~DesktopAutostart() = default;
