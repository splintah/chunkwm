#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "../../api/plugin_api.h"
#include "../../common/accessibility/display.h"
#include "../../common/accessibility/application.h"
#include "../../common/accessibility/window.h"
#include "../../common/accessibility/element.h"
#include "../../common/border/border.h"
#include "../../common/config/tokenize.h"
#include "../../common/config/cvar.h"
#include "../../common/misc/assert.h"

#include "../../common/accessibility/display.mm"
#include "../../common/accessibility/window.cpp"
#include "../../common/accessibility/element.cpp"
#include "../../common/config/tokenize.cpp"
#include "../../common/config/cvar.cpp"
#include "../../common/border/border.mm"

#define internal static

internal macos_application *Application;
internal border_window *Border;
internal bool SkipFloating;
internal bool DrawBorder;
internal chunkwm_api API;
internal void UpdateBorderCustomColor(macos_application *FocusedApplication);

struct window_rule
{
    char *Owner;
    unsigned Color;
    bool DrawBorder;
};
internal std::vector<window_rule *> WindowRules;

internal AXUIElementRef
GetFocusedWindow()
{
    AXUIElementRef ApplicationRef, WindowRef;

    ApplicationRef = AXLibGetFocusedApplication();
    if(ApplicationRef)
    {
        WindowRef = AXLibGetFocusedWindow(ApplicationRef);
        CFRelease(ApplicationRef);
        if(WindowRef)
        {
            return WindowRef;
        }
    }

    return NULL;;
}

internal void
CreateBorder(int X, int Y, int W, int H)
{
    unsigned Color = CVarUnsignedValue("focused_border_color");
    int Width = CVarIntegerValue("focused_border_width");
    int Radius = CVarIntegerValue("focused_border_radius");
    Border = CreateBorderWindow(X, Y, W, H, Width, Radius, Color, false);
}

internal inline void
ClearBorderWindow(border_window *Border)
{
    UpdateBorderWindowRect(Border, 0, 0, 0, 0);
}

internal inline void
FuckingMacOSMonitorBoundsChangingBetweenPrimaryAndMainMonitor(AXUIElementRef WindowRef)
{
    CGPoint Position = AXLibGetWindowPosition(WindowRef);
    CGSize Size = AXLibGetWindowSize(WindowRef);

    CFStringRef DisplayRef = AXLibGetDisplayIdentifierForMainDisplay();
    if(!DisplayRef) return;

    CGRect DisplayBounds = AXLibGetDisplayBounds(DisplayRef);
    CFRelease(DisplayRef);

    int InvertY = DisplayBounds.size.height - (Position.y + Size.height);
    if(Border)
    {
        UpdateBorderWindowRect(Border, Position.x, InvertY, Size.width, Size.height);
    }
    else
    {
        CreateBorder(Position.x, InvertY, Size.width, Size.height);
    }
}

internal inline void
UpdateWindow(AXUIElementRef WindowRef)
{
    if(DrawBorder)
    {
        if(AXLibIsWindowFullscreen(WindowRef))
        {
            if(Border)
            {
                ClearBorderWindow(Border);
            }
        }
        else
        {
            FuckingMacOSMonitorBoundsChangingBetweenPrimaryAndMainMonitor(WindowRef);
        }
    }
}

internal void
UpdateToFocusedWindow()
{
    AXUIElementRef WindowRef = GetFocusedWindow();
    if(WindowRef)
    {
        uint32_t WindowId = AXLibGetWindowID(WindowRef);
        if(WindowId)
        {
            CFStringRef DisplayRef = AXLibGetDisplayIdentifierFromWindow(WindowId);
            if(!DisplayRef)
            {
                CGPoint Position = AXLibGetWindowPosition(WindowRef);
                CGSize Size = AXLibGetWindowSize(WindowRef);
                DisplayRef = AXLibGetDisplayIdentifierFromWindowRect(Position, Size);
            }
            ASSERT(DisplayRef);

            macos_space *Space = AXLibActiveSpace(DisplayRef);
            if(AXLibSpaceHasWindow(Space->Id, WindowId))
            {
                UpdateWindow(WindowRef);
            }
            else if(Border)
            {
                ClearBorderWindow(Border);
            }

            AXLibDestroySpace(Space);
            CFRelease(DisplayRef);
        }
        else if(Border)
        {
            ClearBorderWindow(Border);
        }
        CFRelease(WindowRef);
    }
    else if(Border)
    {
        ClearBorderWindow(Border);
    }
}

internal void
UpdateIfFocusedWindow(AXUIElementRef Element)
{
    AXUIElementRef WindowRef = GetFocusedWindow();
    if(WindowRef)
    {
        if(CFEqual(WindowRef, Element))
        {
            UpdateWindow(WindowRef);
        }
        CFRelease(WindowRef);
    }
}

