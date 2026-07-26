#!/usr/bin/env python3
"""
Apply WM_TOUCH synthesis to Wine 11.0 source tree (run from the Wine source root).

Modifies 7 files to implement RegisterTouchWindow / WM_TOUCH dispatch:
  dlls/win32u/message.c     — touch slot table + alloc + NtUser{Get,Close}TouchInput*
                               + WM_TOUCH sentinel intercept in send_hardware_message
  dlls/win32u/win32u.spec   — export the two new NtUser functions
  dlls/win32u/win32syscalls.h — fix SYSCALL_ENTRY for the two new functions
  dlls/wow64win/user.c      — WoW64 thunks for the two new functions
  include/ntuser.h          — declare the two new NtUser functions
  dlls/user32/input.c       — wire stubs to new NtUser calls
  dlls/user32/sysparams.c   — advertise SM_DIGITIZER + SM_MAXIMUMTOUCHES
  dlls/winex11.drv/mouse.c  — dispatch WM_TOUCH from X11DRV_TouchEvent
"""

import sys

def patch(path, old, new, label):
    with open(path, 'r') as f:
        content = f.read()
    if old not in content:
        print(f"ERROR: anchor not found in {path} [{label}]", file=sys.stderr)
        sys.exit(1)
    result = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(result)
    print(f"  patched {path} [{label}]")

# ---------------------------------------------------------------------------
# 1. dlls/win32u/message.c
#    a) Insert touch slot table + NtUser functions before send_hardware_message
#    b) Add WM_TOUCH sentinel intercept at the top of send_hardware_message
# ---------------------------------------------------------------------------

TOUCH_INFRA = """\
/* =========================================================================
 * WM_TOUCH handle ring buffer (WineMA3 patch: grandMA3 onPC touch support)
 *
 * HTOUCHINPUT is encoded as (slot_index + 1).  Allocated in
 * send_hardware_message when winex11.drv fires the WM_TOUCH sentinel;
 * released by NtUserCloseTouchInputHandle called from user32.
 * ========================================================================= */

#define TOUCH_SLOT_COUNT      32
#define TOUCH_SLOT_MAX_POINTS 10

struct touch_slot
{
    TOUCHINPUT inputs[TOUCH_SLOT_MAX_POINTS];
    UINT        count;
    LONG        in_use;  /* atomic: 0 = free, 1 = claimed */
};

static struct touch_slot touch_slots[TOUCH_SLOT_COUNT];
static LONG next_touch_hint;

static HTOUCHINPUT alloc_touch_slot( UINT count, const TOUCHINPUT *inputs )
{
    UINT n = count < TOUCH_SLOT_MAX_POINTS ? count : TOUCH_SLOT_MAX_POINTS;
    int i;

    for (i = 0; i < TOUCH_SLOT_COUNT; i++)
    {
        int idx = (int)((UINT)(InterlockedIncrement( &next_touch_hint ) - 1) % TOUCH_SLOT_COUNT);
        if (!InterlockedCompareExchange( &touch_slots[idx].in_use, 1, 0 ))
        {
            touch_slots[idx].count = n;
            memcpy( touch_slots[idx].inputs, inputs, n * sizeof(TOUCHINPUT) );
            return (HTOUCHINPUT)(ULONG_PTR)(idx + 1);
        }
    }
    ERR( "WM_TOUCH: all %d slots busy, dropping touch event\\n", TOUCH_SLOT_COUNT );
    return NULL;
}

/***********************************************************************
 *           NtUserGetTouchInputInfo   (win32u.@)
 */
BOOL WINAPI NtUserGetTouchInputInfo( HTOUCHINPUT handle, UINT count, TOUCHINPUT *ptr, int size )
{
    ULONG_PTR v = (ULONG_PTR)handle;
    int idx;
    UINT n;

    if (!v || v > TOUCH_SLOT_COUNT)
    {
        RtlSetLastWin32Error( ERROR_INVALID_HANDLE );
        return FALSE;
    }
    idx = (int)v - 1;
    if (!touch_slots[idx].in_use)
    {
        RtlSetLastWin32Error( ERROR_INVALID_HANDLE );
        return FALSE;
    }
    if (!ptr || (UINT)size < sizeof(TOUCHINPUT))
    {
        RtlSetLastWin32Error( ERROR_INVALID_PARAMETER );
        return FALSE;
    }
    FIXME( "WM_TOUCH: GetTouchInputInfo called handle=%p slot=%d\\n", handle, idx );
    n = count < touch_slots[idx].count ? count : touch_slots[idx].count;
    memcpy( ptr, touch_slots[idx].inputs, n * sizeof(TOUCHINPUT) );
    InterlockedExchange( &touch_slots[idx].in_use, 0 );
    return TRUE;
}

/***********************************************************************
 *           NtUserCloseTouchInputHandle   (win32u.@)
 */
BOOL WINAPI NtUserCloseTouchInputHandle( HTOUCHINPUT handle )
{
    ULONG_PTR v = (ULONG_PTR)handle;
    int idx;

    if (!v || v > TOUCH_SLOT_COUNT)
    {
        RtlSetLastWin32Error( ERROR_INVALID_HANDLE );
        return FALSE;
    }
    idx = (int)v - 1;
    InterlockedExchange( &touch_slots[idx].in_use, 0 );
    return TRUE;
}

"""

