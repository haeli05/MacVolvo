/* Native Win32 integration probe, used only in a disposable test prefix.
 * Compile the child with -DMACVOLVO_DISPLAY_FIX_CHILD as deadlock.exe. */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#ifdef MACVOLVO_DISPLAY_FIX_CHILD
#define MACVOLVO_DISPLAY_FIX_GEOMETRY_ONLY
#endif
#include "gptk4_display_fix.h"

int main(int argc,char **argv) {
    if(argc!=2)return 2;
#ifdef MACVOLVO_DISPLAY_FIX_CHILD
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    MONITORINFO monitor={0};monitor.cbSize=sizeof(monitor);
    if(!GetMonitorInfoW(MonitorFromPoint((POINT){0,0},MONITOR_DEFAULTTOPRIMARY),&monitor))return 3;
    LONG width=monitor.rcMonitor.right-monitor.rcMonitor.left;
    LONG height=monitor.rcMonitor.bottom-monitor.rcMonitor.top;
    BOOL windowed=!strcmp(argv[1],"windowed");
    BOOL correct=!strcmp(argv[1],"correct");
    BOOL offset=!strcmp(argv[1],"offset");
    BOOL disabled=!strcmp(argv[1],"disabled");
    WNDCLASSW klass={0};klass.lpfnWndProc=DefWindowProcW;
    klass.hInstance=GetModuleHandleW(NULL);klass.lpszClassName=L"MacVolvoDisplayFixture";
    if(!RegisterClassW(&klass))return 4;
    HWND window=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,klass.lpszClassName,L"MacVolvo display test",
        windowed?WS_OVERLAPPEDWINDOW:WS_POPUP,monitor.rcMonitor.left+(offset?100:0),monitor.rcMonitor.top+(offset?100:0),
        windowed?800:width+(correct?0:200),windowed?600:height+(correct?0:150),NULL,NULL,klass.hInstance,NULL);
    if(!window)return 5;
    SetWindowPos(window,HWND_BOTTOM,0,0,0,0,SWP_NOACTIVATE|SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW);
    /* Let Cocoa settle the decorated window's initial Retina rounding. */
    if(windowed) {
        ULONGLONG settle=GetTickCount64()+500;
        while(GetTickCount64()<settle) {
            MSG message;
            while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)) {
                TranslateMessage(&message);DispatchMessageW(&message);
            }
            Sleep(10);
        }
    }
    RECT before,after;GetClientRect(window,&before);
    ULONGLONG end=GetTickCount64()+1800;
    while(GetTickCount64()<end) {
        MSG message;
        while(PeekMessageW(&message,NULL,0,0,PM_REMOVE)) {
            TranslateMessage(&message);DispatchMessageW(&message);
        }
        Sleep(10);
    }
    GetClientRect(window,&after);
    BOOL repaired=after.right==width && after.bottom==height;
    BOOL unchanged=EqualRect(&before,&after);
    BOOL ok=windowed||offset||disabled?unchanged:repaired;
    printf("case=%s before=%ldx%ld after=%ldx%ld monitor=%ldx%ld result=%s\n",
           argv[1],before.right,before.bottom,after.right,after.bottom,width,height,ok?"PASS":"FAIL");
    DestroyWindow(window);UnregisterClassW(klass.lpszClassName,klass.hInstance);
    return ok?0:6;
#else
    SetEnvironmentVariableW(L"MACVOLVO_GPTK4_DISPLAY_FIX",!strcmp(argv[1],"disabled")?L"0":L"1");
    MVDisplayWatcher watcher=mvStartDisplayWatcher();
    /* Let the initial check expire: the later game window must trigger an event. */
    Sleep(4200);
    WCHAR path[4096],command[8192];
    if(!GetModuleFileNameW(NULL,path,4096))return 7;
    WCHAR *slash=wcsrchr(path,L'\\');if(!slash)return 8;
    wcscpy(slash+1,L"deadlock.exe");
    swprintf(command,8192,L"\"%ls\" %hs",path,argv[1]);
    STARTUPINFOW startup={0};startup.cb=sizeof(startup);
    PROCESS_INFORMATION process={0};
    if(!CreateProcessW(path,command,NULL,NULL,TRUE,0,NULL,NULL,&startup,&process))return 9;
    DWORD wait=WaitForSingleObject(process.hProcess,10000),code=10;
    if(wait==WAIT_OBJECT_0)GetExitCodeProcess(process.hProcess,&code);
    else TerminateProcess(process.hProcess,10);
    CloseHandle(process.hThread);CloseHandle(process.hProcess);
    mvStopDisplayWatcher(watcher);
    return (int)code;
#endif
}
