// AppKit glue for the macOS backend: one borderless, always-on-top window
// showing whatever pixels backend.zig last rendered, with key events
// forwarded back to it. Holds no launcher state of its own -- query,
// results and drawing all live in Zig (src/core), same as on Wayland.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include "zofi_macos.h"

// Carbon's kVK_* virtual key codes, so named keys are matched by physical
// key regardless of keyboard layout, without pulling in all of Carbon.
enum {
    kZofiVKReturn = 0x24,
    kZofiVKTab = 0x30,
    kZofiVKDelete = 0x33,
    kZofiVKEscape = 0x35,
    kZofiVKKeypadEnter = 0x4C,
    kZofiVKHome = 0x73,
    kZofiVKForwardDelete = 0x75,
    kZofiVKPageUp = 0x74,
    kZofiVKEnd = 0x77,
    kZofiVKPageDown = 0x79,
    kZofiVKLeftArrow = 0x7B,
    kZofiVKRightArrow = 0x7C,
    kZofiVKDownArrow = 0x7D,
    kZofiVKUpArrow = 0x7E,
};

static ZofiMacNamedKey namedKeyFor(unsigned short keyCode) {
    switch (keyCode) {
    case kZofiVKEscape: return ZOFI_MAC_KEY_ESCAPE;
    case kZofiVKReturn:
    case kZofiVKKeypadEnter: return ZOFI_MAC_KEY_ENTER;
    case kZofiVKDelete: return ZOFI_MAC_KEY_BACKSPACE;
    case kZofiVKLeftArrow: return ZOFI_MAC_KEY_LEFT;
    case kZofiVKRightArrow: return ZOFI_MAC_KEY_RIGHT;
    case kZofiVKUpArrow: return ZOFI_MAC_KEY_UP;
    case kZofiVKDownArrow: return ZOFI_MAC_KEY_DOWN;
    case kZofiVKPageUp: return ZOFI_MAC_KEY_PAGE_UP;
    case kZofiVKPageDown: return ZOFI_MAC_KEY_PAGE_DOWN;
    case kZofiVKHome: return ZOFI_MAC_KEY_HOME;
    case kZofiVKEnd: return ZOFI_MAC_KEY_END;
    case kZofiVKTab: return ZOFI_MAC_KEY_TAB;
    case kZofiVKForwardDelete: return ZOFI_MAC_KEY_DELETE;
    default: return ZOFI_MAC_KEY_NONE;
    }
}

// Control characters and the private-use range AppKit reports arrow and
// function keys in (NSUpArrowFunctionKey = 0xF700, ...) aren't text to
// type into the query.
static BOOL isInsertableText(NSString *s) {
    if (s.length == 0) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c == 0x7F || (c >= 0xF700 && c <= 0xF8FF)) return NO;
    }
    return YES;
}

@interface ZofiWindow : NSWindow
@end

@implementation ZofiWindow
// Borderless windows refuse key status by default, which would leave the
// launcher unable to receive any typing at all.
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return YES;
}
@end

@interface ZofiView : NSView
- (instancetype)initWithFrame:(NSRect)frame callbacks:(ZofiMacCallbacks)callbacks;
- (void)setImage:(CGImageRef)image;
@end

@implementation ZofiView {
    ZofiMacCallbacks _callbacks;
    CGImageRef _image;
}

- (instancetype)initWithFrame:(NSRect)frame callbacks:(ZofiMacCallbacks)callbacks {
    self = [super initWithFrame:frame];
    if (self) {
        _callbacks = callbacks;
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    }
    return self;
}