MSG_C_ANCHOR = """\
/***********************************************************************
 *\t\tsend_hardware_message
 */
NTSTATUS send_hardware_message( HWND hwnd, UINT flags, const INPUT *input, LPARAM lparam )"""

patch("dlls/win32u/message.c",
      MSG_C_ANCHOR,
      TOUCH_INFRA + MSG_C_ANCHOR,
      "insert touch slot table before send_hardware_message")

# Add WM_TOUCH sentinel intercept inside send_hardware_message, before the
# info.* initialisation block.

OLD_SEND_BODY = """\
    info.type     = MSG_HARDWARE;
    info.dest_tid = 0;
    info.hwnd     = hwnd;
    info.flags    = 0;
    info.timeout  = 0;
    info.params   = NULL;

    if (input->type == INPUT_MOUSE && (input->mi.dwFlags & (MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_RIGHTDOWN)))"""

NEW_SEND_BODY = """\
    /* WM_TOUCH sentinel: winex11.drv sends INPUT_HARDWARE with hi.uMsg=WM_TOUCH.
     * Two modes:
     *   Single-point (wParamH != 0xFFFF): wParamL=touch_id, wParamH=TOUCHEVENTF_*,
     *     lparam=MAKELPARAM(norm_x,norm_y) 0-65535 screen coords.
     *   Multi-point  (wParamH == 0xFFFF): wParamL=count,
     *     lparam=(ULONG_PTR) pointer to caller-stack TOUCHINPUT[count] (safe: call
     *     is synchronous and alloc_touch_slot memcpy's before returning).
     * Post to GA_ROOT so DXVK child windows don't swallow the message. */
    if (input->type == INPUT_HARDWARE && input->hi.uMsg == WM_TOUCH)
    {
        HWND root = NtUserGetAncestor( hwnd, GA_ROOT );
        HTOUCHINPUT htouchinput;
        if (!root) root = hwnd;

        if (input->hi.wParamH == 0xFFFF) /* multi-point */
        {
            const TOUCHINPUT *inputs = (const TOUCHINPUT *)(ULONG_PTR)lparam;
            UINT count = input->hi.wParamL;
            if ((htouchinput = alloc_touch_slot( count, inputs )))
            {
                NtUserPostMessage( root, WM_TOUCH, MAKEWPARAM( count, 0 ), (LPARAM)htouchinput );
                NtUserCloseTouchInputHandle( htouchinput );
            }
            return STATUS_SUCCESS;
        }

        /* Single-point mode */
        {
            RECT virtual = NtUserGetVirtualScreenRect( 2 /* MDT_RAW_DPI */ );
            UINT norm_x  = LOWORD( lparam ), norm_y = HIWORD( lparam );
            LONG screen_w = virtual.right  - virtual.left;
            LONG screen_h = virtual.bottom - virtual.top;
            TOUCHINPUT ti = { 0 };

            ti.x         = screen_w ? (LONG)((ULONGLONG)norm_x * screen_w * 100 / 65535) : 0;
            ti.y         = screen_h ? (LONG)((ULONGLONG)norm_y * screen_h * 100 / 65535) : 0;
            ti.hSource   = NULL;
            ti.dwID      = input->hi.wParamL;
            ti.dwFlags   = input->hi.wParamH;
            ti.dwMask    = TOUCHINPUTMASKF_CONTACTAREA;
            ti.dwTime    = 0;
            ti.cxContact = 100;
            ti.cyContact = 100;

            if ((htouchinput = alloc_touch_slot( 1, &ti )))
            {
                NtUserPostMessage( root, WM_TOUCH, MAKEWPARAM( 1, 0 ), (LPARAM)htouchinput );
                NtUserCloseTouchInputHandle( htouchinput );
            }
            return STATUS_SUCCESS;
        }
    }

    info.type     = MSG_HARDWARE;
    info.dest_tid = 0;
    info.hwnd     = hwnd;
    info.flags    = 0;
    info.timeout  = 0;
    info.params   = NULL;

    if (input->type == INPUT_MOUSE && (input->mi.dwFlags & (MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_RIGHTDOWN)))"""

