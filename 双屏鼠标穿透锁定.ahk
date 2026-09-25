;@Ahk2Exe-SetDescription  双屏鼠标穿透工具
;@Ahk2Exe-SetCompanyName  骷髅领域
;@Ahk2Exe-SetCopyright    Copyright (c) 2026 圣骷髅
;@Ahk2Exe-SetFileVersion  1.0
;@Ahk2Exe-SetProductName  双屏鼠标穿透锁定
;@Ahk2Exe-SetProductVersion 1.0
;@Ahk2Exe-SetOrigFilename 双屏鼠标穿透锁定.ahk
; ============================================================
;  双屏鼠标穿透锁定: 穿透快捷键单击 解锁/锁定, 双击 暂停/播放副屏媒体
;  只锁主屏模式: 解锁后5秒未穿透到副屏自动重锁
;  锁定模式(托盘切换, 自动记忆, 默认只锁主屏) | 任务管理器/提权窗口放行
;  配置跟随脚本名.ini; 托盘可改快捷键/开机启动/操作提示
; ============================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------- 全局配置 ----------
if !DllCall("user32.dll\SetProcessDpiAwarenessContext", "Ptr", -4)
    DllCall("user32.dll\SetProcessDPIAware")
MAIN_MONITOR := MonitorGetPrimary()
POLL_MS := 10
CONFIG := A_ScriptDir "\" . RegExReplace(A_ScriptName, "\.(ahk|exe)$", "") . ".ini"
; 首次运行: 旧的固定名配置文件自动迁移(热键/模式记忆不丢失)
if !FileExist(CONFIG) && FileExist(A_ScriptDir "\双屏锁定配置.ini")
    FileCopy(A_ScriptDir "\双屏锁定配置.ini", CONFIG)
showTips := IniRead(CONFIG, "设置", "showTips", "1") = "1"
lockMode := IniRead(CONFIG, "设置", "lockMode", "主屏")          ; "主屏" | "当前屏"
if lockMode != "当前屏"
    lockMode := "主屏"
state := 0, suspended := false, bypass := false, unlockArmed := false, lastRelease := 0
UnlockHotkey := "", PauseHotkey := ""
mL := 0, mT := 0, mR := 0, mB := 0, sL := 0, sT := 0, sR := 0, sB := 0
clipRect := Buffer(16, 0), clipRectSec := Buffer(16, 0)
AUTOSTART_KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
AUTOSTART_NAME := "双屏鼠标穿透锁定"
MEDIA_PROCS := ["msedge.exe", "chrome.exe", "firefox.exe", "potplayer64.exe", "potplayer.exe", "vlc.exe", "wmplayer.exe", "cloudmusic.exe", "kugou.exe", "qqmusic.exe", "foobar2000.exe"]
CHROMIUM_PROCS := ["msedge.exe", "chrome.exe", "firefox.exe"]

; ---------- 核心工具 ----------
GetCursor(&x, &y) {
    pt := Buffer(8, 0)
    DllCall("user32.dll\GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")
}
InMain(x, y) {
    global mL, mT, mR, mB
    return x >= mL && x < mR && y >= mT && y < mB
}
ClipToMain() {
    global clipRect
    DllCall("user32.dll\ClipCursor", "Ptr", clipRect)
}
ClipToSec() {
    global clipRectSec
    DllCall("user32.dll\ClipCursor", "Ptr", clipRectSec)
}
ReleaseClip() {
    DllCall("user32.dll\ClipCursor", "Ptr", 0)
}
ShowTip(t) {
    global showTips
    if showTips
        ToolTip(t), SetTimer((*) => ToolTip(), -1500)
}
SetRect(buf, l, t, r, b) {
    NumPut("Int", l, buf, 0), NumPut("Int", t, buf, 4)
    NumPut("Int", r, buf, 8), NumPut("Int", b, buf, 12)
}
; 向窗口投递按键(句柄直发, 窗口失效静默返回, 不会报错)
SendKey(hwnd, vk) {
    DllCall("user32.dll\PostMessage", "Ptr", hwnd, "UInt", 0x0100, "UPtr", vk, "Ptr", 0)
    DllCall("user32.dll\PostMessage", "Ptr", hwnd, "UInt", 0x0101, "UPtr", vk, "Ptr", 0)
}

