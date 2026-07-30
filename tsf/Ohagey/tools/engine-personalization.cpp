// Does confirming a candidate actually reorder Zenzai's output? (decision 0034)
//
// This is the claim the feature rests on, and it is not one that can be read
// off the code. The converter's own learning store feeds the lattice, which
// sits underneath the neural model — measured, and documented in
// engine-roundtrip.cpp: with the model loaded, confirming the second candidate
// does not move it. Personalisation is a different mechanism (a trained n-gram
// mixed into the logits), so whether *it* moves the ranking has to be measured
// too, not inferred from the fact that it is wired up.
//
// The engine retrains after a batch of commits and publishes the result
// asynchronously, so this harness confirms repeatedly and then waits.
//
// ── Your own data is not touched ────────────────────────────────────────────
//
// The engine reads LOCALAPPDATA to find its per-user directory (decision 0024).
// This sets it to a scratch path before launching, so the corpus and trained
// model built here are thrown away rather than mixed into the profile you type
// with. An engine already running would have the real path, so this refuses to
// continue if one is up.
//
// Build and run: tsf/Ohagey/tools/build-and-run-personalization.ps1

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

    // Position of a candidate in a result, or -1.
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
        // Double-NUL terminated, as SHFileOperation-style APIs want; here the
        // simpler route is a recursive delete via the shell-free helper below.
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

    // An engine already running was launched with the real LOCALAPPDATA and
    // would train on — and pollute — the profile you actually type with.
    {
        EngineClient probe;
        if (probe.Connect())
        {
            printf("An engine is already running. Close it first: this harness needs to\n"
                   "start one against a scratch profile so it does not train on your own\n"
                   "typing history.\n");
            return 1;
        }
    }

    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-p13n-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    // Inherited by the engine this client launches, which is how the engine
    // ends up with a profile of its own.
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());
    Say("scratch profile: ", scratch);

    EngineClient client;

    // `Connect` launches the engine and retries for about a second, which is
    // tuned for an engine that is already up or nearly so. A cold start here
    // loads the dictionary *and* the Zenzai weights before it begins listening,
    // which takes considerably longer, so this waits rather than reporting a
    // failure that is really just impatience.
    //
    // Worth noting for phase 2: the TSF client inherits that same one-second
    // budget, so the first conversion after a reboot may come back empty and
    // only the next one succeed.
    bool connected = false;
    for (int attempt = 0; attempt < 60 && !connected; ++attempt)
    {
        connected = client.Connect();
        if (!connected) Sleep(1000);
    }
    Check(connected, "launched an engine and connected");
    if (!client.IsConnected()) return 1;

    PingResult ping;
    Check(client.Ping(&ping) == CallResult::Ok, "ping answered");
    if (!ping.modelLoaded)
    {
        printf("\nThe Zenzai model is not installed, so there is no neural ranking to\n"
               "personalise and this harness has nothing to measure. Set OHAGEY_MODEL_PATH\n"
               "(debug builds) or install the model, then run it again.\n");
        return 1;
    }
    Check(ping.modelLoaded, "the Zenzai model is loaded");

    // A reading with several plausible conversions, so there is a ranking to
    // change in the first place.
    const std::wstring reading = L"きしゃのきしゃ";

    ConvertResult before;
    Check(client.Convert(reading, 5, L"", &before) == CallResult::Ok, "converted before any training");
    if (before.candidates.size() < 2)
    {
        Check(false, "needed at least two candidates to have a ranking to change");
        return 1;
    }
    Check(before.zenzaiUsed, "the conversion went through Zenzai");
    PrintRanking("  before:", before);

    // Something the engine did *not* rank first, so promotion is unambiguous.
    const std::wstring target = before.candidates[before.candidates.size() - 1].text;
    const int rankBefore = RankOf(before, target);
    printf("  target: rank %d\n", rankBefore + 1);
    Say("          ", target);

    // Past the engine's retraining threshold, with room to spare: the model is
    // rebuilt after a batch of commits, not on each one.
    const int commits = 40;
    bool allCommitted = true;
    for (int i = 0; i < commits; ++i)
    {
        if (client.Commit(reading, target, true) != CallResult::Ok) allCommitted = false;
    }
    Check(allCommitted, "confirmed the target 40 times");

    // Training runs off the engine's main actor and publishes when it finishes,
    // so the next conversion does not necessarily see it. Poll rather than
    // sleeping a fixed amount: a slow machine should not fail the check, and a
    // fast one should not wait.
    printf("  waiting for the engine to retrain...\n");
    int rankAfter = rankBefore;
    ConvertResult after;
    for (int attempt = 0; attempt < 60; ++attempt)
    {
        Sleep(500);
        if (client.Convert(reading, 5, L"", &after) != CallResult::Ok) continue;
        rankAfter = RankOf(after, target);
        if (rankAfter >= 0 && rankAfter < rankBefore) break;
    }

    PrintRanking("  after:", after);
    printf("  target: rank %d -> %d\n", rankBefore + 1, rankAfter + 1);

    Check(rankAfter >= 0, "the target is still among the candidates");
    Check(rankAfter < rankBefore,
          "confirming the candidate moved it up — learning now reaches Zenzai's ranking");

    // The point of decision 0034 is that personalisation *adds* to the neural
    // model rather than replacing it, and the measurement for that is the order
    // of everything else.
    //
    // Absolute positions are the wrong thing to compare: promoting the target
    // to the top pushes every other candidate down one, so nothing would sit
    // where it did even though nothing was reordered. What has to hold is that
    // the others keep their order relative to each other — which is exactly
    // what an empty base model predicts, since it scores every token the user
    // has not typed identically and so shifts them all by the same constant.
    std::vector<std::wstring> othersBefore, othersAfter;
    for (const auto& candidate : before.candidates)
    {
        if (candidate.text != target) othersBefore.push_back(candidate.text);
    }
    for (const auto& candidate : after.candidates)
    {
        if (candidate.text != target) othersAfter.push_back(candidate.text);
    }
    printf("  untouched candidates: %zu before, %zu after\n", othersBefore.size(), othersAfter.size());
    Check(othersBefore == othersAfter,
          "every other candidate kept its order, so Zenzai is not being overruled wholesale");

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