patch("dlls/win32u/message.c", OLD_SEND_BODY, NEW_SEND_BODY,
      "add WM_TOUCH intercept in send_hardware_message")

# ---------------------------------------------------------------------------
# 2. dlls/win32u/win32u.spec — add/update touch exports
#
# NtUserGetTouchInputInfo already exists as "@ stub -syscall" — replace it
# with a real implementation entry (no -syscall: user32 calls via import lib).
# NtUserCloseTouchInputHandle is absent — insert it alphabetically between
# NtUserCloseDesktop and NtUserCloseWindowStation.
# ---------------------------------------------------------------------------

patch(
    "dlls/win32u/win32u.spec",
    "@ stub -syscall NtUserGetTouchInputInfo",
    "@ stdcall -syscall NtUserGetTouchInputInfo(long long ptr long)",
    "replace NtUserGetTouchInputInfo stub with real entry",
)

patch(
    "dlls/win32u/win32u.spec",
    "@ stdcall -syscall NtUserCloseDesktop(long)\n"
    "@ stdcall -syscall NtUserCloseWindowStation(long)",
    "@ stdcall -syscall NtUserCloseDesktop(long)\n"
    "@ stdcall -syscall NtUserCloseTouchInputHandle(long)\n"
    "@ stdcall -syscall NtUserCloseWindowStation(long)",
    "add NtUserCloseTouchInputHandle between CloseDesktop and CloseWindowStation",
)

# ---------------------------------------------------------------------------
# 3. dlls/win32u/win32syscalls.h — fix SYSCALL_STUB / SYSCALL_ENTRY
#
# NtUserGetTouchInputInfo was a stub in the original table with arg size 0.
# We replace it with a real implementation so:
#   a) remove it from ALL_SYSCALL_STUBS (else conflicting stub body generated)
#   b) fix arg sizes: 16 bytes (4 args × 4B on 32-bit), 32 bytes (4 args × 8B on 64-bit)
#
# NtUserCloseTouchInputHandle is new — append it after the last entry in
# ALL_SYSCALLS32 and ALL_SYSCALLS (64-bit) with a fresh ordinal 0x1604.
# ---------------------------------------------------------------------------

# 3a — remove SYSCALL_STUB for NtUserGetTouchInputInfo
patch(
    "dlls/win32u/win32syscalls.h",
    "    SYSCALL_STUB( NtUserGetTopLevelWindow ) \\\n"
    "    SYSCALL_STUB( NtUserGetTouchInputInfo ) \\\n"
    "    SYSCALL_STUB( NtUserGetTouchValidationStatus ) \\",
    "    SYSCALL_STUB( NtUserGetTopLevelWindow ) \\\n"
    "    SYSCALL_STUB( NtUserGetTouchValidationStatus ) \\",
    "remove SYSCALL_STUB for NtUserGetTouchInputInfo",
)

