/* steamwebhelper.exe stand-in: runs steamwebhelper_real.exe (same folder) with the same
 * command line plus --in-process-gpu, and returns its exit code.
 *
 * On Wine 11 for macOS, Steam's browser must draw with its GPU on (GPU off draws black), and
 * each Wine process has its own Cocoa windows, so Chrome's separate GPU process cannot
 * present into the browser's window. Steam drops -cef-in-process-gpu once GPU web views are
 * on, so the flag is added here. Child processes Chrome starts use the real executable.
 *
 * Steam tracks and ends this process, not the real helper, so the real one runs in a job that
 * closes with this process: when Steam ends a helper it gave up on, nothing is left behind
 * (otherwise each of Steam's restarts orphaned a browser, until macOS ran out of processes).
 *
 * WEBHELPER_EXTRA_ARGS (environment, optional) is appended too, for testing other Chrome flags.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -municode -o steamwebhelper.exe webhelper_wrapper.c */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <wchar.h>
#include "gptk4_display_fix.h"

static const WCHAR extra[] = L" --in-process-gpu";

int wmain(void)
{
    WCHAR path[MAX_PATH], more[1024] = L"", *slash, *cmd, *args = GetCommandLineW();
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    BOOL quoted = FALSE;
    size_t len;

    if (!GetModuleFileNameW(NULL, path, MAX_PATH)) return 1;
    if (!(slash = wcsrchr(path, L'\\'))) return 1;
    /* Never run in the real helper's place: that would start itself without end. */
    if (!_wcsicmp(slash + 1, L"steamwebhelper_real.exe")) return 1;
    wcscpy(slash + 1, L"steamwebhelper_real.exe");

    /* Skip our own program name (quoted or not) in the command line. */
    for (; *args && (quoted || (*args != L' ' && *args != L'\t')); args++)
        if (*args == L'"') quoted = !quoted;

    if (GetEnvironmentVariableW(L"WEBHELPER_EXTRA_ARGS", more + 1, (DWORD)(sizeof(more) / sizeof(*more)) - 1)) more[0] = L' ';
    len = wcslen(path) + wcslen(args) + wcslen(extra) + wcslen(more) + 3;
    if (!(cmd = HeapAlloc(GetProcessHeap(), 0, len * sizeof(WCHAR)))) return 1;
    swprintf(cmd, len, L"\"%ls\"%ls%ls%ls", path, args, extra, more);

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit = {0};
    HANDLE job = CreateJobObjectW(NULL, NULL);
    limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit, sizeof(limit))) return 1;
    if (!CreateProcessW(path, cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) return 1;
    if (!AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 1); return 1; }
    ResumeThread(pi.hThread);
    MVDisplayWatcher watcher=mvStartDisplayWatcher();
    WaitForSingleObject(pi.hProcess, INFINITE);
    mvStopDisplayWatcher(watcher);
    GetExitCodeProcess(pi.hProcess, &code);
    return code;
}