- (void)dealloc {
    CGImageRelease(_image);
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)isOpaque {
    return NO;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

// The rendered image already has the panel's final pixel size (points x
// backing scale), so it's handed to the layer as-is: no redrawing, and the
// layer's default resize gravity maps it 1:1 onto the view's bounds.
- (void)updateLayer {
    self.layer.contents = (__bridge id)_image;
}

- (void)setImage:(CGImageRef)image {
    CGImageRelease(_image);
    _image = CGImageRetain(image);
    self.needsDisplay = YES;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (_callbacks.rescale) _callbacks.rescale(_callbacks.ctx);
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.characters ?: @"";
    NSString *unmodified = event.charactersIgnoringModifiers ?: @"";
    const char *text = isInsertableText(chars) ? chars.UTF8String : "";
    const char *text_unmodified = unmodified.UTF8String ?: "";
    NSEventModifierFlags flags = event.modifierFlags;

    ZofiMacKeyEvent ev = {
        .named = namedKeyFor(event.keyCode),
        .ctrl = (flags & NSEventModifierFlagControl) != 0,
        .shift = (flags & NSEventModifierFlagShift) != 0,
        .command = (flags & NSEventModifierFlagCommand) != 0,
        .repeat = event.isARepeat,
        .text = text,
        .text_len = strlen(text),
        .text_unmodified = text_unmodified,
        .text_unmodified_len = strlen(text_unmodified),
    };
    if (_callbacks.key) _callbacks.key(_callbacks.ctx, &ev);
}
@end

@interface ZofiController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) ZofiWindow *window;
@property(nonatomic, strong) ZofiView *view;
@property(nonatomic) ZofiMacCallbacks callbacks;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL presented;
@end

@implementation ZofiController
- (void)requestClose {
    if (self.running && self.callbacks.close) self.callbacks.close(self.callbacks.ctx);
}

// Spotlight-style: clicking anywhere else dismisses the launcher instead of
// leaving it floating above everything with no keyboard focus.
- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    [self requestClose];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self requestClose];
}
@end

static ZofiController *controllerFrom(ZofiMacWindow *window) {
    return (__bridge ZofiController *)(void *)window;
}

static NSScreen *screenUnderMouse(void) {
    NSPoint mouse = NSEvent.mouseLocation;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSMouseInRect(mouse, screen.frame, NO)) return screen;
    }
    return NSScreen.mainScreen;
}

ZofiMacWindow *zofi_mac_window_create(double width, double height, const ZofiMacCallbacks *callbacks) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // zofi is a plain executable, not an .app bundle. Accessory keeps
        // it out of the Dock and Cmd+Tab (like any launcher overlay) while
        // still letting its window take keyboard focus.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        NSScreen *screen = screenUnderMouse();
        NSRect area = screen ? screen.visibleFrame : NSMakeRect(0, 0, width, height);
        NSRect frame = NSMakeRect(
            round(NSMidX(area) - width / 2),
            round(NSMidY(area) - height / 2),
            width,
            height);

        ZofiWindow *window = [[ZofiWindow alloc] initWithContentRect:frame
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"zofi";
        // Transparent outside the rendered panel's rounded corners.
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = YES;
        // Above regular and floating windows, on whichever Space is
        // current, including over full-screen apps -- the macOS
        // equivalent of the Wayland backend's overlay layer surface.
        window.level = NSStatusWindowLevel;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;

        ZofiView *view = [[ZofiView alloc] initWithFrame:NSMakeRect(0, 0, width, height) callbacks:*callbacks];
        window.contentView = view;
        [window makeFirstResponder:view];

        ZofiController *controller = [[ZofiController alloc] init];
        controller.window = window;
        controller.view = view;
        controller.callbacks = *callbacks;
        window.delegate = controller;

        return (__bridge_retained void *)controller;
    }
}

void zofi_mac_window_destroy(ZofiMacWindow *window) {
    @autoreleasepool {
        ZofiController *controller = (__bridge_transfer ZofiController *)(void *)window;
        controller.running = NO;
        controller.window.delegate = nil;
        [controller.window orderOut:nil];
        [controller.window close];
    }
}

double zofi_mac_window_scale(ZofiMacWindow *window) {
    return controllerFrom(window).window.backingScaleFactor;
}

void zofi_mac_window_present(ZofiMacWindow *window, const void *pixels, int32_t width_px, int32_t height_px) {
    @autoreleasepool {
        ZofiController *controller = controllerFrom(window);
        size_t stride = (size_t)width_px * 4;

        CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)(stride * (size_t)height_px));
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGImageRef image = CGImageCreate(
            (size_t)width_px,
            (size_t)height_px,
            8,
            32,
            stride,
            space,
            kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
            provider,
            NULL,
            false,
            kCGRenderingIntentDefault);
        [controller.view setImage:image];
        CGImageRelease(image);
        CGColorSpaceRelease(space);
        CGDataProviderRelease(provider);
        CFRelease(data);

        [controller.window displayIfNeeded];
        // The window shadow follows the content's alpha (the rounded
        // corners), which doesn't exist until the first frame lands.
        if (!controller.presented) {
            controller.presented = YES;
            [controller.window invalidateShadow];
        }
    }
}