# 3b — fix arg size in ALL_SYSCALLS32 (4 bytes per arg → 4 args = 16 bytes)
patch(
    "dlls/win32u/win32syscalls.h",
    "    SYSCALL_ENTRY( 0x144f, NtUserGetTitleBarInfo, 8 ) \\\n"
    "    SYSCALL_ENTRY( 0x1450, NtUserGetTopLevelWindow, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1451, NtUserGetTouchInputInfo, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1452, NtUserGetTouchValidationStatus, 0 ) \\",
    "    SYSCALL_ENTRY( 0x144f, NtUserGetTitleBarInfo, 8 ) \\\n"
    "    SYSCALL_ENTRY( 0x1450, NtUserGetTopLevelWindow, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1451, NtUserGetTouchInputInfo, 16 ) \\\n"
    "    SYSCALL_ENTRY( 0x1452, NtUserGetTouchValidationStatus, 0 ) \\",
    "fix NtUserGetTouchInputInfo arg size in ALL_SYSCALLS32 (0→16)",
)

# 3c — fix arg size in ALL_SYSCALLS (64-bit, 8 bytes per arg → 4 args = 32 bytes)
patch(
    "dlls/win32u/win32syscalls.h",
    "    SYSCALL_ENTRY( 0x144f, NtUserGetTitleBarInfo, 16 ) \\\n"
    "    SYSCALL_ENTRY( 0x1450, NtUserGetTopLevelWindow, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1451, NtUserGetTouchInputInfo, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1452, NtUserGetTouchValidationStatus, 0 ) \\",
    "    SYSCALL_ENTRY( 0x144f, NtUserGetTitleBarInfo, 16 ) \\\n"
    "    SYSCALL_ENTRY( 0x1450, NtUserGetTopLevelWindow, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1451, NtUserGetTouchInputInfo, 32 ) \\\n"
    "    SYSCALL_ENTRY( 0x1452, NtUserGetTouchValidationStatus, 0 ) \\",
    "fix NtUserGetTouchInputInfo arg size in ALL_SYSCALLS64 (0→32)",
)

# 3d — append NtUserCloseTouchInputHandle to ALL_SYSCALLS32 (4B per arg → 1 arg = 4 bytes)
patch(
    "dlls/win32u/win32syscalls.h",
    "    SYSCALL_ENTRY( 0x1603, NtVisualCaptureBits, 0 )\n"
    "#ifdef _WIN64",
    "    SYSCALL_ENTRY( 0x1603, NtVisualCaptureBits, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1604, NtUserCloseTouchInputHandle, 4 )\n"
    "#ifdef _WIN64",
    "append NtUserCloseTouchInputHandle to ALL_SYSCALLS32",
)

# 3e — append NtUserCloseTouchInputHandle to ALL_SYSCALLS (64-bit, 8B per arg → 8 bytes)
patch(
    "dlls/win32u/win32syscalls.h",
    "    SYSCALL_ENTRY( 0x1603, NtVisualCaptureBits, 0 )\n"
    "#else\n"
    "#define ALL_SYSCALLS ALL_SYSCALLS32",
    "    SYSCALL_ENTRY( 0x1603, NtVisualCaptureBits, 0 ) \\\n"
    "    SYSCALL_ENTRY( 0x1604, NtUserCloseTouchInputHandle, 8 )\n"
    "#else\n"
    "#define ALL_SYSCALLS ALL_SYSCALLS32",
    "append NtUserCloseTouchInputHandle to ALL_SYSCALLS64",
)

# ---------------------------------------------------------------------------
# 4. dlls/wow64win/user.c — add WoW64 thunks for the two new NtUser functions
#
# ALL_SYSCALLS32 in win32syscalls.h generates a dispatch table in
# wow64win/syscall.c that references wow64_NtUserXxx for every SYSCALL_ENTRY.
# For non-stub functions we must provide real thunks in wow64win/user.c.
# ---------------------------------------------------------------------------

patch(
    "dlls/wow64win/user.c",
    "NTSTATUS WINAPI wow64_NtUserCloseWindowStation( UINT *args )\n"
    "{\n"
    "    HWINSTA handle = get_handle( &args );\n"
    "\n"
    "    return NtUserCloseWindowStation( handle );\n"
    "}\n",
    "NTSTATUS WINAPI wow64_NtUserCloseWindowStation( UINT *args )\n"
    "{\n"
    "    HWINSTA handle = get_handle( &args );\n"
    "\n"
    "    return NtUserCloseWindowStation( handle );\n"
    "}\n"
    "\n"
    "NTSTATUS WINAPI wow64_NtUserCloseTouchInputHandle( UINT *args )\n"
    "{\n"
    "    HTOUCHINPUT handle = get_handle( &args );\n"
    "\n"
    "    return NtUserCloseTouchInputHandle( handle );\n"
    "}\n",
    "add wow64_NtUserCloseTouchInputHandle thunk",
)