internal inline void
ApplicationActivatedHandler(void *Data)
{
    Application = (macos_application *) Data;
    UpdateBorderCustomColor(Application);
    UpdateToFocusedWindow();
}

internal inline void
ApplicationDeactivatedHandler(void *Data)
{
    macos_application *Context = (macos_application *) Data;
    if(Application == Context)
    {
        Application = NULL;
        if(Border)
        {
            ClearBorderWindow(Border);
        }
    }
}

internal void
WindowFocusedHandler(void *Data)
{
    macos_window *Window = (macos_window *) Data;

    UpdateBorderCustomColor(Window->Owner);

    if((AXLibIsWindowStandard(Window)) &&
       ((Window->Owner == Application) ||
       (Application == NULL)))
    {
        CFStringRef DisplayRef = AXLibGetDisplayIdentifierFromWindow(Window->Id);
        if(!DisplayRef) DisplayRef = AXLibGetDisplayIdentifierFromWindowRect(Window->Position, Window->Size);
        ASSERT(DisplayRef);

        macos_space *Space = AXLibActiveSpace(DisplayRef);
        if(AXLibSpaceHasWindow(Space->Id, Window->Id))
        {
            UpdateWindow(Window->Ref);
        }

        AXLibDestroySpace(Space);
        CFRelease(DisplayRef);
    }
}

internal inline void
NewWindowHandler()
{
    if(Border) return;

    AXUIElementRef WindowRef = GetFocusedWindow();
    if(WindowRef)
    {
        uint32_t WindowId = AXLibGetWindowID(WindowRef);
        if(WindowId)
        {
            FuckingMacOSMonitorBoundsChangingBetweenPrimaryAndMainMonitor(WindowRef);
        }
        CFRelease(WindowRef);
    }
}

internal inline void
WindowDestroyedHandler(void *Data)
{
    macos_window *Window = (macos_window *) Data;
    if(Window->Owner == Application)
    {
        UpdateToFocusedWindow();
    }
}

internal inline void
WindowMovedHandler(void *Data)
{
    macos_window *Window = (macos_window *) Data;
    UpdateIfFocusedWindow(Window->Ref);
}

internal inline void
WindowResizedHandler(void *Data)
{
    macos_window *Window = (macos_window *) Data;
    UpdateIfFocusedWindow(Window->Ref);
}

internal inline void
WindowMinimizedHandler(void *Data)
{
    macos_window *Window = (macos_window *) Data;
    if(Window->Owner == Application)
    {
        UpdateToFocusedWindow();
    }
}

internal inline void
SpaceChangedHandler()
{
    macos_space *Space;
    bool Success = AXLibActiveSpace(&Space);
    ASSERT(Success);

    if(Border)
    {
        DestroyBorderWindow(Border);
        Border = NULL;
    }

    if(Space->Type == kCGSSpaceUser)
    {
        NewWindowHandler();
    }

    AXLibDestroySpace(Space);
}

internal inline bool
StringEquals(const char *A, const char *B)
{
    bool Result = (strcmp(A, B) == 0);
    return Result;
}

internal void
UpdateBorderCustomColor(macos_application *FocusedApplication)
{
    AXUIElementRef WindowRef = GetFocusedWindow();
    macos_window *FocusedWindow = AXLibConstructWindow(FocusedApplication, GetFocusedWindow());
    CGSize WindowBounds = FocusedWindow->Size;

    CFStringRef DisplayRef = AXLibGetDisplayIdentifierForMainDisplay();
    CGRect DisplayBounds = AXLibGetDisplayBounds(DisplayRef);
    CFRelease(DisplayRef);

    if (AXLibIsWindowFullscreen(WindowRef) ||
        (WindowBounds.height == CGRectGetHeight(DisplayBounds) &&
        WindowBounds.width == CGRectGetWidth(DisplayBounds)))
    {
        return;
    }

    char *WindowName = FocusedApplication->Name;

    bool CustomColorSpecifiedForWindow = false;

    for(int Index = 0; Index < WindowRules.size(); ++Index)
    {
        window_rule *WindowRule = WindowRules.at(Index);
        if(StringEquals(WindowRule->Owner, WindowName))
        {
            CustomColorSpecifiedForWindow = true;

            if(!WindowRule->DrawBorder)
            {
                UpdateBorderWindowColor(Border, 0x00000000);
                break;
            }

            UpdateBorderWindowColor(Border, WindowRule->Color);
            break;
        }
    }

    if(!CustomColorSpecifiedForWindow)
        UpdateBorderWindowColor(Border, CVarUnsignedValue("focused_border_color"));
}

