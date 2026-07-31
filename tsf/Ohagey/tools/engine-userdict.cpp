// Does registering a word actually make it convert? (decision 0026)
//
// The engine can store an entry, hand it to the converter and report success
// without any of that reaching the candidate list — the reading has to be
// katakana, the part of speech has to map to ids the converter knows, and the
// cost has to beat the built-in dictionary's guesses. None of that is visible
// from the return value of RegisterWord, so it is measured here.
//
// ── Your own dictionary is not touched ──────────────────────────────────────
//
// The engine reads LOCALAPPDATA to find its per-user directory (decision 0024).
// This sets it to a scratch path before launching, so the words registered here
// are thrown away rather than mixed into the dictionary you type with. An
// engine already running would have the real path, so this refuses to continue
// if one is up.
//
// Build and run: tsf/Ohagey/tools/build-and-run-userdict.ps1

#include "../OhageyProtocol.h"

#include <windows.h>

#include <cstdio>
#include <string>
#include <vector>

using namespace Ohagey;

namespace
{
    int g_failures = 0;

    void Check(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }

    void Say(const char* label, const std::wstring& value)
    {
        printf("%s", label);
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
        if (bytes > 0)
        {
            std::string utf8(static_cast<size_t>(bytes), '\0');
            WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
            printf("%s", utf8.c_str());
        }
        printf("\n");
    }

    int RankOf(const ConvertResult& result, const std::wstring& text)
    {
        for (size_t i = 0; i < result.candidates.size(); ++i)
        {
            if (result.candidates[i].text == text) return static_cast<int>(i);
        }
        return -1;
    }

    void PrintRanking(const char* label, const ConvertResult& result)
    {
        printf("%s\n", label);
        for (size_t i = 0; i < result.candidates.size() && i < 5; ++i)
        {
            printf("    %zu. ", i + 1);
            Say("", result.candidates[i].text);
        }
    }

    bool RemoveTree(const std::wstring& path)
    {
        WIN32_FIND_DATAW found = {};
        const std::wstring pattern = path + L"\\*";
        HANDLE handle = FindFirstFileW(pattern.c_str(), &found);
        if (handle == INVALID_HANDLE_VALUE) return RemoveDirectoryW(path.c_str()) != 0;

        do
        {
            const std::wstring name = found.cFileName;
            if (name == L"." || name == L"..") continue;
            const std::wstring child = path + L"\\" + name;
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) RemoveTree(child);
            else DeleteFileW(child.c_str());
        } while (FindNextFileW(handle, &found));

        FindClose(handle);
        return RemoveDirectoryW(path.c_str()) != 0;
    }
}

int wmain()
{
    SetConsoleOutputCP(CP_UTF8);

    // Opening the pipe directly rather than through EngineClient::Connect.
    // Connect *launches* an engine when nothing is listening (decisions 0015 /
    // 0033), and doing that here — before LOCALAPPDATA is redirected below —
    // starts one against the real profile, which is exactly what this is
    // supposed to prevent.
    {
        std::wstring pipe;
        EngineClient::PipeName(&pipe);
        const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr,
                                         OPEN_EXISTING, 0, nullptr);
        if (probe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(probe);
            printf("An engine is already running. Close it first: this harness needs to\n"
                   "start one against a scratch profile so it does not write into the\n"
                   "dictionary you actually type with.\n");
            return 1;
        }
    }

    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-userdict-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());
    Say("scratch profile: ", scratch);

    EngineClient client;
    bool connected = false;
    for (int attempt = 0; attempt < 60 && !connected; ++attempt)
    {
        connected = client.Connect();
        if (!connected) Sleep(1000);
    }
    Check(connected, "launched an engine and connected");
    if (!client.IsConnected()) return 1;

    // A reading that means nothing in particular, so the built-in dictionary
    // has no strong opinion and the registered word is unambiguously ours.
    const std::wstring reading = L"おはぎー";
    const std::wstring word = L"Ohagey";

    ConvertResult before;
    Check(client.Convert(reading, 5, L"", &before) == CallResult::Ok, "converted before registering");
    PrintRanking("  before:", before);
    Check(RankOf(before, word) < 0, "the word is not a candidate yet");

    // ── Registering ─────────────────────────────────────────────────────────

    printf("\nRegisterWord\n");
    Check(client.RegisterWord(reading, word, L"propernoun") == CallResult::Ok,
          "the engine accepted the word");

    ConvertResult after;
    Check(client.Convert(reading, 5, L"", &after) == CallResult::Ok, "converted again");
    PrintRanking("  after:", after);

    const int rank = RankOf(after, word);
    printf("  rank of the registered word: %d\n", rank + 1);
    Check(rank >= 0, "the registered word is now a candidate");
    // Upstream's own dynamic user dictionary uses a cost of -10 against
    // built-in candidates at -14.5 and below, so an explicitly registered word
    // is meant to win. If it does not, the cost or the ids are wrong.
    Check(rank == 0, "and it is ranked first — a word you registered should beat a guess");

    // ── Persistence ─────────────────────────────────────────────────────────

    printf("\nthe file it was written to\n");
    const std::wstring path = scratch + L"\\Ohagey\\userdict.tsv";
    const DWORD attributes = GetFileAttributesW(path.c_str());
    Check(attributes != INVALID_FILE_ATTRIBUTES, "userdict.tsv exists");

    // ── Refusing what cannot work ───────────────────────────────────────────

    printf("\nan entry that could never match\n");
    {
        // Lookup is by kana, so a reading in kanji would load cleanly and never
        // convert. Reporting that beats storing it and leaving the user to
        // wonder why their word does nothing.
        const CallResult result = client.RegisterWord(L"御萩", L"おはぎ", L"noun");
        Check(result == CallResult::Status, "a kanji reading is refused");
        Check(client.LastStatus() == StatusCode::InvalidArgument, "as INVALID_ARGUMENT");
        Say("  message: ", client.LastStatusMessage());
    }

    printf("\nthe connection survives a refusal\n");
    {
        // Decision 0030: a request the engine could answer and declined must
        // not cost the composition in progress.
        ConvertResult stillWorks;
        Check(client.Convert(reading, 5, L"", &stillWorks) == CallResult::Ok
                  && RankOf(stillWorks, word) == 0,
              "the registered word still converts");
    }

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