void zofi_mac_window_show(ZofiMacWindow *window) {
    @autoreleasepool {
        ZofiController *controller = controllerFrom(window);
        // Deprecated in macOS 14 in favor of the cooperative -activate,
        // which can decline when whatever spawned zofi (a terminal, a
        // hotkey daemon) doesn't yield focus -- and a launcher that opens
        // without keyboard focus is useless.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
        [controller.window makeKeyAndOrderFront:nil];
    }
}

void zofi_mac_window_run(ZofiMacWindow *window) {
    ZofiController *controller = controllerFrom(window);
    controller.running = YES;
    while (controller.running) {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:NSDate.distantFuture
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    }
    [controller.window orderOut:nil];
}

void zofi_mac_window_stop(ZofiMacWindow *window) {
    @autoreleasepool {
        controllerFrom(window).running = NO;
        // Wake the loop in case this wasn't called from inside an event
        // handler, so it notices `running` is now false.
        NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                           location:NSZeroPoint
                                      modifierFlags:0
                                          timestamp:0
                                       windowNumber:0
                                            context:nil
                                            subtype:0
                                              data1:0
                                              data2:0];
        [NSApp postEvent:wake atStart:YES];
    }
}

void zofi_mac_list_running_apps(void *ctx, ZofiMacAppVisitor visit) {
    @autoreleasepool {
        pid_t self_pid = NSProcessInfo.processInfo.processIdentifier;
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
            // Regular = has a Dock icon and windows of its own; skips
            // agents, daemons and menu bar extras.
            if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
            if (app.processIdentifier == self_pid || app.terminated) continue;
            visit(ctx, app.processIdentifier, app.localizedName.UTF8String ?: "", app.bundleIdentifier.UTF8String ?: "");
        }
    }
}

bool zofi_mac_activate_app(int32_t pid) {
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app) return false;
        // macOS 14+ only lets another app take focus if the active one
        // (zofi, at this point) explicitly yields it.
        if (@available(macOS 14.0, *)) {
            [NSApp yieldActivationToApplication:app];
        }
        return [app activateWithOptions:NSApplicationActivateAllWindows];
    }
}

int64_t zofi_mac_pasteboard_change_count(void) {
    return (int64_t)NSPasteboard.generalPasteboard.changeCount;
}

bool zofi_mac_pasteboard_read(void *ctx, ZofiMacPasteboardVisitor visit) {
    @autoreleasepool {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSArray<NSPasteboardType> *types = pb.types;
        // nspasteboard.org conventions: password managers mark secrets as
        // concealed, and apps mark throwaway content as transient.
        if ([types containsObject:@"org.nspasteboard.ConcealedType"] ||
            [types containsObject:@"org.nspasteboard.TransientType"]) {
            return false;
        }

        // Text first, matching the Wayland daemon's preference order.
        NSString *text = [pb stringForType:NSPasteboardTypeString];
        if (text.length > 0) {
            NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
            visit(ctx, "text/plain;charset=utf-8", utf8.bytes, utf8.length);
            return true;
        }

        NSData *png = [pb dataForType:NSPasteboardTypePNG];
        if (png.length == 0) {
            // Screenshots and most image copies on macOS are TIFF-only.
            NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
            if (tiff.length > 0) {
                NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
                png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            }
        }
        if (png.length > 0) {
            visit(ctx, "image/png", png.bytes, png.length);
            return true;
        }
        return false;
    }
}

bool zofi_mac_pasteboard_write(const char *mime, const void *bytes, size_t len) {
    @autoreleasepool {
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        NSData *data = [NSData dataWithBytes:bytes length:len];

        if (strncmp(mime, "text/", 5) == 0) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!text) return false;
            [pb clearContents];
            return [pb setString:text forType:NSPasteboardTypeString];
        }

        // Offer both PNG and TIFF: some apps only paste one or the other.
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep) return false;
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSData *tiff = rep.TIFFRepresentation;
        [pb declareTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF ] owner:nil];
        BOOL ok = NO;
        if (png) ok = [pb setData:png forType:NSPasteboardTypePNG] || ok;
        if (tiff) ok = [pb setData:tiff forType:NSPasteboardTypeTIFF] || ok;
        return ok;
    }
}
