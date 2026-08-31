#include "desktop_autostart.h"

#include <glib/gstdio.h>

#include <cerrno>

namespace {

constexpr char kDesktopFileName[] = "com.nkshub.nextcloudtalk.desktop";

gchar* DesktopFilePath() {
  return g_build_filename(g_get_user_config_dir(), "autostart",
                          kDesktopFileName, nullptr);
}

gchar* ExecutablePath(GError** error) {
  return g_file_read_link("/proc/self/exe", error);
}

gchar* QuoteExec(const gchar* path) {
  GString* value = g_string_new("\"");
  for (const gchar* cursor = path; *cursor != '\0'; cursor++) {
    if (*cursor == '\"' || *cursor == '\\' || *cursor == '$' ||
        *cursor == '`') {
      g_string_append_c(value, '\\');
    }
    g_string_append_c(value, *cursor);
  }
  g_string_append_c(value, '\"');
  return g_string_free(value, FALSE);
}

gboolean IsEnabled(gboolean* enabled, GError** error) {
  g_autofree gchar* desktop_path = DesktopFilePath();
  if (!g_file_test(desktop_path, G_FILE_TEST_EXISTS)) {
    *enabled = FALSE;
    return TRUE;
  }

  g_autoptr(GKeyFile) entry = g_key_file_new();
  if (!g_key_file_load_from_file(entry, desktop_path, G_KEY_FILE_NONE, error)) {
    return FALSE;
  }
  g_autofree gchar* type =
      g_key_file_get_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                            G_KEY_FILE_DESKTOP_KEY_TYPE, error);
  if (type == nullptr) {
    return FALSE;
  }
  g_autofree gchar* exec =
      g_key_file_get_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                            G_KEY_FILE_DESKTOP_KEY_EXEC, error);
  if (exec == nullptr) {
    return FALSE;
  }
  g_autoptr(GError) executable_error = nullptr;
  g_autofree gchar* executable = ExecutablePath(&executable_error);
  if (executable == nullptr) {
    g_propagate_error(error, g_steal_pointer(&executable_error));
    return FALSE;
  }
  g_autofree gchar* expected_exec = QuoteExec(executable);

  gboolean hidden = FALSE;
  if (g_key_file_has_key(entry, G_KEY_FILE_DESKTOP_GROUP,
                         G_KEY_FILE_DESKTOP_KEY_HIDDEN, nullptr)) {
    hidden = g_key_file_get_boolean(entry, G_KEY_FILE_DESKTOP_GROUP,
                                    G_KEY_FILE_DESKTOP_KEY_HIDDEN, error);
    if (*error != nullptr) {
      return FALSE;
    }
  }
  gboolean allowed = TRUE;
  if (g_key_file_has_key(entry, G_KEY_FILE_DESKTOP_GROUP,
                         "X-GNOME-Autostart-enabled", nullptr)) {
    allowed = g_key_file_get_boolean(entry, G_KEY_FILE_DESKTOP_GROUP,
                                     "X-GNOME-Autostart-enabled", error);
    if (*error != nullptr) {
      return FALSE;
    }
  }
  *enabled = g_str_equal(type, G_KEY_FILE_DESKTOP_TYPE_APPLICATION) &&
             g_str_equal(exec, expected_exec) && !hidden && allowed;
  return TRUE;
}

gboolean SetEnabled(gboolean enabled, GError** error) {
  g_autofree gchar* desktop_path = DesktopFilePath();
  if (!enabled) {
    if (g_remove(desktop_path) == 0 || errno == ENOENT) {
      return TRUE;
    }
    g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                "Could not remove desktop autostart entry");
    return FALSE;
  }

  g_autofree gchar* directory = g_path_get_dirname(desktop_path);
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                "Could not create desktop autostart directory");
    return FALSE;
  }
  g_autofree gchar* executable = ExecutablePath(error);
  if (executable == nullptr) {
    return FALSE;
  }
  g_autofree gchar* exec = QuoteExec(executable);
  g_autoptr(GKeyFile) entry = g_key_file_new();
  g_key_file_set_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                        G_KEY_FILE_DESKTOP_KEY_TYPE,
                        G_KEY_FILE_DESKTOP_TYPE_APPLICATION);
  g_key_file_set_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                        G_KEY_FILE_DESKTOP_KEY_VERSION, "1.0");
  g_key_file_set_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                        G_KEY_FILE_DESKTOP_KEY_NAME, "NKS Talk");
  g_key_file_set_string(entry, G_KEY_FILE_DESKTOP_GROUP,
                        G_KEY_FILE_DESKTOP_KEY_EXEC, exec);
  g_key_file_set_boolean(entry, G_KEY_FILE_DESKTOP_GROUP,
                         G_KEY_FILE_DESKTOP_KEY_TERMINAL, FALSE);
  g_key_file_set_boolean(entry, G_KEY_FILE_DESKTOP_GROUP,
                         "X-GNOME-Autostart-enabled", TRUE);
  gsize data_size = 0;
  g_autofree gchar* data = g_key_file_to_data(entry, &data_size, error);
  if (data == nullptr ||
      !g_file_set_contents(desktop_path, data, data_size, error)) {
    return FALSE;
  }
  if (g_chmod(desktop_path, 0600) != 0) {
    g_set_error(error, G_FILE_ERROR, g_file_error_from_errno(errno),
                "Could not protect desktop autostart entry");
    return FALSE;
  }
  return TRUE;
}

void RespondError(FlMethodCall* call, const gchar* code) {
  fl_method_call_respond_error(
      call, code, "The desktop startup setting could not be changed.", nullptr,
      nullptr);
}

void MethodCall(FlMethodChannel* channel, FlMethodCall* call,
                gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "isSupported")) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(call, value, nullptr);
    return;
  }
  if (g_str_equal(method, "isEnabled")) {
    gboolean enabled = FALSE;
    g_autoptr(GError) error = nullptr;
    if (!IsEnabled(&enabled, &error)) {
      RespondError(call, "autostart-read-failed");
      return;
    }
    g_autoptr(FlValue) value = fl_value_new_bool(enabled);
    fl_method_call_respond_success(call, value, nullptr);
    return;
  }
  if (!g_str_equal(method, "setEnabled")) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }

  FlValue* arguments = fl_method_call_get_args(call);
  FlValue* requested = arguments == nullptr
                           ? nullptr
                           : fl_value_lookup_string(arguments, "enabled");
  if (requested == nullptr ||
      fl_value_get_type(requested) != FL_VALUE_TYPE_BOOL) {
    RespondError(call, "autostart-invalid-arguments");
    return;
  }
  g_autoptr(GError) error = nullptr;
  if (!SetEnabled(fl_value_get_bool(requested), &error)) {
    RespondError(call, "autostart-write-failed");
    return;
  }
  gboolean actual = FALSE;
  if (!IsEnabled(&actual, &error)) {
    RespondError(call, "autostart-read-failed");
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_bool(actual);
  fl_method_call_respond_success(call, value, nullptr);
}

}  // namespace

FlMethodChannel* desktop_autostart_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "com.nkshub.nextcloudtalk/desktop_autostart",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, MethodCall, nullptr,
                                            nullptr);
  return channel;
}
