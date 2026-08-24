// Does importing text damage unrelated conversions? (decision 0037)
//
// ── Why this harness exists ────────────────────────────────────────────────
//
// Decision 0037 feeds user-supplied text into the same personal n-gram that
// decision 0034 spent weeks establishing is dangerous when built wrong. The
// danger was never the size of the input — it was training the personal model
// from nothing, which put the smoothing floor under every word the user had not
// typed and made subtracting the base a penalty on the whole language: 8 to 18
// of 30 otherwise-correct conversions lost, measured.
//
// Resuming from the base fixed that, and this is the measurement that says it
// stays fixed when the training input grows by two orders of magnitude. It is
// the same assertion the user dictionary harness makes — "you may register a
// word, but not at the cost of everything else" — applied to a document.
//
// ── What it does NOT claim ─────────────────────────────────────────────────
//
// It does not claim the import *helps*. Showing that needs a reading whose
// answer the learning store cannot already promote, and personalisation can
// only move candidates that share their first character with the current first
// place (decision 0034). That measurement is build-and-run-learning.ps1's job
// and it is deliberately not duplicated here — decision 0034 mistook the
// learning store's work for personalisation's three separate times.
//
// Build and run: tsf/Ohagey/tools/build-and-run-imported.ps1

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

    std::string ToUtf8(const std::wstring& value)
    {
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
        if (bytes <= 0) return {};
        std::string utf8(static_cast<size_t>(bytes - 1), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
        return utf8;
    }

    bool ReadFileUtf8(const wchar_t* path, std::wstring* text)
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
        text->assign(static_cast<size_t>(chars), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()),
                            text->data(), chars);
        return true;
    }

    /// Reads `reading<TAB>expected` lines, skipping comments and blanks.
    ///
    /// Same format and same leniency as engine-personalization.cpp: the file is
    /// edited by hand, and one malformed line should not cost the whole run.
    bool ReadEvalSet(const wchar_t* path,
                     std::vector<std::wstring>* readings,
                     std::vector<std::wstring>* expected)
    {
        std::wstring text;
        if (!ReadFileUtf8(path, &text)) return false;

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

    /// Converts every reading and reports how many came first correctly.
    ///
    /// `show` prints the first few comparisons. A score on its own cannot be
    /// acted on: "0 of 32" reads identically whether the converter is wrong,
    /// the file failed to parse, or the two strings differ by a character
    /// nobody can see. Printing what came back distinguishes them immediately.
    size_t ScoreEvalSet(EngineClient& client,
                        const std::vector<std::wstring>& readings,
                        const std::vector<std::wstring>& expected,
                        std::vector<bool>* correct,
                        int show = 0)
    {
        correct->assign(readings.size(), false);
        size_t right = 0;
        for (size_t i = 0; i < readings.size(); ++i)
        {
            ConvertResult result;
            if (client.Convert(readings[i], 5, L"", &result) != CallResult::Ok)
            {
                if (static_cast<int>(i) < show) printf("    [%zu] convert FAILED\n", i);
                continue;
            }
            if (result.candidates.empty())
            {
                if (static_cast<int>(i) < show) printf("    [%zu] no candidates\n", i);
                continue;
            }
            const bool ok = result.candidates[0].text == expected[i];
            if (ok)
            {
                (*correct)[i] = true;
                ++right;
            }
            if (static_cast<int>(i) < show)
            {
                printf("    [%zu] %s ", i, ok ? "ok  " : "MISS");
                Say("", readings[i] + L" -> " + result.candidates[0].text
                         + L"   (expected " + expected[i] + L")");
            }
        }
        return right;
    }

    bool WriteUtf8File(const std::wstring& path, const std::string& contents)
    {
        const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        DWORD written = 0;
        const BOOL ok = WriteFile(file, contents.data(),
                                  static_cast<DWORD>(contents.size()), &written, nullptr);
        CloseHandle(file);
        return ok && written == contents.size();
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

    // argv[1] the text to import, argv[2] the evaluation set,
    // argv[3] how long to let the retraining land.
    const std::wstring corpusPath = (argc > 1) ? argv[1] : L"corpus-sample.txt";
    const std::wstring evalPath = (argc > 2) ? argv[2] : L"eval-set.tsv";
    // Resuming from the shipped 9.4 MB base costs about 8 seconds, and the duty
    // cycle can defer a run further. Fixed and generous rather than a poll that
    // stops when it likes the answer — decision 0034 was burned by exactly that,
    // and separately by measuring before a resumed run had landed at all.
    const int settleSeconds = (argc > 3) ? _wtoi(argv[3]) : 30;

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

    std::vector<std::wstring> readings;
    std::vector<std::wstring> expected;
    if (!ReadEvalSet(evalPath.c_str(), &readings, &expected))
    {
        printf("could not read the evaluation set\n");
        return 1;
    }

    std::wstring corpus;
    if (!ReadFileUtf8(corpusPath.c_str(), &corpus) || corpus.empty())
    {
        printf("could not read the text to import\n");
        return 1;
    }

    // The developer's own profile is not the harness's to write into. The
    // engine reads LOCALAPPDATA for its data directory (decision 0024), so a
    // scratch copy gives this run a fresh corpus, a fresh personal model, and
    // no way to leave anything behind.
    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-imported-check";
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
    printf("\n=== importing text (decision 0037) ===\n");
    printf("  model loaded: %s\n", ping.modelLoaded ? "yes" : "NO - this measures nothing");
    if (!ping.modelLoaded) return 1;

    std::vector<bool> before;
    printf("\n  baseline (first few shown):\n");
    const size_t rightBefore = ScoreEvalSet(client, readings, expected, &before, 6);
    printf("  before import: %zu of %zu correct at rank 1\n", rightBefore, readings.size());

    // ── A low baseline is a broken harness, not a clean run ────────────────
    //
    // "broke 0" is arithmetically true and completely worthless when nothing
    // was right to begin with: there is nothing left to break. This harness
    // reported exactly that on its first run — 0 of 32, ALL PASSED — because
    // the engine was answering, just not with these answers.
    //
    // Decision 0034 records three separate occasions where a measurement was
    // believed because it came back green. The threshold is deliberately
    // generous: the point is to catch "nothing works", not to police the
    // converter's accuracy, which the eval set's own header disclaims.
    if (rightBefore * 2 < readings.size())
    {
        printf("\n  REFUSING TO MEASURE: only %zu of %zu were right before the import.\n",
               rightBefore, readings.size());
        printf("  Anything this run reported about damage would be meaningless -- there is\n");
        printf("  nothing left to break. Fix the baseline first. Usual causes: the engine is\n");
        printf("  converting without Zenzai, the evaluation set does not match this build's\n");
        printf("  dictionary, or a stale engine binary is being launched.\n");
        return 2;
    }

    // ── Import, exactly the way the settings app does ──────────────────────
    //
    // A file written into personal/, and nothing else. The engine is not told;
    // it notices by modification date on the next conversion, which is the
    // mechanism under test as much as the training is (decision 0037).
    const std::wstring personal = scratch + L"\\Ohagey\\personal";
    CreateDirectoryW((scratch + L"\\Ohagey").c_str(), nullptr);
    CreateDirectoryW(personal.c_str(), nullptr);
    if (!WriteUtf8File(personal + L"\\imported.txt", ToUtf8(corpus)))
    {
        printf("  could not write imported.txt\n");
        return 1;
    }
    Say("  imported: ", corpusPath);

    // One conversion so the engine stats the file and starts a training run,
    // then the wait. Without the conversion nothing would ever look.
    ConvertResult ignored;
    client.Convert(readings[0], 5, L"", &ignored);
    printf("  waiting %ds for the retraining to land\n", settleSeconds);
    Sleep(static_cast<DWORD>(settleSeconds) * 1000);

    std::vector<bool> after;
    printf("\n  after import (first few shown):\n");
    const size_t rightAfter = ScoreEvalSet(client, readings, expected, &after, 6);

    size_t broke = 0;
    size_t fixed = 0;
    for (size_t i = 0; i < readings.size(); ++i)
    {
        if (before[i] && !after[i]) ++broke;
        if (!before[i] && after[i]) ++fixed;
    }

    printf("\n  correct at rank 1: %zu -> %zu of %zu   (broke %zu, fixed %zu)\n",
           rightBefore, rightAfter, readings.size(), broke, fixed);

    for (size_t i = 0; i < readings.size(); ++i)
    {
        if (!before[i] || after[i]) continue;
        ConvertResult now;
        client.Convert(readings[i], 5, L"", &now);
        printf("    BROKE ");
        Say("", readings[i] + L" -> " + (now.candidates.empty() ? L"(nothing)" : now.candidates[0].text)
                 + L"   (expected " + expected[i] + L")");
    }

    RemoveTree(scratch);

    // Non-zero when something broke, so this can gate a change rather than
    // only inform one. The assertion is "importing text does not cost you the
    // rest of the language" — the same one the user dictionary harness makes.
    if (broke > 0)
    {
        printf("\n  FAILED: importing text cost %zu previously-correct conversions.\n", broke);
        printf("  This is the failure mode of decision 0034. Check that the base model\n");
        printf("  is resumable (all five files) before concluding the import is at fault.\n");
        return 1;
    }

    printf("\n  ALL PASSED: importing text broke nothing.\n");
    return 0;
}
