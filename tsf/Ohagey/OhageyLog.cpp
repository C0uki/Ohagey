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
        // The body every line goes through. Split out of Log() so the module
        // identity can be written without consulting the switch.
        void AppendLine(const char* line)
        {
            wchar_t path[MAX_PATH] = {L'\0'};
            if (!LogPath(path, ARRAYSIZE(path)))
            {
                return;
            }

            // Shared read/write: every application with the IME loaded writes
            // here, and the user may have the file open in an editor.
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

            char stamped[1200] = {'\0'};
            const int used = _snprintf_s(stamped, _TRUNCATE, "%02d:%02d:%02d.%03d [%lu] %s\r\n",
                                         now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
                                         GetCurrentProcessId(), line);
            if (used > 0)
            {
                DWORD ignored = 0;
                WriteFile(file, stamped, static_cast<DWORD>(used), &ignored, nullptr);
            }
            CloseHandle(file);
        }
    }

    void LogModuleIdentity()
    {
        // Once per process, and **not** behind the diagnostic switch.
        //
        // ── Why this one line is always written ────────────────────────────
        //
        // A DLL cannot be replaced while it is loaded, so a running application
        // keeps whatever build it started with. Every application on the
        // machine therefore runs a possibly different Ohagey, and nothing on
        // screen says which. Six times in one day a fix was declared not to
        // work when the process under test simply had not loaded it -- each
        // time costing a round trip, and each time "resolved" by asking a human
        // to compare process start times against a swap time.
        //
        // The file's own size and write time settle it: they come from the
        // module actually mapped into this process, and they compare directly
        // against the build on disk. One line per process, no user text, and it
        // is the line that makes every other line in this file trustworthy --
        // which is why it is not something to have to switch on first.
        static volatile LONG written = 0;
        if (InterlockedExchange(&written, 1) != 0)
        {
            return;
        }

        HMODULE self = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                    | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                reinterpret_cast<LPCWSTR>(&LogModuleIdentity),
                                &self))
        {
            return;
        }

        wchar_t modulePath[MAX_PATH] = {L'\0'};
        if (GetModuleFileNameW(self, modulePath, ARRAYSIZE(modulePath)) == 0)
        {
            return;
        }

        WIN32_FILE_ATTRIBUTE_DATA info = {};
        SYSTEMTIME built = {};
        unsigned long long bytes = 0;
        if (GetFileAttributesExW(modulePath, GetFileExInfoStandard, &info))
        {
            FILETIME local = {};
            FileTimeToLocalFileTime(&info.ftLastWriteTime, &local);
            FileTimeToSystemTime(&local, &built);
            bytes = (static_cast<unsigned long long>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
        }

        char narrowPath[MAX_PATH * 3] = {'\0'};
        WideCharToMultiByte(CP_UTF8, 0, modulePath, -1, narrowPath,
                            static_cast<int>(sizeof(narrowPath)), nullptr, nullptr);

        char line[1024] = {'\0'};
        if (_snprintf_s(line, _TRUNCATE,
                        "module: %s  %llu bytes  built %04d-%02d-%02d %02d:%02d:%02d",
                        narrowPath, bytes,
                        built.wYear, built.wMonth, built.wDay,
                        built.wHour, built.wMinute, built.wSecond) > 0)
        {
            AppendLine(line);
        }
    }

    void Log(const char* format, ...)
    {
        if (!Enabled())
        {
            return;
        }

        char line[1024] = {'\0'};
        va_list args;
        va_start(args, format);
        const int written = _vsnprintf_s(line, sizeof(line), _TRUNCATE, format, args);
        va_end(args);
        if (written < 0)
        {
            return;
        }

        AppendLine(line);
    }
}