internal void
CommandHandler(void *Data)
{
    chunkwm_payload *Payload = (chunkwm_payload *) Data;
    if(StringEquals(Payload->Command, "color"))
    {
        token Token = GetToken(&Payload->Message);
        if(Token.Length > 0)
        {
            unsigned Color = TokenToUnsigned(Token);
            if(Border)
            {
                UpdateBorderWindowColor(Border, Color);
            }
        }
    }
    else if(StringEquals(Payload->Command, "clear"))
    {
        if(Border)
        {
            ClearBorderWindow(Border);
        }
    }
    else if(StringEquals(Payload->Command, "rule"))
    {
        window_rule *WindowRule = (window_rule *) malloc(sizeof(window_rule));
        WindowRule->Color = CVarUnsignedValue("focused_border_color");
        WindowRule->DrawBorder = true;

        while(Payload->Message)
        {
            token Token = GetToken(&Payload->Message);

            if (Token.Length <= 0)
                break;

            char *Arg = TokenToString(Token);

            if(StringEquals(Arg, "--owner"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    char *Owner = TokenToString(Value);
                    WindowRule->Owner = Owner;
                }
            }
            else if(StringEquals(Arg, "--color"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    unsigned Color = TokenToUnsigned(Value);
                    WindowRule->Color = Color;
                }
            }
            else if(StringEquals(Arg, "--border"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    bool DrawBorder = TokenToInt(Value);
                    WindowRule->DrawBorder = DrawBorder;
                }
            }
        }

        // NOTE(splintah): prevent double rule.
        bool RuleUpdated = false;
        for(int Index = 0; Index < WindowRules.size(); ++Index)
        {
            if(StringEquals(WindowRules.at(Index)->Owner, WindowRule->Owner))
            {
                WindowRules.at(Index) = WindowRule;
                RuleUpdated = true;
            }
        }

        if(!RuleUpdated)
        {
            WindowRules.push_back(WindowRule);
        }

    }
}

internal inline void
TilingFocusedWindowFloatStatus(void *Data)
{
    uint32_t Status = *(uint32_t *) Data;
    if(Status)
    {
        DrawBorder = false;
        if(Border)
        {
            ClearBorderWindow(Border);
        }
    }
    else
    {
        DrawBorder = true;
        UpdateToFocusedWindow();
    }
}

PLUGIN_MAIN_FUNC(PluginMain)
{
    if((StringEquals(Node, "chunkwm_export_application_launched")) ||
       (StringEquals(Node, "chunkwm_export_window_created")) ||
       (StringEquals(Node, "chunkwm_export_application_unhidden")) ||
       (StringEquals(Node, "chunkwm_export_window_deminimized")))
    {
        NewWindowHandler();
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_application_activated"))
    {
        ApplicationActivatedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_application_deactivated"))
    {
        ApplicationDeactivatedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_window_destroyed"))
    {
        WindowDestroyedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_window_focused"))
    {
        WindowFocusedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_window_moved"))
    {
        WindowMovedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_window_resized"))
    {
        WindowResizedHandler(Data);
        return true;
    }
    else if(StringEquals(Node, "chunkwm_export_window_minimized"))
    {
        WindowMinimizedHandler(Data);
        return true;
    }
    else if((StringEquals(Node, "chunkwm_export_space_changed")) ||
            (StringEquals(Node, "chunkwm_export_display_changed")))
    {
        SpaceChangedHandler();
        return true;
    }
    else if(StringEquals(Node, "chunkwm_daemon_command"))
    {
        CommandHandler(Data);
        return true;
    }
    else if((StringEquals(Node, "Tiling_focused_window_float")) &&
            (SkipFloating))
    {
        TilingFocusedWindowFloatStatus(Data);
        return true;
    }

    return false;
}

PLUGIN_BOOL_FUNC(PluginInit)
{
    API = ChunkwmAPI;
    BeginCVars(&API);

    CreateCVar("focused_border_color", 0xffd5c4a1);
    CreateCVar("focused_border_width", 4);
    CreateCVar("focused_border_radius", 4);
    CreateCVar("focused_border_skip_floating", 0);

    SkipFloating = CVarIntegerValue("focused_border_skip_floating");
    DrawBorder = !SkipFloating;
    CreateBorder(0, 0, 0, 0);
    return true;
}

PLUGIN_VOID_FUNC(PluginDeInit)
{
    if(Border)
    {
        DestroyBorderWindow(Border);
    }
}

CHUNKWM_PLUGIN_VTABLE(PluginInit, PluginDeInit, PluginMain)
chunkwm_plugin_export Subscriptions[] =
{
    chunkwm_export_application_launched,
    chunkwm_export_application_unhidden,
    chunkwm_export_application_activated,
    chunkwm_export_application_deactivated,

    chunkwm_export_window_created,
    chunkwm_export_window_focused,
    chunkwm_export_window_destroyed,
    chunkwm_export_window_moved,
    chunkwm_export_window_resized,
    chunkwm_export_window_minimized,
    chunkwm_export_window_deminimized,

    chunkwm_export_space_changed,
    chunkwm_export_display_changed,
};
CHUNKWM_PLUGIN_SUBSCRIBE(Subscriptions)
CHUNKWM_PLUGIN("Border", "0.2.9")
