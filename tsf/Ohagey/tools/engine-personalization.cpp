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

    std::vector<std::wstring> TextsOf(const ConvertResult& result)
    {
        std::vector<std::wstring> texts;
        for (const auto& candidate : result.candidates) texts.push_back(candidate.text);
        return texts;
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

    /// Reads `reading<TAB>expected` lines, skipping comments and blanks.
    ///
    /// UTF-8 with no BOM, which is what the repo's file is and what anyone
    /// editing it in an editor will produce. Lines without a tab are skipped
    /// rather than rejected: the file is meant to be edited by hand, and one
    /// malformed line should not cost the whole run.
    bool ReadEvalSet(const wchar_t* path,
                     std::vector<std::wstring>* readings,
                     std::vector<std::wstring>* expected)
    {
        const HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;

        std::string bytes;
        char buffer[4096];
        DWORD read = 0;
        while (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) && read > 0)
        {
            bytes.append(buffer, read);
        }
        CloseHandle(file);

        const int chars = MultiByteToWideChar(CP_UTF8, 0, bytes.data(),
                                              static_cast<int>(bytes.size()), nullptr, 0);
        std::wstring text(static_cast<size_t>(chars), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()),
                            text.data(), chars);

        size_t start = 0;
        while (start <= text.size())
        {
            size_t end = text.find(L'\n', start);
            if (end == std::wstring::npos) end = text.size();
            std::wstring line = text.substr(start, end - start);
            start = end + 1;
            if (!line.empty() && line.back() == L'\r') line.pop_back();
            if (line.empty() || line[0] == L'#') continue;

            const size_t tab = line.find(L'\t');
            if (tab == std::wstring::npos) continue;
            readings->push_back(line.substr(0, tab));
            expected->push_back(line.substr(tab + 1));
        }
        return !readings->empty();
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

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);

    // argv[1] n_best, argv[2] reading, argv[3] a corpus file to start from,
    // argv[4] an evaluation set of readings with their expected conversions.
    // Read here rather than beside each use because the seeding below happens
    // before anything else — it has to be in place before the engine starts.
    // "-" means "not given". PowerShell drops empty arguments to a native
    // executable, so a positional gap needs something to stand in it.
    const auto optional = [](const wchar_t* value) -> const wchar_t* {
        if (value == nullptr) return nullptr;
        const std::wstring text = value;
        if (text.empty() || text == L"-") return nullptr;
        return value;
    };
    const wchar_t* seedCorpus = optional(argc > 3 ? argv[3] : nullptr);
    const wchar_t* evalSet = optional(argc > 4 ? argv[4] : nullptr);

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

    // ── Optionally start from a corpus that looks like someone's ───────────
    //
    // Without this the model is trained on forty copies of one phrase and
    // nothing else, and an n-gram that knows one sentence pulls everything
    // toward it. That measured as damage to unrelated readings at the default
    // alpha — a real result, but an upper bound rather than a prediction, since
    // no real profile looks like that.
    //
    // Seeded before the engine starts, so the very first training run already
    // sees it. The file is copied rather than referenced: the engine trims and
    // rewrites its corpus, and it must not do that to something in the repo.
    if (seedCorpus != nullptr && seedCorpus[0] != L'\0')
    {
        const std::wstring personal = scratch + L"\\Ohagey\\personal";
        CreateDirectoryW((scratch + L"\\Ohagey").c_str(), nullptr);
        CreateDirectoryW(personal.c_str(), nullptr);
        if (!CopyFileW(seedCorpus, (personal + L"\\corpus.txt").c_str(), FALSE))
        {
            printf("could not read the seed corpus (error %lu)\n", GetLastError());
            return 1;
        }
        Say("seed corpus: ", seedCorpus);
    }

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

    // ── Why this reading and not a richer one ──────────────────────────────
    //
    // This was briefly `こうしょう`, on the reasoning that twenty genuinely
    // different kanji conversions make a better ranking to disturb than one
    // whose only movable full-length candidates are katakana forms. The result
    // looked much stronger — 20th to 1st instead of 2nd to 1st.
    //
    // It was measuring the wrong thing. Confirming a candidate also feeds the
    // converter's own learning store, which sits *under* Zenzai, and for a
    // single short word that lattice ordering survives the re-ranking: with
    // personalisation switched off entirely, `こうしょう` still went 20th to
    // 1st. The promotion was real and had nothing to do with the mechanism
    // this harness exists to test.
    //
    // `きしゃのきしゃ` is a multi-clause reading where Zenzai dominates, and the
    // control run holds: learning store alone leaves the target at 2nd after
    // forty confirmations, and only personalisation moves it to 1st. That A/B
    // is `build-and-run-learning.ps1`, and it is what makes this reading the
    // right one — a weaker-looking number that is actually about personalisation.
    //
    // Overridable, because one reading is not a measurement. Twice in this
    // file's history a conclusion drawn from a single reading turned out to be
    // about something else — see the note above and decision 0034's addenda.
    const std::wstring reading = argc > 2 ? argv[2] : L"きしゃのきしゃ";

    // More than the five that get printed. `mainResults` spends its first few
    // places on the full-length conversions and then on forms that are not
    // conversions at all (katakana, the reading itself) and partial ones, so a
    // request for five leaves almost nothing to promote — measured, the only
    // full-length candidate below the top was the reading passed straight
    // through, and promoting that proves very little about a language model
    // trained on exactly it.
    //
    // Overridable because it is not just a display count: the engine passes it
    // to the converter as `N_best`, which steers the lattice search itself. Two
    // harnesses asking for different numbers can therefore disagree about the
    // same reading — and `build-and-run-learning.ps1` asks for 5.
    const uint32_t nBest = argc > 1 ? static_cast<uint32_t>(_wtoi(argv[1])) : 20;

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
    //
    // ── And it has to start with the same character as the top candidate ──
    //
    // `ZenzContext` skips personalisation entirely while the generated
    // prefix is empty:
    //
    //     if !prefix.isEmpty { baseProb = baseLM.bulkPredict(prefix)... }
    //     else { baseProb = Array(repeating: 0, count: n_vocab) }
    //
    // SwiftNgram has no unigram probabilities, so **the first character of a
    // candidate can never be personalised**. A target that differs from the
    // top candidate at character one asks the mechanism for something it
    // structurally cannot do, and the harness then reports that
    // personalisation does not work.
    //
    // That is what it did report. Scanning from the end picked the katakana
    // passthrough — キカイヲツクル against 機会をつくる — which differs at
    // character one. Choosing 機会を作る instead, which shares 機会を, the
    // same run promotes it to 1st.
    //
    // So: prefer a candidate sharing the first character with the top one.
    // Fall back to the old choice when there is none, and say so — a run
    // that cannot promote still measures whether anything breaks, but its
    // rank result means nothing.
    std::wstring target;
    bool targetIsReachable = false;
    const std::wstring topFirst =
        before.candidates.empty() ? std::wstring() : before.candidates[0].text.substr(0, 1);

    for (size_t i = 1; i < before.candidates.size(); ++i)
    {
        if (before.candidates[i].reading != reading) continue;
        if (before.candidates[i].text == reading) continue;
        if (before.candidates[i].text.substr(0, 1) != topFirst) continue;
        target = before.candidates[i].text;
        targetIsReachable = true;
        break;
    }

    if (target.empty())
    {
        for (size_t i = before.candidates.size(); i-- > 0;)
        {
            if (before.candidates[i].reading != reading) continue;
            if (before.candidates[i].text == reading) continue;
            target = before.candidates[i].text;
            break;
        }
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
    if (!targetIsReachable)
    {
        printf("  NOTE: no candidate shares its first character with the top one, so this\n"
               "        target cannot be promoted however well personalisation works.\n"
               "        The collateral numbers below still hold; the rank does not.\n");
    }

    // ── A reading that has nothing to do with any of this ──────────────────
    //
    // "collateral" below counts only the other candidates for the *same*
    // reading, and that is the cheap half of the question. Turning alpha up
    // promotes what the user confirmed; what it costs is whatever it does to
    // everything they did not. A personal n-gram trained on one phrase can
    // perfectly well reorder an unrelated one, and no amount of measuring the
    // trained reading would show it.
    // Several of them, not one. A single control reading is one coin flip, and
    // this project has repeatedly drawn a conclusion from a single measurement
    // and had to take it back.
    //
    // Each one carries the answer it *should* give, so the report can say
    // "broke" instead of "changed". That distinction is what the alpha question
    // has been stuck on: a reading moving because personalisation nudged it
    // toward what this user writes is the feature working, and one moving from
    // the right answer to a wrong one is the feature leaking. Counting changes
    // cannot tell them apart, and every previous round of this measurement
    // could only count changes.
    //
    // eval-set.tsv beside this file, or the three below when it is not given.
    std::vector<std::wstring> controlReadings;
    std::vector<std::wstring> controlExpected;
    if (evalSet != nullptr && evalSet[0] != L'\0')
    {
        if (!ReadEvalSet(evalSet, &controlReadings, &controlExpected))
        {
            printf("could not read the evaluation set\n");
            return 1;
        }
        Say("evaluation set: ", evalSet);
    }
    else
    {
        controlReadings = { L"あしたのてんき", L"かいぎのしりょう", L"でんしゃがおくれた" };
        controlExpected = { L"明日の天気", L"会議の資料", L"電車が遅れた" };
    }

    std::vector<std::vector<std::wstring>> controlBefore;
    for (const auto& control : controlReadings)
    {
        ConvertResult result;
        if (client.Convert(control, nBest, L"", &result) != CallResult::Ok) break;
        controlBefore.push_back(TextsOf(result));
    }
    const bool haveControl = controlBefore.size() == controlReadings.size();

    // Converted once more, immediately before confirming it.
    //
    // The engine can only feed its own learning store a candidate it still
    // remembers offering, and it remembers the last eight readings
    // (`ConversionService.recentCandidates`). Reading the evaluation set above
    // converts thirty-two, which pushed the target out — so the commits below
    // reached personalisation and not the learning store, and the run measured
    // something different from the runs without an evaluation set. That is what
    // made the target's rank move the wrong way.
    //
    // A real user converts and then confirms, with nothing in between. Doing
    // the same here is both the fix and the more honest scenario.
    ConvertResult refreshed;
    if (client.Convert(reading, nBest, L"", &refreshed) != CallResult::Ok)
    {
        Check(false, "re-converted the target before confirming it");
        return 1;
    }

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
    // 480 half-seconds. Long because the wait is set by the base model, not
    // by the machine: resuming from a 42.6 MB base takes about forty seconds
    // per training run. The loop still exits as soon as the rank improves, so
    // the budget is only spent when nothing is going to happen — which is
    // exactly the case worth being sure about.
    for (int attempt = 0; attempt < 480; ++attempt)
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
    // Counted, not just noticed. The lever on this is alpha, and choosing a
    // value means comparing runs — "some candidates moved" cannot be compared
    // with anything, while "3 of 19 moved" can.
    size_t displaced = 0;
    for (size_t i = 0; i < othersBefore.size(); ++i)
    {
        bool same = i < othersAfter.size() && othersBefore[i] == othersAfter[i];
        if (!same) ++displaced;
    }
    printf("  collateral: %zu of %zu other candidates moved\n", displaced, othersBefore.size());

    if (haveControl)
    {
        // Printed in full when one moves, because "reordered" on its own cannot
        // be judged. Personalisation nudging an unrelated reading toward
        // something the user writes is arguably the feature working; nudging it
        // toward nonsense is the feature leaking. Only the two lists side by
        // side tell those apart — and this is the number that decides whether
        // alpha can be raised, because the same-reading collateral above reads
        // 0 at every alpha and makes it look free.
        //
        // Reported rather than asserted, on the same grounds as that
        // collateral: it is a property of the mechanism, tracked in the
        // roadmap, and a permanently red check is one nobody reads.
        size_t movedReadings = 0;
        size_t rightBefore = 0, rightAfter = 0, broke = 0, fixed = 0;
        for (size_t r = 0; r < controlReadings.size(); ++r)
        {
            ConvertResult controlAfter;
            if (client.Convert(controlReadings[r], nBest, L"", &controlAfter) != CallResult::Ok) continue;

            const std::vector<std::wstring>& was = controlBefore[r];
            const std::vector<std::wstring> now = TextsOf(controlAfter);
            if (was != now) ++movedReadings;

            // Top of the list only. A right answer sitting at rank 4 is one the
            // user still has to hunt for, so counting it as correct would
            // flatter the result.
            const bool wasRight = !was.empty() && was[0] == controlExpected[r];
            const bool isRight = !now.empty() && now[0] == controlExpected[r];
            rightBefore += wasRight ? 1 : 0;
            rightAfter += isRight ? 1 : 0;
            if (wasRight && !isRight) ++broke;
            if (!wasRight && isRight) ++fixed;

            // Only the ones that got worse are printed in full. A run over
            // thirty readings would otherwise bury the answer in output, and
            // the readings that broke are the answer.
            if (wasRight && !isRight)
            {
                printf("    broke: ");
                std::wstring line = controlReadings[r];
                line += L"   ";
                line += was.empty() ? L"" : was[0];
                line += L"   ->  ";
                line += now.empty() ? L"(none)" : now[0];
                Say("", line);
            }
        }
        printf("  untrained readings disturbed: %zu of %zu\n",
               movedReadings, controlReadings.size());
        printf("  correct at rank 1: %zu -> %zu of %zu   (broke %zu, fixed %zu)\n",
               rightBefore, rightAfter, controlReadings.size(), broke, fixed);
    }

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