patch(
    "dlls/wow64win/user.c",
    "NTSTATUS WINAPI wow64_NtUserGetTitleBarInfo( UINT *args )\n"
    "{\n"
    "    HWND hwnd = get_handle( &args );\n"
    "    TITLEBARINFO *info = get_ptr( &args );\n"
    "\n"
    "    return NtUserGetTitleBarInfo( hwnd, info );\n"
    "}\n"
    "\n"
    "NTSTATUS WINAPI wow64_NtUserGetUpdateRect( UINT *args )",
    "NTSTATUS WINAPI wow64_NtUserGetTitleBarInfo( UINT *args )\n"
    "{\n"
    "    HWND hwnd = get_handle( &args );\n"
    "    TITLEBARINFO *info = get_ptr( &args );\n"
    "\n"
    "    return NtUserGetTitleBarInfo( hwnd, info );\n"
    "}\n"
    "\n"
    "NTSTATUS WINAPI wow64_NtUserGetTouchInputInfo( UINT *args )\n"
    "{\n"
    "    HTOUCHINPUT handle = get_handle( &args );\n"
    "    UINT count = get_ulong( &args );\n"
    "    TOUCHINPUT *ptr = get_ptr( &args );\n"
    "    int size = get_ulong( &args );\n"
    "\n"
    "    return NtUserGetTouchInputInfo( handle, count, ptr, size );\n"
    "}\n"
    "\n"
    "NTSTATUS WINAPI wow64_NtUserGetUpdateRect( UINT *args )",
    "add wow64_NtUserGetTouchInputInfo thunk",
)

# ---------------------------------------------------------------------------
# 5. include/ntuser.h — declare the two new NtUser functions
# (user32/input.c reaches ntuser.h via user_private.h → ntuser.h)
# ---------------------------------------------------------------------------

patch(
    "include/ntuser.h",
    "W32KAPI BOOL    WINAPI NtUserGetPointerInfoList( UINT32 id, POINTER_INPUT_TYPE type, UINT_PTR, UINT_PTR, SIZE_T size,",
    "W32KAPI BOOL    WINAPI NtUserCloseTouchInputHandle( HTOUCHINPUT handle );\n"
    "W32KAPI BOOL    WINAPI NtUserGetTouchInputInfo( HTOUCHINPUT handle, UINT count, TOUCHINPUT *ptr, int size );\n"
    "W32KAPI BOOL    WINAPI NtUserGetPointerInfoList( UINT32 id, POINTER_INPUT_TYPE type, UINT_PTR, UINT_PTR, SIZE_T size,",
    "declare NtUserClose/GetTouchInput* in ntuser.h",
)

# ---------------------------------------------------------------------------
# 4. dlls/user32/input.c — wire stubs to the new NtUser calls
# ---------------------------------------------------------------------------

patch(
    "dlls/user32/input.c",
    "BOOL WINAPI CloseTouchInputHandle( HTOUCHINPUT handle )\n"
    "{\n"
    "    FIXME( \"handle %p stub!\\n\", handle );\n"
    "    SetLastError( ERROR_CALL_NOT_IMPLEMENTED );\n"
    "    return FALSE;\n"
    "}",
    "BOOL WINAPI CloseTouchInputHandle( HTOUCHINPUT handle )\n"
    "{\n"
    "    return NtUserCloseTouchInputHandle( handle );\n"
    "}",
    "wire CloseTouchInputHandle",
)

patch(
    "dlls/user32/input.c",
    "BOOL WINAPI GetTouchInputInfo( HTOUCHINPUT handle, UINT count, TOUCHINPUT *ptr, int size )\n"
    "{\n"
    "    FIXME( \"handle %p, count %u, ptr %p, size %u stub!\\n\", handle, count, ptr, size );\n"
    "    SetLastError( ERROR_CALL_NOT_IMPLEMENTED );\n"
    "    return FALSE;\n"
    "}",
    "BOOL WINAPI GetTouchInputInfo( HTOUCHINPUT handle, UINT count, TOUCHINPUT *ptr, int size )\n"
    "{\n"
    "    return NtUserGetTouchInputInfo( handle, count, ptr, size );\n"
    "}",
    "wire GetTouchInputInfo",
)

