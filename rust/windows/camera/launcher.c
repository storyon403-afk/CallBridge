// 便携包用固定的嵌入式 Python 启动视频进程；不依赖 PATH，也不改变共享帧协议。
// 子进程先挂入 Job 再运行，适配器被强制结束时不会留下持有摄像头的孤儿进程。
#ifndef UNICODE
#define UNICODE 1
#endif
#ifndef _UNICODE
#define _UNICODE 1
#endif
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv) {
    const wchar_t *mode = NULL;
    if (argc == 2 && (!wcscmp(argv[1], L"--obs-check") || !wcscmp(argv[1], L"--memory-check")))
        mode = argv[1];
    else if (argc == 3 && !wcscmp(argv[1], L"--obs-send") && !wcscmp(argv[2], L"--confirm-virtual-video"))
        mode = L"--obs-send --confirm-virtual-video";
    if (!mode) { fputs("{\"error\":\"Invalid camera arguments\"}\n", stdout); return 2; }
    wchar_t base[32768], python[32768], command[32768];
    DWORD length = GetModuleFileNameW(NULL, base, 32768);
    if (!length || length >= 32768) return 1;
    wchar_t *slash = wcsrchr(base, L'\\');
    if (!slash) return 1;
    *slash = 0;
    if (swprintf(python, 32768, L"%ls\\python\\python.exe", base) < 0 ||
        swprintf(command, 32768, L"\"%ls\" -I \"%ls\\camera_sender.py\" %ls", python, base, mode) < 0) return 1;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        if (job) CloseHandle(job);
        return 1;
    }
    STARTUPINFOW start = {0};
    start.cb = sizeof(start);
    start.dwFlags = STARTF_USESTDHANDLES;
    start.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    start.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    start.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessW(python, command, NULL, NULL, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW,
                        NULL, base, &start, &process)) {
        CloseHandle(job);
        fputs("{\"error\":\"Cannot start bundled Python\"}\n", stdout);
        return 1;
    }
    if (!AssignProcessToJobObject(job, process.hProcess) || ResumeThread(process.hThread) == (DWORD)-1) {
        TerminateProcess(process.hProcess, 1);
        WaitForSingleObject(process.hProcess, INFINITE);
        CloseHandle(process.hThread); CloseHandle(process.hProcess); CloseHandle(job);
        return 1;
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    return (int)code;
}
