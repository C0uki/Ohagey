#include "OhageyLog.h"

#include <windows.h>
#include <shlobj.h>
#include <strsafe.h>
#include <cstdarg>
#include <cstdio>

namespace Ohagey
{
    namespace
    {
        // 1 MiB, matching the engine's log. Past that the file is started
        // again rather than rotated: this is a development aid, and the
        // interesting lines are always the last ones.
        const LONGLONG kMaximumBytes = 1 << 20;

        // -1 not yet asked, 0 off, 1 on.
        volatile LONG g_enabled = -1;

        // Off unless HKCU\Software\Ohagey\DiagnosticLog is a non-zero DWORD.
        //
        // This runs on the typing path, inside the user's applications, and
        // opens a file twice per conversion. That is the right price while
        // chasing something and no price worth paying the rest of the time: a
        // shipped IME has no business touching the disk on every space bar
        // because a maintainer once needed to see an HRESULT.
        //
        // Read once and cached -- a registry query per line would cost more
        // than the writing does. Turning it on therefore applies to
        // applications started afterwards, which is worth knowing when the
        // file stays empty: the same trap as replacing the DLL.
        bool Enabled()
        {
            const LONG cached = g_enabled;
            if (cached >= 0)
            {
                return cached != 0;
            }

            DWORD value = 0;
            DWORD size = sizeof(value);
            LONG on = 0;
            if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Ohagey", L"DiagnosticLog",
                             RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS
                && value != 0)
            {
                on = 1;
            }
            InterlockedExchange(&g_enabled, on);
            return on != 0;
        }

        bool LogPath(wchar_t* buffer, size_t count)
        {
            PWSTR local = nullptr;
            if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local)))
            {
                return false;
            }
            const HRESULT hr = StringCchPrintfW(buffer, count, L"%s\\Ohagey\\tsf.log", local);
            CoTaskMemFree(local);
            return SUCCEEDED(hr);
        }
    }

    void Log(const char* format, ...)
    {
        if (!Enabled())
        {
            return;
        }

        wchar_t path[MAX_PATH] = {L'\0'};
        if (!LogPath(path, ARRAYSIZE(path)))
        {
            return;
        }

        // Shared read/write: every application with the IME loaded writes here,
        // and the user may have the file open in an editor while doing so.
        HANDLE file = CreateFileW(path, FILE_APPEND_DATA,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            return;
        }

        LARGE_INTEGER size = {};
        if (GetFileSizeEx(file, &size) && size.QuadPart > kMaximumBytes)
        {
            CloseHandle(file);
            file = CreateFileW(path, GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file == INVALID_HANDLE_VALUE)
            {
                return;
            }
        }

        SYSTEMTIME now = {};
        GetLocalTime(&now);

        char line[1024] = {'\0'};
        int used = _snprintf_s(line, _TRUNCATE, "%02d:%02d:%02d.%03d [%lu] ",
                               now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
                               GetCurrentProcessId());
        if (used < 0)
        {
            CloseHandle(file);
            return;
        }

        va_list args;
        va_start(args, format);
        const int written = _vsnprintf_s(line + used, sizeof(line) - used, _TRUNCATE, format, args);
        va_end(args);
        if (written < 0)
        {
            CloseHandle(file);
            return;
        }

        size_t length = 0;
        if (SUCCEEDED(StringCchLengthA(line, ARRAYSIZE(line), &length)))
        {
            DWORD ignored = 0;
            WriteFile(file, line, static_cast<DWORD>(length), &ignored, nullptr);
            WriteFile(file, "\r\n", 2, &ignored, nullptr);
        }
        CloseHandle(file);
    }
}