patch(
    "dlls/user32/input.c",
    "BOOL WINAPI RegisterTouchWindow( HWND hwnd, ULONG flags )\n"
    "{\n"
    "    FIXME( \"hwnd %p, flags %#lx stub!\\n\", hwnd, flags );\n"
    "    return TRUE;\n"
    "}",
    "BOOL WINAPI RegisterTouchWindow( HWND hwnd, ULONG flags )\n"
    "{\n"
    "    TRACE( \"hwnd %p, flags %#lx\\n\", hwnd, flags );\n"
    "    return TRUE;\n"
    "}",
    "upgrade RegisterTouchWindow stub to TRACE",
)

patch(
    "dlls/user32/input.c",
    "BOOL WINAPI UnregisterTouchWindow( HWND hwnd )\n"
    "{\n"
    "    FIXME( \"hwnd %p stub!\\n\", hwnd );\n"
    "    return TRUE;\n"
    "}",
    "BOOL WINAPI UnregisterTouchWindow( HWND hwnd )\n"
    "{\n"
    "    TRACE( \"hwnd %p\\n\", hwnd );\n"
    "    return TRUE;\n"
    "}",
    "upgrade UnregisterTouchWindow stub to TRACE",
)

# ---------------------------------------------------------------------------
# 6. dlls/user32/sysparams.c — advertise touch digitizer capability
#
# Wine returns 0 for SM_DIGITIZER (94) and SM_MAXIMUMTOUCHES (95), which
# tells apps like grandMA3 onPC there is no touchscreen and causes them to
# silently ignore WM_TOUCH messages even when they arrive.
# Return values matching a standard 10-point integrated touchscreen.
# ---------------------------------------------------------------------------

patch(
    "dlls/user32/sysparams.c",
    "INT WINAPI GetSystemMetrics( INT index )\n"
    "{\n"
    "    return NtUserGetSystemMetrics( index );\n"
    "}",
    "INT WINAPI GetSystemMetrics( INT index )\n"
    "{\n"
    "    /* Advertise integrated touch digitizer (WineMA3 patch) */\n"
    "    if (index == 94 /* SM_DIGITIZER */) return 0xC1; /* NID_INTEGRATED_TOUCH|NID_MULTI_INPUT|NID_READY */\n"
    "    if (index == 95 /* SM_MAXIMUMTOUCHES */) return 10;\n"
    "    return NtUserGetSystemMetrics( index );\n"
    "}",
    "advertise SM_DIGITIZER + SM_MAXIMUMTOUCHES in GetSystemMetrics",
)

patch(
    "dlls/user32/sysparams.c",
    "INT WINAPI GetSystemMetricsForDpi( INT index, UINT dpi )\n"
    "{\n"
    "    return NtUserGetSystemMetricsForDpi( index, dpi );\n"
    "}",
    "INT WINAPI GetSystemMetricsForDpi( INT index, UINT dpi )\n"
    "{\n"
    "    if (index == 94 /* SM_DIGITIZER */) return 0xC1;\n"
    "    if (index == 95 /* SM_MAXIMUMTOUCHES */) return 10;\n"
    "    return NtUserGetSystemMetricsForDpi( index, dpi );\n"
    "}",
    "advertise SM_DIGITIZER + SM_MAXIMUMTOUCHES in GetSystemMetricsForDpi",
)

# ---------------------------------------------------------------------------
# 7. dlls/winex11.drv/mouse.c — synthesise WM_TOUCH from X11DRV_TouchEvent
# ---------------------------------------------------------------------------

