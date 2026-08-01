// Is conversion deterministic? (decisions 0032 / 0034)
//
// Converts one reading many times, with nothing in between, and reports whether
// the answer ever differs.
//
// ── Why this needed asking ─────────────────────────────────────────────────
//
// The personalisation harness polls: it converts repeatedly after confirming a
// candidate and stops as soon as the target's rank improves, because retraining
// runs asynchronously and the improvement lands at an unpredictable moment.
// That is the right shape *if* conversion is deterministic. If it is not, the
// loop stops at the first favourable sample and calls it a result — and it
// disagrees with `build-and-run-learning.ps1`, which converts once and sees the
// target stay where it was.
//
// So the question is not academic: one of those two harnesses is wrong about
// personalisation, and this decides which.
//
// It also matters on its own. An IME that offers a different candidate order
// for the same reading, with no input in between, is one a user cannot build a
// habit against.
//
// Build and run: tsf/Ohagey/tools/build-and-run-stability.ps1

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

    std::vector<std::wstring> TextsOf(const ConvertResult& result)
    {
        std::vector<std::wstring> texts;
        for (const auto& candidate : result.candidates) texts.push_back(candidate.text);
        return texts;
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

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);

    // Matches what the personalisation harness polls with, so that a difference
    // found here explains a difference found there.
    const uint32_t nBest = argc > 1 ? static_cast<uint32_t>(_wtoi(argv[1])) : 20;
    const int rounds = argc > 2 ? _wtoi(argv[2]) : 60;

    // Nothing is confirmed here, so the profile would not be written to — but
    // the engine still creates its directories, and a harness that leaves marks
    // in the profile you type with is a harness people stop running.
    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-stability-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());
    Say("scratch profile: ", scratch);

    {
        std::wstring pipe;
        EngineClient::PipeName(&pipe);
        const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr,
                                         OPEN_EXISTING, 0, nullptr);
        if (probe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(probe);
            printf("An engine is already running. Close it first: this needs one started\n"
                   "against a scratch profile.\n");
            return 1;
        }
    }

    EngineClient client;
    bool connected = false;
    for (int attempt = 0; attempt < 60 && !connected; ++attempt)
    {
        connected = client.Connect();
        if (!connected) Sleep(1000);
    }
    Check(connected, "launched an engine and connected");
    if (!client.IsConnected()) return 1;

    PingResult ping;
    if (client.Ping(&ping) != CallResult::Ok) return 1;
    printf("  Zenzai model loaded: %s\n", ping.modelLoaded ? "yes" : "no");

    const std::wstring reading = L"きしゃのきしゃ";
    printf("\nconverting the same reading %d times, n_best=%u, nothing in between\n",
           rounds, nBest);

    ConvertResult first;
    if (client.Convert(reading, nBest, L"", &first) != CallResult::Ok)
    {
        Check(false, "the first conversion succeeded");
        return 1;
    }
    const std::vector<std::wstring> baseline = TextsOf(first);
    printf("  first answer, top 3:\n");
    for (size_t i = 0; i < baseline.size() && i < 3; ++i)
    {
        printf("    %zu. ", i + 1);
        Say("", baseline[i]);
    }

    int differed = 0;
    std::vector<std::wstring> firstDifference;

    // Timed as well as compared. Every conversion now discards the previous
    // lattice before building a new one (see ConversionService.convert), which
    // is what stopped the candidate order alternating between calls — but it
    // also means the cache is no longer paying for anything, and the price of
    // that belongs here rather than in someone's typing.
    double totalMs = 0;
    double worstMs = 0;
    LARGE_INTEGER frequency = {};
    QueryPerformanceFrequency(&frequency);

    for (int round = 1; round < rounds; ++round)
    {
        // The same pause the personalisation harness leaves between polls, so
        // that anything time-dependent has the same chance to happen.
        Sleep(500);
        ConvertResult again;
        LARGE_INTEGER started = {}, finished = {};
        QueryPerformanceCounter(&started);
        const CallResult call = client.Convert(reading, nBest, L"", &again);
        QueryPerformanceCounter(&finished);
        if (call != CallResult::Ok) continue;
        const double ms = (finished.QuadPart - started.QuadPart) * 1000.0 / frequency.QuadPart;
        totalMs += ms;
        if (ms > worstMs) worstMs = ms;

        const std::vector<std::wstring> texts = TextsOf(again);
        if (texts == baseline) continue;
        if (differed == 0)
        {
            firstDifference = texts;
            printf("  round %d differs, top 3:\n", round + 1);
            for (size_t i = 0; i < texts.size() && i < 3; ++i)
            {
                printf("    %zu. ", i + 1);
                Say("", texts[i]);
            }
        }
        ++differed;
    }

    printf("\n  %d of %d repeats differed from the first answer\n", differed, rounds - 1);
    if (rounds > 1)
    {
        printf("  conversion: mean %.0fms, worst %.0fms over %d calls\n",
               totalMs / (rounds - 1), worstMs, rounds - 1);
    }
    Check(differed == 0,
          "the same reading converts the same way every time");
    if (differed != 0)
    {
        printf("\nConversion is not deterministic for a fixed input. Anything that polls\n"
               "until it likes the answer — build-and-run-personalization.ps1 does — is\n"
               "sampling rather than measuring.\n");
    }

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
