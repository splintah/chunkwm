#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <string>

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

#include <vector>

struct border_rule
{
    char *Owner;
    char *Name;
    unsigned Color;
    int Width;
    int Radius;
    bool Ignore;
};

#define internal static

std::vector<border_rule *> BorderRules;

internal macos_application *Application;
internal border_window *Border;
internal bool SkipFloating;
internal bool DrawBorder;
internal chunkwm_api API;

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
    Border = CreateBorderWindow(X, Y, W, H, Width, Radius, Color);
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
ApplyWindowRules()
{
    if(!Application)
        return;
    AXUIElementRef WindowRef = GetFocusedWindow();

    if(!WindowRef)
        return;

    uint32_t WindowId = AXLibGetWindowID(WindowRef);
    if(!WindowId)
        return;

    macos_window *Window = AXLibConstructWindow(Application, WindowRef);

    border_rule *BorderRule = NULL;

    bool WindowMatch = false;
    for(size_t Index = 0;
        Index < BorderRules.size();
        ++Index)
    {
        border_rule *Rule = BorderRules[Index];

        if(Rule->Owner && Window->Owner->Name &&
           Rule->Name && Window->Name &&
           StringEquals(Rule->Owner, Window->Owner->Name) &&
           StringEquals(Rule->Name, Window->Name))
        {
            BorderRule = Rule;
            break;
        }

        if(Rule->Name && Window->Name &&
           !Rule->Owner && !Window->Owner->Name &&
           StringEquals(Rule->Name, Window->Name))
        {
            BorderRule = Rule;
            WindowMatch = true;
        }
        else if(Rule->Owner && Window->Owner->Name &&
               !WindowMatch && StringEquals(Rule->Owner, Window->Owner->Name))
        {
            BorderRule = Rule;
        }
    }

    if(BorderRule == NULL)
    {
        unsigned Color = CVarUnsignedValue("focused_border_color");
        int Width = CVarIntegerValue("focused_border_width");
        int Radius = CVarIntegerValue("focused_border_radius");

        ClearBorderWindow(Border);
        Border = CreateBorderWindow(0, 0, 0, 0, Width, Radius, Color);

        return;
    }

    if(BorderRule->Ignore)
    {
        UpdateBorderWindowColor(Border, 0x00000000);
        ClearBorderWindow(Border);
        return;
    }

    if(BorderRule->Color)
    {
        if(Border)
        {
            ClearBorderWindow(Border);
        }
        if(Border->Width != BorderRule->Width ||
           Border->Radius != BorderRule->Radius ||
           Border->Color != BorderRule->Color)
        {
            ClearBorderWindow(Border);
            Border = CreateBorderWindow(0, 0, 0, 0, BorderRule->Width, BorderRule->Radius, BorderRule->Color);
        }
    }

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
        border_rule *BorderRule = (border_rule *) malloc(sizeof(border_rule));
        BorderRule->Owner = NULL;
        BorderRule->Name = NULL;
        BorderRule->Color = CVarUnsignedValue("focused_border_color");
        BorderRule->Ignore = false;
        BorderRule->Width = CVarIntegerValue("focused_border_width");
        BorderRule->Radius = CVarIntegerValue("focused_border_radius");

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
                    BorderRule->Owner = TokenToString(Value);
                }
            }
            else if(StringEquals(Arg, "--name"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    BorderRule->Name = TokenToString(Value);
                }
            }
            else if(StringEquals(Arg, "--color"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    unsigned Color = TokenToUnsigned(Value);
                    BorderRule->Color = Color;
                }
            }
            else if(StringEquals(Arg, "--ignore"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    bool Ignore = TokenToInt(Value);
                    BorderRule->Ignore = Ignore;
                }
            }
            else if(StringEquals(Arg, "--width"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    int Width = TokenToInt(Value);
                    BorderRule->Width = Width;
                }
            }
            else if(StringEquals(Arg, "--radius"))
            {
                token Value = GetToken(&Payload->Message);
                if(Value.Length > 0)
                {
                    int Radius = TokenToInt(Value);
                    BorderRule->Radius = Radius;
                }
            }
        }

        if(BorderRule->Owner || BorderRule->Name)
        {
            bool RuleChanged = false;
            bool WindowMatch = false;
            for(size_t Index = 0;
                Index < BorderRules.size();
                ++Index)
            {
                border_rule *Rule = BorderRules[Index];

                if(Rule->Owner && BorderRule->Owner && Rule->Name && BorderRule->Name
                    && StringEquals(Rule->Owner, BorderRule->Owner)
                    && StringEquals(Rule->Name, BorderRule->Name))
                {
                    BorderRules[Index] = BorderRule;
                    RuleChanged = true;
                    break;
                }

                if(Rule->Name && BorderRule->Name
                    && StringEquals(Rule->Name, BorderRule->Name))
                {
                    BorderRules[Index] = BorderRule;
                    RuleChanged = true;
                    WindowMatch = true;
                }
                else if(Rule->Owner && BorderRule->Owner
                    && !WindowMatch && StringEquals(Rule->Owner, BorderRule->Owner))
                {
                    BorderRules[Index] = BorderRule;
                    RuleChanged = true;
                }
            }

            if(!RuleChanged)
            {
                BorderRules.push_back(BorderRule);
            }
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
        ApplyWindowRules();
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
        ApplyWindowRules();
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
        ApplyWindowRules();
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
