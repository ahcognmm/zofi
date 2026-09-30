// C interface between the Zig macOS backend (backend.zig) and its AppKit
// glue (window.m). Only plain C types cross this boundary, so backend.zig
// can @cImport it without any Objective-C in sight.
#ifndef ZOFI_MACOS_H
#define ZOFI_MACOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ZofiMacWindow ZofiMacWindow;

typedef enum {
    ZOFI_MAC_KEY_NONE = 0,
    ZOFI_MAC_KEY_ESCAPE,
    ZOFI_MAC_KEY_ENTER,
    ZOFI_MAC_KEY_BACKSPACE,
    ZOFI_MAC_KEY_LEFT,
    ZOFI_MAC_KEY_RIGHT,
    ZOFI_MAC_KEY_UP,
    ZOFI_MAC_KEY_DOWN,
    ZOFI_MAC_KEY_PAGE_UP,
    ZOFI_MAC_KEY_PAGE_DOWN,
    ZOFI_MAC_KEY_HOME,
    ZOFI_MAC_KEY_END,
    ZOFI_MAC_KEY_TAB,
    /// Forward delete (Fn+Backspace on laptop keyboards).
    ZOFI_MAC_KEY_DELETE,
} ZofiMacNamedKey;

typedef struct {
    /// ZOFI_MAC_KEY_NONE for anything that isn't one of the named keys.
    ZofiMacNamedKey named;
    bool ctrl;
    bool shift;
    bool command;
    /// Auto-repeat from a held key (AppKit generates these itself).
    bool repeat;
    /// NSEvent.characters as UTF-8, or empty when that isn't insertable
    /// text (control characters, arrow/function keys). Not NUL-terminated
    /// from Zig's point of view; valid only for the duration of the callback.
    const char *text;
    size_t text_len;
    /// NSEvent.charactersIgnoringModifiers, e.g. "w" for Ctrl+W (where
    /// `text` would be the control character 0x17 instead).
    const char *text_unmodified;
    size_t text_unmodified_len;
} ZofiMacKeyEvent;

typedef struct {
    void *ctx;
    void (*key)(void *ctx, const ZofiMacKeyEvent *event);
    /// The window's backing scale factor changed (e.g. it landed on a
    /// display with a different density): render again at
    /// zofi_mac_window_scale() and present.
    void (*rescale)(void *ctx);
    /// The window lost focus or was closed; treat it like a cancel.
    void (*close)(void *ctx);
} ZofiMacCallbacks;

/// Sets up NSApplication (no Dock icon) and a borderless, always-on-top
/// window of `width` x `height` points, centered on the screen under the
/// mouse. `callbacks` is copied. Not visible until zofi_mac_window_show().
ZofiMacWindow *zofi_mac_window_create(double width, double height, const ZofiMacCallbacks *callbacks);
void zofi_mac_window_destroy(ZofiMacWindow *window);

/// Pixels per point for the window's current display (2.0 on Retina).
double zofi_mac_window_scale(ZofiMacWindow *window);

/// Shows `pixels`: premultiplied ARGB32 in native little-endian order (BGRA
/// in memory), which is z2d's `image_surface_argb` layout. The buffer is
/// copied, so the caller can reuse it immediately.
void zofi_mac_window_present(ZofiMacWindow *window, const void *pixels, int32_t width_px, int32_t height_px);

/// Brings the app forward and gives the window keyboard focus.
void zofi_mac_window_show(ZofiMacWindow *window);

/// Pumps AppKit events until zofi_mac_window_stop() is called (normally
/// from inside one of the callbacks), then hides the window.
void zofi_mac_window_run(ZofiMacWindow *window);
void zofi_mac_window_stop(ZofiMacWindow *window);

/// Windows mode: calls `visit` for every running app that shows up in the
/// Dock/Cmd+Tab (regular activation policy), excluding zofi itself. The
/// strings are only valid for the duration of each call.
typedef void (*ZofiMacAppVisitor)(void *ctx, int32_t pid, const char *name, const char *bundle_id);
void zofi_mac_list_running_apps(void *ctx, ZofiMacAppVisitor visit);

/// Brings every window of the app with this pid to the front.
bool zofi_mac_activate_app(int32_t pid);

/// Clipboard history (`zofi --clipboard-daemon` and the clipboard tab).
/// NSPasteboard has no change notifications, only a counter that bumps on
/// every write; the daemon polls it.
int64_t zofi_mac_pasteboard_change_count(void);

/// Reads the general pasteboard's current content and, if it's something
/// the history keeps, calls `visit` once with a mime type
/// ("text/plain;charset=utf-8" or "image/png"; TIFF-only images are
/// converted to PNG) and the bytes, valid only during the call. Content
/// marked concealed or transient (password managers, per nspasteboard.org)
/// is skipped. Returns whether `visit` was called.
typedef void (*ZofiMacPasteboardVisitor)(void *ctx, const char *mime, const void *bytes, size_t len);
bool zofi_mac_pasteboard_read(void *ctx, ZofiMacPasteboardVisitor visit);

/// Replaces the general pasteboard's content with `bytes` of type `mime`
/// (any text/... type, or an image NSBitmapImageRep can decode). The data is
/// handed to the pasteboard server, so it outlives this process.
bool zofi_mac_pasteboard_write(const char *mime, const void *bytes, size_t len);

#endif
