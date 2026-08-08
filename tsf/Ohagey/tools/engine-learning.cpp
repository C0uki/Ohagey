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
    // Enough to see whether the rank settles, without turning the run into a
    // benchmark. Five is comfortably more than the two the question needs.
    constexpr int kRepeats = 5;

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
    // The reading, because which one is chosen decides what this can show.
    //
    // Personalisation cannot touch the first character of a candidate
    // (`ZenzContext` skips the mixing while the generated prefix is empty),
    // so a reading whose alternatives all differ at character one measures
    // the learning store and nothing else. きしゃのきしゃ is such a reading;
    // きかいをつくる offers 機会をつくる and 機会を作る, which share 機会を.
    const std::wstring reading = (argc > 2) ? argv[2] : L"きしゃのきしゃ";
    // How long to let the retraining finish before measuring.
    //
    // Has to be a knob because the cost is set by the base model: resuming
    // from a 1.4 MB base takes about a second, and from a 42.6 MB one about
    // forty. Waiting too little does not look like waiting too little — it
    // looks like personalisation doing nothing.
    const int settleSeconds = (argc > 3) ? _wtoi(argv[3]) : 20;

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
        // Re-converted before each commit. The engine only remembers the
        // last few readings it answered, and a commit for one it has
        // forgotten is dropped (decision 0034).
        for (int i = 0; i < commits; ++i)
        {
            ConvertResult again;
            client.Convert(reading, 5, L"", &again);
            client.Commit(reading, target, true);
        }

        // ── Wait for the retraining, then measure ──────────────────────
        //
        // Fixed, and generous, and *not* a poll that stops when it likes
        // the answer — decision 0034 has been burned by that. It is here
        // because retraining time depends on how the personal model is
        // built: from nothing it takes ~30ms, and resumed from the base it
        // takes ~5s. Measuring immediately reported "personalisation does
        // nothing" for every resumed run, which is the opposite of what a
        // longer look shows.
        Sleep(static_cast<DWORD>(settleSeconds) * 1000);

        const int total = (commits == 3) ? 3 : 40;

        // Converted several times in a row, with no pause and nothing in
        // between, and the rank printed for each.
        //
        // The point is to separate two explanations that a single delayed
        // measurement cannot tell apart: "the effect needs time to land" and
        // "the effect needs one more conversion". This harness used to measure
        // once, immediately, and concluded the confirmed candidate never moved;
        // the personalisation harness polled for thirty seconds and concluded it
        // reached first. If the rank changes on the second call with no waiting,
        // the difference was never about time.
        printf("\n  after %d confirmations, converting %d times in a row:\n",
               total, kRepeats);
        ConvertResult after;
        for (int attempt = 0; attempt < kRepeats; ++attempt)
        {
            if (client.Convert(reading, 5, L"", &after) != CallResult::Ok) continue;
            printf("    call %d: target rank %d\n", attempt + 1, RankOf(after, target) + 1);
        }
        PrintRanking("", after);
        printf("    target rank: %d -> %d\n", RankOf(before, target) + 1, RankOf(after, target) + 1);
        printf("    other original candidates still present: %d of %zu\n",
               Survivors(before, after, target), before.candidates.size() - 1);
    }

    RemoveTree(scratch);
    return 0;
}