OLD_TOUCH_EVENT = """\
static BOOL X11DRV_TouchEvent( HWND hwnd, XGenericEventCookie *xev )
{
    RECT virtual = NtUserGetVirtualScreenRect( MDT_RAW_DPI );
    INPUT input = {.type = INPUT_HARDWARE};
    XIDeviceEvent *event = xev->data;
    int flags = 0;
    POINT pos;

    input.mi.dx = event->event_x;
    input.mi.dy = event->event_y;
    map_event_coords( hwnd, event->event, event->root, event->root_x, event->root_y, &input );
    pos.x = input.mi.dx * 65535 / (virtual.right - virtual.left);
    pos.y = input.mi.dy * 65535 / (virtual.bottom - virtual.top);

    switch (event->evtype)
    {
    case XI_TouchBegin:
        input.hi.uMsg = WM_POINTERDOWN;
        flags |= POINTER_MESSAGE_FLAG_NEW;
        TRACE("XI_TouchBegin detail %u pos %dx%d, flags %#x\\n", event->detail, pos.x, pos.y, flags);
        break;
    case XI_TouchEnd:
        input.hi.uMsg = WM_POINTERUP;
        TRACE("XI_TouchEnd detail %u pos %dx%d, flags %#x\\n", event->detail, pos.x, pos.y, flags);
        break;
    case XI_TouchUpdate:
        input.hi.uMsg = WM_POINTERUPDATE;
        TRACE("XI_TouchUpdate detail %u pos %dx%d, flags %#x\\n", event->detail, pos.x, pos.y, flags);
        break;
    }

    input.hi.wParamL = event->detail;
    input.hi.wParamH = POINTER_MESSAGE_FLAG_INRANGE | POINTER_MESSAGE_FLAG_INCONTACT | flags;
    NtUserSendHardwareInput( hwnd, 0, &input, MAKELPARAM( pos.x, pos.y ) );

    return TRUE;
}"""