; ---------- 前台检测 ----------
; 前台进程是否提权(任务管理器等管理员程序)
IsFgElevated() {
    hWnd := DllCall("user32.dll\GetForegroundWindow", "Ptr")
    if !hWnd
        return false
    pid := 0
    DllCall("user32.dll\GetWindowThreadProcessId", "Ptr", hWnd, "UInt*", &pid)
    if !pid
        return false
    hProc := DllCall("kernel32.dll\OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if !hProc
        return false
    hTok := 0
    DllCall("advapi32.dll\OpenProcessToken", "Ptr", hProc, "UInt", 0x0008, "Ptr*", &hTok)
    DllCall("kernel32.dll\CloseHandle", "Ptr", hProc)
    if !hTok
        return false
    buf := Buffer(4, 0), rl := 0
    ; ReturnLength 必须用变量接收(NULL 会返回 ERROR_NOACCESS 导致检测失效)
    r := DllCall("advapi32.dll\GetTokenInformation", "Ptr", hTok, "Int", 20, "Ptr", buf, "UInt", 4, "UInt*", &rl)
    DllCall("kernel32.dll\CloseHandle", "Ptr", hTok)
    return r && NumGet(buf, 0, "Int") != 0
}
; 提权进程 或 任务管理器窗口 → 临时放行
IsBypassFocus() {
    if IsFgElevated()
        return true
    try
        return WinGetClass(DllCall("user32.dll\GetForegroundWindow", "Ptr")) = "TaskManagerWindow"
    catch
        return false
}

; ---------- 状态机 ----------
; 状态: 0=锁主屏 1=穿透 2=锁副屏(当前屏模式)/副屏自由(主屏模式)
LockCheck() {
    global state, suspended, bypass, lockMode
    if suspended
        return
    if IsBypassFocus() {
        if !bypass
            bypass := true, ReleaseClip(), ShowTip("焦点在系统窗口 · 已临时放行鼠标")
    } else if bypass {
        bypass := false
        GetCursor(&x, &y)
        state := InMain(x, y) ? 0 : 2
        ShowTip("已恢复锁定")
    }
    if bypass
        return
    GetCursor(&x, &y)
    if state = 0 {
        ClipToMain()
    } else if state = 1 {
        if lockMode = "主屏" && !InMain(x, y)
            state := 2, ShowTip("已进入副屏幕 · 移回主屏即重新锁定")
    } else if state = 2 {
        if lockMode = "主屏" {
            if InMain(x, y)
                state := 0, ShowTip("已回到主屏幕 · 重新锁定")
        } else
            ClipToSec()
    }
}
; 穿透快捷键: 单击 = 解锁↔锁定; 双击(500ms内) = 暂停/播放副屏媒体; 放行期间忽略
UnlockDown(*) {
    global unlockArmed
    unlockArmed := true
}
UnlockUp(*) {
    global unlockArmed, suspended, bypass, lastRelease
    if suspended || bypass || !unlockArmed
        return
    unlockArmed := false
    if A_TickCount - lastRelease < 500 {      ; 快速第二次释放 → 双击
        lastRelease := A_TickCount
        SetTimer(DoSingleClick, 0)            ; 取消挂起的单击
        ToggleMedia()
        return
    }
    lastRelease := A_TickCount
    SetTimer(DoSingleClick, -500)             ; 500ms 后执行单击(期间再按则转为双击)
}
; 单击: 穿透 解锁/锁定(按当前模式)
DoSingleClick(*) {
    global state, lockMode
    if state = 0 {
        state := 1, ReleaseClip(), ShowTip("已解锁 · 可穿透到副屏幕")
        if lockMode = "主屏"
            SetTimer(ReLockIfIdle, -5000)     ; 只锁主屏: 5秒未穿透自动重锁
    } else if state = 1 {
        GetCursor(&x, &y)
        if lockMode = "当前屏" && !InMain(x, y)
            state := 2, ClipToSec(), ShowTip("已锁定副屏幕")
        else
            state := 0, ClipToMain(), ShowTip("已锁定主屏幕")
    } else if state = 2 {
        if lockMode = "当前屏"
            state := 1, ReleaseClip(), ShowTip("已解锁 · 可穿透到副屏幕")
        else
            state := 0, ClipToMain(), ShowTip("已锁定主屏幕")
    }
}
; 只锁主屏模式: 解锁后 5 秒未穿透到副屏 → 自动重新锁定
ReLockIfIdle() {
    global state, suspended, bypass, lockMode
    if state = 1 && lockMode = "主屏" && !suspended && !bypass {
        state := 0
        ClipToMain()
        ShowTip("5秒内未穿透 · 已自动重新锁定")
    }
}
; 双击: 暂停/播放 副屏上的媒体(浏览器/播放器/音乐)
ToggleMedia() {
    hwnd := FindMediaOnSec()
    if !hwnd
        return ShowTip("副屏未找到媒体窗口, 无法控制")
    if IsProcIn(WinGetProcessName("ahk_id " hwnd), CHROMIUM_PROCS) {
        ToggleBrowser(hwnd)
        ShowTip("已发送 播放/暂停 · 副屏浏览器")
    } else {
        DllCall("user32.dll\SendMessage", "Ptr", hwnd, "UInt", 0x0319, "UPtr", 0, "Ptr", (0x0E << 16))
        ShowTip("已发送 播放/暂停 · 副屏媒体")
    }
}
; 浏览器: 键盘焦点悄悄转移(活动窗口/前台不变), 发空格+Home, 立即还焦点
; 空格=播放/暂停(网页JS) + 页面滚下一屏(平滑动画); Home=滚回顶部抵消滚动
ToggleBrowser(hwnd) {
    tid := DllCall("user32.dll\GetWindowThreadProcessId", "Ptr", hwnd, "Ptr", 0, "UInt")
    myTid := DllCall("kernel32.dll\GetCurrentThreadId", "UInt")
    prev := DllCall("user32.dll\GetFocus", "Ptr")
    DllCall("user32.dll\AttachThreadInput", "UInt", myTid, "UInt", tid, "Int", 1)
    DllCall("user32.dll\SetFocus", "Ptr", hwnd)
    Sleep(80)                                ; 等 Chromium 更新内部焦点
    SendKey(hwnd, 0x20)                      ; 空格
    Sleep(120)                               ; 等平滑滚动动画完成
    SendKey(hwnd, 0x24)                      ; Home
    Sleep(50)
    if prev {                                ; 还回键盘焦点
        pt := DllCall("user32.dll\GetWindowThreadProcessId", "Ptr", prev, "Ptr", 0, "UInt")
        DllCall("user32.dll\AttachThreadInput", "UInt", myTid, "UInt", pt, "Int", 1)
        DllCall("user32.dll\SetFocus", "Ptr", prev)
        DllCall("user32.dll\AttachThreadInput", "UInt", myTid, "UInt", pt, "Int", 0)
    }
    DllCall("user32.dll\AttachThreadInput", "UInt", myTid, "UInt", tid, "Int", 0)
}
; 副屏上找媒体窗口: 中心落在副屏; 媒体进程取最大, 无媒体取最大窗口兜底
FindMediaOnSec() {
    global sL, sT, sR, sB
    mediaBest := 0, mediaArea := 0
    best := 0, bestArea := 0
    for h in WinGetList() {
        try {
            if WinGetMinMax("ahk_id " h) = -1   ; 跳过最小化
                continue
            WinGetPos(&x, &y, &w, &hh, "ahk_id " h)
            if w <= 0 || hh <= 0
                continue
            cx := x + w / 2, cy := y + hh / 2
            if cx < sL || cx >= sR || cy < sT || cy >= sB   ; 窗口中心在副屏
                continue
            pn := WinGetProcessName("ahk_id " h)
            if pn = "explorer.exe" || pn = "dwm.exe" || pn = "AutoHotkey64.exe"
                continue
            area := w * hh
            if IsProcIn(pn, MEDIA_PROCS) {
                if area > mediaArea            ; 媒体窗口取最大(避开画中画等瞬态小窗)
                    mediaBest := h, mediaArea := area
            } else if area > bestArea
                best := h, bestArea := area    ; 非媒体窗口记最大兜底
        } catch
            continue
    }
    return mediaBest ? mediaBest : best
}
IsProcIn(pn, list) {
    for m in list
        if pn = m
            return true
    return false
}
PauseToggle(*) {
    global suspended, state, PauseHotkey
    suspended := !suspended
    if suspended
        ReleaseClip(), ShowTip("已暂停 · 鼠标完全自由 (" . DisplayHotkey(PauseHotkey) . " 恢复)")
    else {
        GetCursor(&x, &y)
        state := InMain(x, y) ? 0 : 2
        ShowTip("已恢复锁定")
    }
}
; 退出时释放锁定(回调必须返回 0, 否则 ExitApp 会被取消)
Cleanup(*) {
    DllCall("user32.dll\ClipCursor", "Ptr", 0)
    return 0
}
OnExit Cleanup

; ---------- 热键处理 ----------
RegisterHotkeys(hkUnlock, hkPause) {
    global UnlockHotkey, PauseHotkey
    if UnlockHotkey != "" && UnlockHotkey != hkUnlock {
        Hotkey("*" . UnlockHotkey, UnlockDown, "Off")
        Hotkey("*" . UnlockHotkey . " up", UnlockUp, "Off")
    }
    if PauseHotkey != "" && PauseHotkey != hkPause
        Hotkey(PauseHotkey, PauseToggle, "Off")
    if UnlockHotkey != hkUnlock {
        Hotkey("*" . hkUnlock, UnlockDown, "On")
        Hotkey("*" . hkUnlock . " up", UnlockUp, "On")
    }
    if PauseHotkey != hkPause
        Hotkey(hkPause, PauseToggle, "On")
    UnlockHotkey := hkUnlock, PauseHotkey := hkPause
}
; 等待用户按下新快捷键; 取消/Esc/超时返回空串
CaptureHotkey() {
    ih := InputHook()
    ih.KeyOpt("{All}", "E")                                    ; 任意键按下即结束
    ih.KeyOpt("{LControl}{RControl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}", "-E") ; 纯修饰键不结束
    ih.Start(), ih.Wait(30)                                    ; 最多等 30 秒
    if ih.InProgress {
        ih.Stop()
        return ""
    }
    key := ih.EndKey
    if ih.EndReason != "EndKey" || key = "Escape" || key = ""
        return ""
    return RegExReplace(ih.EndMods, "[<>](.)(?:>\1)?", "$1") . key
}
; AHK 记法转可读, 如 "^+a" → "Ctrl+Shift+A"
DisplayHotkey(hk) {
    key := RegExReplace(hk, "^[#!^+]+", "")
    if StrLen(key) = 1 && RegExMatch(key, "[a-z]")
        key := Format("{:U}", key)
    mods := ""
    if InStr(hk, "#")
        mods .= "Win+"
    if InStr(hk, "!")
        mods .= "Alt+"
    if InStr(hk, "^")
        mods .= "Ctrl+"
    if InStr(hk, "+")
        mods .= "Shift+"
    return mods . key
}
; 修改某一类快捷键; kind: "穿透" | "暂停"
SetHotkey(kind) {
    global UnlockHotkey, PauseHotkey, CONFIG
    isUnlock := kind = "穿透"
    display := isUnlock ? "穿透" : "暂停/恢复"
    other := isUnlock ? PauseHotkey : UnlockHotkey
    ToolTip("修改「" . display . "」快捷键`n当前: " . DisplayHotkey(isUnlock ? UnlockHotkey : PauseHotkey) . "`n请按下新的组合键或单键, 按 Esc 取消")
    new := CaptureHotkey()
    ToolTip()
    if new = ""
        return ShowTip("已取消修改, 快捷键未变")
    if new = other
        return ShowTip("与「" . (isUnlock ? "暂停/恢复" : "穿透") . "」快捷键相同, 请重试")
    RegisterHotkeys(isUnlock ? new : UnlockHotkey, isUnlock ? PauseHotkey : new)
    IniWrite(new, CONFIG, "热键", kind)
    ShowTip("「" . display . "」快捷键已改为: " . DisplayHotkey(new))
}
SetUnlockHotkey(*) => SetHotkey("穿透")
SetPauseHotkey(*) => SetHotkey("暂停")

; ---------- 托盘设置 ----------
; 锁定模式(托盘切换, 自动记忆)
SetLockMode(mode) {
    global lockMode, state, bypass, CONFIG
    if mode = lockMode
        return
    lockMode := mode
    IniWrite(mode, CONFIG, "设置", "lockMode")
    UpdateLockMenu()
    if state = 1 || bypass        ; 穿透中/放行期间: 只记模式, 不立即锁定
        return ShowTip("锁定模式: " . mode)
    GetCursor(&x, &y)                                        ; 立即按新模式锁定
    if mode = "当前屏" && !InMain(x, y)
        state := 2, ClipToSec()
    else
        state := 0, ClipToMain()
    ShowTip("锁定模式: " . mode)
}
LockMainOnly(*) => SetLockMode("主屏")
LockPerScreen(*) => SetLockMode("当前屏")
UpdateLockMenu() {
    global lockMode
    A_TrayMenu.Uncheck("只锁定主屏"), A_TrayMenu.Uncheck("主副屏单独锁")
    A_TrayMenu.Check(lockMode = "当前屏" ? "主副屏单独锁" : "只锁定主屏")
}
; 操作提示开关
ToggleTips(*) {
    global showTips, CONFIG
    showTips := !showTips
    IniWrite(showTips ? "1" : "0", CONFIG, "设置", "showTips")
    UpdateTipsMenu()
    ShowTip(showTips ? "操作提示已开启" : "操作提示已关闭")
}
UpdateTipsMenu() {
    global showTips
    A_TrayMenu.Uncheck("操作提示")
    if showTips
        A_TrayMenu.Check("操作提示")
}
; 开机启动开关(写当前用户 Run 键, 跟随实际运行载体, 默认关闭)
IsAutostart() {
    global AUTOSTART_KEY, AUTOSTART_NAME
    try
        return RegRead(AUTOSTART_KEY, AUTOSTART_NAME) != ""
    catch
        return false
}
ToggleAutostart(*) {
    global AUTOSTART_KEY, AUTOSTART_NAME
    if IsAutostart()
        RegDelete(AUTOSTART_KEY, AUTOSTART_NAME), ShowTip("已关闭开机启动")
    else
        RegWrite('"' . A_ScriptFullPath . '"', "REG_SZ", AUTOSTART_KEY, AUTOSTART_NAME), ShowTip("已开启开机启动")
    UpdateAutostartMenu()
}
UpdateAutostartMenu() {
    A_TrayMenu.Uncheck("开机启动")
    if IsAutostart()
        A_TrayMenu.Check("开机启动")
}

; ---------- 托盘菜单 ----------
m := A_TrayMenu
m.Delete()
m.Add("只锁定主屏", LockMainOnly)
m.Add("主副屏单独锁", LockPerScreen)
m.Add()
m.Add("开机启动", ToggleAutostart)
m.Add("操作提示", ToggleTips)
m.Add()
m.Add("修改穿透快捷键...", SetUnlockHotkey)
m.Add("修改暂停/恢复快捷键...", SetPauseHotkey)
m.Add()
m.Add("退出", (*) => ExitApp())
UpdateLockMenu(), UpdateTipsMenu(), UpdateAutostartMenu()

; ---------- 启动 ----------
MonitorGet(MAIN_MONITOR, &mL, &mT, &mR, &mB)
SetRect(clipRect, mL, mT, mR, mB)
; 找到副屏(排除主屏的第一个显示器); 单屏时退化为主屏矩形
secMonitor := 0
Loop MonitorGetCount() {
    if A_Index != MAIN_MONITOR {
        secMonitor := A_Index
        break
    }
}
if secMonitor && MonitorGet(secMonitor, &sL, &sT, &sR, &sB)
    SetRect(clipRectSec, sL, sT, sR, sB)
else
    SetRect(clipRectSec, mL, mT, mR, mB)

; 读取上次保存的快捷键并注册; 配置异常时回退默认
try
    RegisterHotkeys(IniRead(CONFIG, "热键", "穿透", "^NumpadMult"), IniRead(CONFIG, "热键", "暂停", "^NumpadDiv"))
catch
    RegisterHotkeys("^NumpadMult", "^NumpadDiv")
SetTimer(LockCheck, POLL_MS)
