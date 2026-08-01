// Is the converter's own learning store enough? (decision 0034, re-examined)
//
// Decision 0034 rests on an observation: that confirming a candidate does not
// change Zenzai's ranking, because the learning store feeds the lattice
// underneath the neural model. Two forks and a personal n-gram were built on
// that.
//
// The observation could not have been trusted, because until now the engine
// reported `zenzai_used` from the presence of the model *file* — and with the
// wrong llama.cpp build the weights are found, rejected, and every conversion
// quietly comes from the dictionary. So "Zenzai was on" was never established.
//
// This measures the question directly, with the model genuinely loaded:
//
//   * a realistic correction (the second candidate, confirmed a few times),
//     not the last candidate hammered forty times;
//   * both with and without personalisation, so the two can be told apart;
//   * and what happens to the *rest* of the list, because an IME that promotes
//     your word by demolishing every other candidate has not helped you.
//
// Build and run: tsf/Ohagey/tools/build-and-run-learning.ps1

#include "../OhageyProtocol.h"

#include <windows.h>

#include <cstdio>
#include <string>
#include <vector>

using namespace Ohagey;

namespace
{
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
        printf("  %s\n", label);
        for (size_t i = 0; i < result.candidates.size() && i < 5; ++i)
        {
            printf("    %zu. ", i + 1);
            Say("", result.candidates[i].text);
        }
    }

    /// How many of the original candidates are still present, ignoring the one
    /// that was promoted.
    int Survivors(const ConvertResult& before, const ConvertResult& after, const std::wstring& target)
    {
        int count = 0;
        for (const auto& candidate : before.candidates)
        {
            if (candidate.text == target) continue;
            if (RankOf(after, candidate.text) >= 0) ++count;
        }
        return count;
    }

    bool RemoveTree(const std::wstring& path)
    {
        WIN32_FIND_DATAW found = {};
        HANDLE handle = FindFirstFileW((path + L"\\*").c_str(), &found);
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
    const std::wstring label = (argc > 1) ? argv[1] : L"(unlabelled)";

    // Opened directly rather than through Connect, which would launch an engine
    // against the real profile before the redirect below.
    {
        std::wstring pipe;
        EngineClient::PipeName(&pipe);
        const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (probe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(probe);
            printf("An engine is already running; stop it first.\n");
            return 1;
        }
    }

    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-learning-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());

    EngineClient client;
    bool connected = false;
    for (int attempt = 0; attempt < 60 && !connected; ++attempt)
    {
        connected = client.Connect();
        if (!connected) Sleep(1000);
    }
    if (!connected) { printf("could not connect\n"); return 1; }

    PingResult ping;
    client.Ping(&ping);
    // Meaningful now that the engine reports whether llama actually loaded the
    // weights rather than whether the file is on disk.
    printf("\n=== %ls ===\n", label.c_str());
    printf("  model loaded: %s\n", ping.modelLoaded ? "yes" : "NO — this measures nothing");
    if (!ping.modelLoaded) return 1;

    const std::wstring reading = L"きしゃのきしゃ";

    ConvertResult before;
    if (client.Convert(reading, 5, L"", &before) != CallResult::Ok || before.candidates.size() < 2)
    {
        printf("  could not get a ranking to work with\n");
        return 1;
    }
    PrintRanking("before:", before);

    // The second candidate: what a user corrects when the IME's first guess is
    // wrong. Not the last one, which is the katakana fallback and not a
    // conversion anyone is choosing on purpose.
    const std::wstring target = before.candidates[1].text;
    Say("  target: ", target);

    // Two points on the curve. Three confirmations is a user correcting the
    // same word a few times in an afternoon; forty is a week of it.
    for (const int commits : { 3, 37 })
    {
        for (int i = 0; i < commits; ++i) client.Commit(reading, target, true);

        const int total = (commits == 3) ? 3 : 40;

        // Measured twice, immediately and again after a pause.
        //
        // This harness used to take only the immediate reading, and that is how
        // it came to disagree with build-and-run-personalization.ps1 about the
        // same reading and the same target: one said the confirmed candidate
        // never moved, the other said it reached first. The personalisation
        // harness polls for up to thirty seconds, so whatever takes effect late
        // was visible to it and not to this.
        //
        // Both numbers are printed rather than one replacing the other, because
        // the difference between them is itself the finding — an IME that needs
        // fifteen seconds to reflect a correction behaves very differently from
        // one that reflects it on the next keystroke.
        for (const wchar_t* when : { L"immediately", L"after 15s" })
        {
            if (when[0] == L'a') Sleep(15000);

            ConvertResult after;
            if (client.Convert(reading, 5, L"", &after) != CallResult::Ok) continue;

            printf("\n  after %d confirmations, ", total);
            Say("", when);
            PrintRanking("", after);
            printf("    target rank: %d -> %d\n", RankOf(before, target) + 1, RankOf(after, target) + 1);
            printf("    other original candidates still present: %d of %zu\n",
                   Survivors(before, after, target), before.candidates.size() - 1);
        }
    }

    RemoveTree(scratch);
    return 0;
}