NEW_TOUCH_EVENT = """\
/* --- WineMA3: active XI2 touch point tracker for multi-finger WM_TOUCH --- */
#define XI2_MAX_TOUCH 10
struct xi2_touch_point { int id; LONG screen_x; LONG screen_y; DWORD flags; };
static struct xi2_touch_point xi2_active[XI2_MAX_TOUCH];
static int xi2_count;

static BOOL X11DRV_TouchEvent( HWND hwnd, XGenericEventCookie *xev )
{
    RECT virtual = NtUserGetVirtualScreenRect( MDT_RAW_DPI );
    INPUT input = {.type = INPUT_HARDWARE};
    INPUT touch_hw = {.type = INPUT_HARDWARE};
    XIDeviceEvent *event = xev->data;
    int flags = 0;
    DWORD touch_flags = 0;
    int ti_idx = -1;
    int i;
    POINT pos;

    input.mi.dx = event->event_x;
    input.mi.dy = event->event_y;
    map_event_coords( hwnd, event->event, event->root, event->root_x, event->root_y, &input );
    pos.x = input.mi.dx * 65535 / (virtual.right - virtual.left);
    pos.y = input.mi.dy * 65535 / (virtual.bottom - virtual.top);

    switch (event->evtype)
    {
    case XI_TouchBegin:
        input.hi.uMsg = WM_POINTERDOWN;
        flags |= POINTER_MESSAGE_FLAG_NEW;
        touch_flags = TOUCHEVENTF_DOWN | TOUCHEVENTF_INRANGE;
        TRACE("XI_TouchBegin detail %u pos %dx%d count %d\\n", event->detail, pos.x, pos.y, xi2_count + 1);
        if (xi2_count < XI2_MAX_TOUCH)
        {
            ti_idx = xi2_count++;
            xi2_active[ti_idx].id       = event->detail;
            xi2_active[ti_idx].screen_x = (LONG)input.mi.dx;
            xi2_active[ti_idx].screen_y = (LONG)input.mi.dy;
            xi2_active[ti_idx].flags    = touch_flags;
        }
        break;
    case XI_TouchEnd:
        input.hi.uMsg = WM_POINTERUP;
        touch_flags = TOUCHEVENTF_UP;
        TRACE("XI_TouchEnd detail %u pos %dx%d count %d\\n", event->detail, pos.x, pos.y, xi2_count);
        for (i = 0; i < xi2_count; i++)
            if (xi2_active[i].id == event->detail)
            {
                ti_idx = i;
                xi2_active[i].screen_x = (LONG)input.mi.dx;
                xi2_active[i].screen_y = (LONG)input.mi.dy;
                xi2_active[i].flags    = touch_flags;
            }
        break;
    case XI_TouchUpdate:
        input.hi.uMsg = WM_POINTERUPDATE;
        touch_flags = TOUCHEVENTF_MOVE | TOUCHEVENTF_INRANGE;
        TRACE("XI_TouchUpdate detail %u pos %dx%d count %d\\n", event->detail, pos.x, pos.y, xi2_count);
        for (i = 0; i < xi2_count; i++)
            if (xi2_active[i].id == event->detail)
            {
                ti_idx = i;
                xi2_active[i].screen_x = (LONG)input.mi.dx;
                xi2_active[i].screen_y = (LONG)input.mi.dy;
                xi2_active[i].flags    = touch_flags;
            }
        break;
    }

    /* Slot 0 is always PRIMARY; clear from others */
    if (xi2_count > 0) xi2_active[0].flags |= TOUCHEVENTF_PRIMARY;
    for (i = 1; i < xi2_count; i++) xi2_active[i].flags &= ~TOUCHEVENTF_PRIMARY;

    /* WM_POINTER* dispatch (existing path, keeps cursor tracking) */
    input.hi.wParamL = event->detail;
    input.hi.wParamH = POINTER_MESSAGE_FLAG_INRANGE | POINTER_MESSAGE_FLAG_INCONTACT | flags;
    NtUserSendHardwareInput( hwnd, 0, &input, MAKELPARAM( pos.x, pos.y ) );

    /* WM_TOUCH synthesis.  Single-point (xi2_count==1): pack coords in lparam.
     * Multi-point (xi2_count>1): pass stack TOUCHINPUT[] via lparam pointer,
     * wParamH=0xFFFF sentinel so send_hardware_message takes the multi path.
     * send_hardware_message copies to a static slot before returning, so the
     * stack array is valid for the entire synchronous call. */
    if (xi2_count > 0)
    {
        if (xi2_count == 1)
        {
            touch_hw.hi.uMsg    = WM_TOUCH;
            touch_hw.hi.wParamL = (WORD)event->detail;
            touch_hw.hi.wParamH = (WORD)xi2_active[0].flags;
            NtUserSendHardwareInput( hwnd, 0, &touch_hw, MAKELPARAM( (WORD)pos.x, (WORD)pos.y ) );
        }
        else
        {
            TOUCHINPUT multi[XI2_MAX_TOUCH];
            for (i = 0; i < xi2_count; i++)
            {
                multi[i].x           = xi2_active[i].screen_x * 100;
                multi[i].y           = xi2_active[i].screen_y * 100;
                multi[i].hSource     = NULL;
                multi[i].dwID        = (DWORD)xi2_active[i].id;
                multi[i].dwFlags     = xi2_active[i].flags;
                multi[i].dwMask      = TOUCHINPUTMASKF_CONTACTAREA;
                multi[i].dwTime      = 0;
                multi[i].dwExtraInfo = 0;
                multi[i].cxContact   = 100;
                multi[i].cyContact   = 100;
            }
            touch_hw.hi.uMsg    = WM_TOUCH;
            touch_hw.hi.wParamL = (WORD)xi2_count;
            touch_hw.hi.wParamH = 0xFFFF;
            NtUserSendHardwareInput( hwnd, 0, &touch_hw, (LPARAM)multi );
        }
    }

    /* Mouse compat: synthesize WM_LBUTTONDOWN/UP for apps that use mouse events */
    if (event->evtype == XI_TouchBegin || event->evtype == XI_TouchEnd)
    {
        INPUT mouse_hw = {.type = INPUT_MOUSE};
        mouse_hw.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK |
                              (event->evtype == XI_TouchBegin ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        mouse_hw.mi.dx = (LONG)pos.x;
        mouse_hw.mi.dy = (LONG)pos.y;
        NtUserSendHardwareInput( hwnd, 0, &mouse_hw, 0 );
    }

    /* Remove lifting point from tracker after sending WM_TOUCH */
    if (event->evtype == XI_TouchEnd && ti_idx >= 0)
    {
        xi2_count--;
        memmove( &xi2_active[ti_idx], &xi2_active[ti_idx + 1],
                 (xi2_count - ti_idx) * sizeof(xi2_active[0]) );
    }

    return TRUE;
}"""

patch("dlls/winex11.drv/mouse.c", OLD_TOUCH_EVENT, NEW_TOUCH_EVENT,
      "add WM_TOUCH synthesis in X11DRV_TouchEvent")

print("\nAll WM_TOUCH patches applied successfully.")
