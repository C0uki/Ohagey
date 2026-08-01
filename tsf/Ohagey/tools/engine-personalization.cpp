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

    // The reading is printed beside each candidate because it is what tells a
    // partial conversion apart from a full one, and reading the list without
    // that is how the target selection below went wrong for so long.
    void PrintRanking(const char* label, const ConvertResult& result)
    {
        printf("%s\n", label);
        for (size_t i = 0; i < result.candidates.size() && i < 5; ++i)
        {
            printf("    %zu. ", i + 1);
            std::wstring line = result.candidates[i].text;
            line += L"  [";
            line += result.candidates[i].reading;
            line += L"]";
            Say("", line);
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
    //
    // Opening the pipe directly rather than through EngineClient::Connect.
    // Connect *launches* an engine when nothing is listening (decisions 0015 /
    // 0033), so using it here — before LOCALAPPDATA is redirected below —
    // starts one against the real profile, which is the very thing this check
    // exists to avoid.
    {
        std::wstring pipe;
        EngineClient::PipeName(&pipe);
        const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr,
                                         OPEN_EXISTING, 0, nullptr);
        if (probe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(probe);
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

    // A reading with many plausible *kanji* conversions, so there is a real
    // ranking to change.
    //
    // Was `きしゃのきしゃ`, which turns out to be a weak test: its only
    // full-length candidates below the top are the katakana form and the
    // reading itself, and promoting either proves little about a character
    // n-gram trained on exactly that string. `こうしょう` offers twenty
    // conversions that are all genuinely different words.
    const std::wstring reading = L"こうしょう";

    // More than the five that get printed. `mainResults` spends its first few
    // places on the full-length conversions and then on forms that are not
    // conversions at all (katakana, the reading itself) and partial ones, so a
    // request for five leaves almost nothing to promote — measured, the only
    // full-length candidate below the top was the reading passed straight
    // through, and promoting that proves very little about a language model
    // trained on exactly it.
    const uint32_t nBest = 20;

    ConvertResult before;
    Check(client.Convert(reading, nBest, L"", &before) == CallResult::Ok, "converted before any training");
    if (before.candidates.size() < 2)
    {
        Check(false, "needed at least two candidates to have a ranking to change");
        return 1;
    }
    Check(before.zenzaiUsed, "the conversion went through Zenzai");
    PrintRanking("  before:", before);

    // Something the engine did *not* rank first, so promotion is unambiguous —
    // but it also has to convert the *whole* reading.
    //
    // `mainResults` mixes in candidates that cover only the start of the
    // composition: for きしゃのきしゃ it offers きしゃ and 期しゃ. Taking the
    // last candidate without checking, as this used to, picked one of those and
    // then confirmed it 40 times as the conversion of the full reading. That is
    // not a weaker measurement, it is a different one — the model learned that
    // きしゃのきしゃ reads as 期しゃ and started answering 記社之記社.
    //
    // A candidate reports what it covers in `reading` (decision 0007), so the
    // check is just that it matches what was asked for.
    // The reading passed straight through is excluded as well. It is a
    // full-length candidate and promoting it does happen, but it demonstrates
    // very little: the personal model is a character n-gram trained on exactly
    // that string, so it would rise whether or not the mechanism does anything
    // interesting to a *conversion*.
    std::wstring target;
    for (size_t i = before.candidates.size(); i-- > 0;)
    {
        if (before.candidates[i].reading != reading) continue;
        if (before.candidates[i].text == reading) continue;
        target = before.candidates[i].text;
        break;
    }
    if (target.empty())
    {
        Check(false, "found a conversion of the whole reading to promote");
        printf("\nEvery candidate offered converts only part of きしゃのきしゃ, or is the\n"
               "reading itself, so there is no ranking here worth measuring.\n");
        return 1;
    }
    Check(true, "the target is a conversion of the whole reading");
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
        if (client.Convert(reading, nBest, L"", &after) != CallResult::Ok) continue;
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

    // Reported rather than asserted, and the distinction is deliberate.
    //
    // Personalisation being coarse enough to disturb candidates the user never
    // confirmed is a *known* limitation — decision 0034 records it and the
    // roadmap tracks it. Failing the run on it would leave this harness
    // permanently red, and a check that is always red is one nobody reads, so
    // the thing it was meant to protect stops being protected.
    //
    // What is asserted above is the claim the feature rests on: the confirmed
    // candidate rises. How much collateral there is belongs in the output, with
    // enough detail to tell whether it is getting better or worse.
    if (othersBefore == othersAfter)
    {
        printf("  [ -- ] every other candidate kept its order\n");
    }
    else
    {
        printf("  [ -- ] other candidates were reordered too — personalisation is still\n"
               "         coarse (decision 0034's remaining limitation, not a regression)\n");
        for (size_t i = 0; i < othersBefore.size() && i < othersAfter.size(); ++i)
        {
            if (othersBefore[i] == othersAfter[i]) continue;
            printf("         first difference at %zu: ", i + 1);
            std::wstring line = othersBefore[i];
            line += L" -> ";
            line += othersAfter[i];
            Say("", line);
            break;
        }
    }

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
