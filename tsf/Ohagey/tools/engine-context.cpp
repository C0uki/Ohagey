// Does the text already on screen change the conversion? (decision 0007 / 0034)
//
// `ConvertRequest.preceding_text` has been on the wire since the first version
// of ohagey.proto, and until now the engine dropped it: the field arrived and
// the conversion was built without it. This measures what putting it back is
// worth.
//
// ── Why it is worth measuring separately ───────────────────────────────────
//
// Every other lever tried on conversion quality so far has been personalisation
// — the personal n-gram — and it breaks 15 to 18 of 30 otherwise-correct
// conversions to fix one (decision 0034). Left context is a different
// mechanism: nothing is trained, nothing is stored, and the model was trained
// with it. So the question here is not "does it help on average" but the more
// basic one: does what the user has already typed reach the model at all, and
// does it move the answer.
//
// ── The shape of the test ──────────────────────────────────────────────────
//
// Each reading below is genuinely ambiguous on its own and is converted three
// times: with no context, and with each of two contexts that should pull it in
// opposite directions. If the answer is the same all three times, the context
// is not reaching the model — or the model is ignoring it, which for the user
// amounts to the same thing.
//
// Build and run: tsf/Ohagey/tools/build-and-run-context.ps1

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

    std::string Utf8(const std::wstring& value)
    {
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
        if (bytes <= 0) return std::string();
        std::string utf8(static_cast<size_t>(bytes), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
        utf8.resize(static_cast<size_t>(bytes) - 1);
        return utf8;
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

    struct Ambiguity
    {
        const wchar_t* reading;
        // Two contexts that a reader would say decide the reading, and the word
        // each should decide it to.
        //
        // The word, not the whole candidate: `きかいをつくる` can come back as
        // 作る or つくる and both are fine, so comparing the full string would
        // score okurigana as a wrong word choice. What this harness is about is
        // 機械 against 機会.
        //
        // These are what a person would pick, not a promise about the model —
        // the counts are reported, and only the "context moved the answer at
        // all" property is asserted.
        const wchar_t* leftA;
        const wchar_t* wordA;
        const wchar_t* leftB;
        const wchar_t* wordB;
    };

    // Kept small and unambiguously ambiguous. Each pair differs only in the
    // context, so anything that changes between the two rows is the context.
    const Ambiguity kAmbiguities[] = {
        { L"きしゃがきた",   L"しんぶんしゃの",   L"記者", L"えきに",         L"汽車" },
        { L"はしをつかう",   L"かわをわたるのに", L"橋",   L"ごはんのときは", L"箸" },
        { L"こうえんにいく", L"こどもと",         L"公園", L"きょうじゅの",   L"講演" },
        { L"きかいをつくる", L"こうじょうで",     L"機械", L"つぎの",         L"機会" },
        { L"かていをみる",   L"けいさんの",       L"過程", L"それぞれの",     L"家庭" },
    };

    bool Picked(const std::wstring& candidate, const wchar_t* word)
    {
        return candidate.find(word) != std::wstring::npos;
    }

    // The top candidate, or an empty string when the call failed.
    std::wstring Top(EngineClient& client, const std::wstring& reading, const std::wstring& left)
    {
        ConvertResult result;
        if (client.Convert(reading, 5, left, &result) != CallResult::Ok) return std::wstring();
        if (result.candidates.empty()) return std::wstring();
        return result.candidates[0].text;
    }
}

int wmain()
{
    SetConsoleOutputCP(CP_UTF8);

    // Nothing is confirmed here, but the engine still creates its directories,
    // and a harness that leaves marks in the profile you type with is a harness
    // people stop running.
    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-context-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());
    printf("scratch profile: %s\n", Utf8(scratch).c_str());

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
    // Without the neural model this measures nothing: the lattice has no notion
    // of a left context, so all three answers would be the same by construction.
    Check(ping.modelLoaded, "Zenzai is active (otherwise there is nothing to measure)");
    if (!ping.modelLoaded) return 1;

    int moved = 0;
    int matched = 0;
    int matchedWithoutContext = 0;

    printf("\n");
    for (const Ambiguity& item : kAmbiguities)
    {
        const std::wstring bare = Top(client, item.reading, L"");
        const std::wstring withA = Top(client, item.reading, item.leftA);
        const std::wstring withB = Top(client, item.reading, item.leftB);

        printf("%s\n", Utf8(item.reading).c_str());
        printf("  (no context) -> %s\n", Utf8(bare).c_str());
        printf("  %s -> %s   [%s %s]\n", Utf8(item.leftA).c_str(), Utf8(withA).c_str(),
               Picked(withA, item.wordA) ? "wanted" : "MISSED", Utf8(item.wordA).c_str());
        printf("  %s -> %s   [%s %s]\n", Utf8(item.leftB).c_str(), Utf8(withB).c_str(),
               Picked(withB, item.wordB) ? "wanted" : "MISSED", Utf8(item.wordB).c_str());

        if (withA != withB) ++moved;
        if (Picked(withA, item.wordA)) ++matched;
        if (Picked(withB, item.wordB)) ++matched;
        if (Picked(bare, item.wordA)) ++matchedWithoutContext;
        if (Picked(bare, item.wordB)) ++matchedWithoutContext;
        printf("\n");
    }

    const int total = static_cast<int>(sizeof(kAmbiguities) / sizeof(kAmbiguities[0]));
    printf("  the two contexts disagreed on %d of %d readings\n", moved, total);
    printf("  picked the word a person would: %d of %d with context\n", matched, total * 2);
    // Printed with its ceiling because the number looks worse than it is: with
    // no context there is one answer for two situations, and the two words are
    // mutually exclusive, so half of these cannot be won. It is a floor to
    // beat, not a fair rival.
    printf("  ... %d of %d for the same conversions with no context (ceiling %d)\n",
           matchedWithoutContext, total * 2, total);

    // The one assertion. Not "the model is right more often" — that is a
    // quality number and it is printed above — but the plumbing question this
    // harness exists for: the same reading, converted with two different left
    // contexts, has to be able to come out differently. If it never does, the
    // context is not reaching the model.
    Check(moved > 0, "the preceding text reaches the model and changes the answer");

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
