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

    // ── What registering one word costs everything else ────────────────────
    //
    // Registering a word does not just add a lattice entry: the word also goes
    // into the personal n-gram, because that is the only mechanism that reaches
    // Zenzai's ranking (decision 0036). So a model trained on *one word* is
    // handed to the converter — which is very nearly the shape that broke 18 of
    // 30 known-correct conversions when it was one *phrase* (decision 0034,
    // addendum 8).
    //
    // That risk was recorded as untested when personalisation was switched off
    // by default, because this path stays on regardless. This measures it.
    std::vector<std::wstring> evalReadings, evalExpected;
    std::vector<std::vector<std::wstring>> evalBefore;
    const wchar_t* evalSet = argc > 1 ? argv[1] : nullptr;
    if (evalSet != nullptr && std::wstring(evalSet) != L"" && ReadEvalSet(evalSet, &evalReadings, &evalExpected))
    {
        Say("evaluation set: ", evalSet);
        for (const auto& r : evalReadings)
        {
            ConvertResult result;
            if (client.Convert(r, 5, L"", &result) != CallResult::Ok) break;
            evalBefore.push_back(TextsOf(result));
        }
    }

    ConvertResult before;
    Check(client.Convert(reading, 5, L"", &before) == CallResult::Ok, "converted before registering");
    PrintRanking("  before:", before);
    Check(RankOf(before, word) < 0, "the word is not a candidate yet");

    // ── Registering ─────────────────────────────────────────────────────────

    printf("\nRegisterWord\n");
    Check(client.RegisterWord(reading, word, L"propernoun") == CallResult::Ok,
          "the engine accepted the word");

    // Immediately, with no waiting: the lattice cost takes effect on the very
    // next conversion, and a word that did not show up at all would be
    // indistinguishable from the registration having failed.
    ConvertResult after;
    Check(client.Convert(reading, 5, L"", &after) == CallResult::Ok, "converted again");
    PrintRanking("  right away:", after);
    Check(RankOf(after, word) >= 0, "the registered word is a candidate straight away");

    // ── Where it lands, and why first is no longer the target ──────────────
    //
    // Upstream's dynamic user dictionary uses a cost of -10 against built-in
    // candidates at -14.5 and below, so in the lattice the registered word
    // wins. With Zenzai loaded that stops deciding the order: the neural model
    // re-ranks above the lattice and the word lands wherever it puts it —
    // measured at 3rd, behind the reading passed straight through.
    //
    // Decision 0036 got past that by routing the word into the personal n-gram,
    // and it worked: 1st. Then the evaluation below was pointed at it, and the
    // price came out at 18 of 30 otherwise-correct conversions — 病院の予約
    // returning 病医ンノ予ヤ久. The same damage, and the same number, as
    // personalisation itself (decision 0034, addendum 8), because it is the
    // same mechanism handed a model trained on one word.
    //
    // So the routing is off and the word keeps its lattice cost alone. What
    // this harness guards is therefore no longer "it reaches first" — that is
    // reported — but "registering a word does not break the language", below.
    const int rank = RankOf(after, word);
    printf("  rank of the registered word: %d\n", rank + 1);

    if (evalBefore.size() == evalReadings.size() && !evalReadings.empty())
    {
        size_t rightBefore = 0, rightAfter = 0, broke = 0;
        for (size_t i = 0; i < evalReadings.size(); ++i)
        {
            ConvertResult after2;
            if (client.Convert(evalReadings[i], 5, L"", &after2) != CallResult::Ok) continue;
            const std::vector<std::wstring> now = TextsOf(after2);
            const bool wasRight = !evalBefore[i].empty() && evalBefore[i][0] == evalExpected[i];
            const bool isRight = !now.empty() && now[0] == evalExpected[i];
            rightBefore += wasRight ? 1 : 0;
            rightAfter += isRight ? 1 : 0;
            if (wasRight && !isRight)
            {
                ++broke;
                printf("    broke: ");
                std::wstring line = evalReadings[i];
                line += L"   ";
                line += evalBefore[i][0];
                line += L"   ->  ";
                line += now.empty() ? L"(none)" : now[0];
                Say("", line);
            }
        }
        printf("  correct at rank 1: %zu -> %zu of %zu   (broke %zu)\n",
               rightBefore, rightAfter, evalReadings.size(), broke);

        // Asserted, unlike the same measurement in the personalisation harness.
        // There it reports a known limitation of a feature the user opted into;
        // here it guards one that is on for everyone — registering a word is an
        // ordinary thing to do, and it must not cost the user their conversion
        // quality. If this goes red, something has put registered words back
        // through the personal model.
        Check(broke == 0, "registering a word broke nothing else");
        // Reported, not asserted, on the same grounds as the personalisation
        // harness: this is a property of the mechanism that the roadmap tracks,
        // and a permanently red check is one nobody reads.
    }

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
        // Present, not first: the word carries its lattice cost and nothing
        // more, so where Zenzai puts it is Zenzai's business (see above). What
        // decision 0030 is about is that a refused request does not cost the
        // conversion in progress, and that is what this checks.
        ConvertResult stillWorks;
        Check(client.Convert(reading, 5, L"", &stillWorks) == CallResult::Ok
                  && RankOf(stillWorks, word) >= 0,
              "the registered word still converts");
    }

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
