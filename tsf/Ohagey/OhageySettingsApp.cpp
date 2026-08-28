// Opening the settings app from inside the user's application.

#include "OhageySettingsApp.h"
#include "OhageyLog.h"

#include <windows.h>
#include <shellapi.h>
#include <string>

namespace Ohagey
{
    namespace
    {
        const wchar_t kSettingsExeName[] = L"OhageySettings.exe";

        // The same method EngineClient::EnginePath uses, for the same reason:
        // the settings app sits beside this DLL (decision 0033), and asking the
        // module where it is avoids a registry value that could disagree with
        // where the files actually ended up.
        //
        // GetModuleHandleEx by address rather than by name: the DLL is renamed
        // in place during development so a running build can be replaced
        // (handover section 4), and a name lookup would find the wrong file --
        // or none.
        bool SettingsAppPath(std::wstring* out)
        {
            HMODULE self = nullptr;
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                        | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                    reinterpret_cast<LPCWSTR>(&SettingsAppPath),
                                    &self))
            {
                return false;
            }

            wchar_t modulePath[MAX_PATH] = {};
            const DWORD written = GetModuleFileNameW(self, modulePath, MAX_PATH);
            if (written == 0 || written >= MAX_PATH) return false;

            std::wstring path(modulePath, written);
            const size_t slash = path.find_last_of(L'\\');
            if (slash == std::wstring::npos) return false;

            path.resize(slash + 1);
            path += kSettingsExeName;
            *out = path;
            return true;
        }
    }

    bool LaunchSettingsApp()
    {
        std::wstring path;
        if (!SettingsAppPath(&path)) return false;

        // ShellExecuteEx rather than CreateProcess, which is what the engine
        // gets started with: this one has a window and a user waiting for it,
        // and the shell is what decides how such a thing is shown.
        //
        // NOASYNC because the host application -- not Ohagey -- owns this
        // thread and may go on to do anything, including exit.
        SHELLEXECUTEINFOW info = {};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
        info.lpFile = path.c_str();
        info.nShow = SW_SHOWNORMAL;

        const BOOL started = ShellExecuteExW(&info);
        if (!started)
        {
            // Worth a line: this is the only failure a user can see and not
            // explain. The log says nothing about what was typed, and the
            // reason here is a Windows error code, not content.
            Log("settings app did not start (error %lu)", GetLastError());
            return false;
        }

        return true;
    }
}
