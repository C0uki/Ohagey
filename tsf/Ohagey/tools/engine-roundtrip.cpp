// Round-trips the hand-written wire codec against a real OhageyEngine.
//
// This is the check that makes decision 0032 defensible. The engine encodes
// with swift-protobuf's generated code, so anything this client gets wrong —
// a field number, a varint, UTF-8 handling, the oneof shape — shows up here.
// Reading our own encoder back with our own decoder would prove nothing.
//
// Build and run: tsf/Ohagey/tools/build-and-run.ps1 (engine must be running).

#include "../OhageyProtocol.h"
#include "../RomajiKana.h"

#include <cstdio>
#include <string>

using namespace Ohagey;

namespace
{
    int g_failures = 0;

    // Recursive delete, for the scratch profile. Same helper as the
    // personalisation harness; kept local rather than shared because these
    // files are meant to be readable on their own.
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

    // Everything prints through printf. Mixing wprintf and printf on stdout
    // fights over the stream's orientation and silently drops one of them, so
    // the harness stays narrow and converts wide strings itself.
    void Say(const char* label, const std::wstring& value)
    {
        std::string utf8;
        if (!value.empty())
        {
            const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                                 static_cast<int>(value.size()),
                                                 nullptr, 0, nullptr, nullptr);
            if (size > 0)
            {
                utf8.resize(static_cast<size_t>(size));
                WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                                    &utf8[0], size, nullptr, nullptr);
            }
        }
        printf("%s%s\n", label, utf8.c_str());
    }

    void Check(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }

    const char* ResultName(CallResult r)
    {
        switch (r)
        {
        case CallResult::Ok: return "Ok";
        case CallResult::NotConnected: return "NotConnected";
        case CallResult::WriteFailed: return "WriteFailed";
        case CallResult::ReadFailed: return "ReadFailed";
        case CallResult::BadResponse: return "BadResponse";
        case CallResult::Status: return "Status";
        }
        return "?";
    }
}

int wmain()
{
    SetConsoleOutputCP(CP_UTF8);

    // ── Your own data is not touched ────────────────────────────────────────
    //
    // The learning section below confirms candidates, and a confirmed candidate
    // goes into the corpus the personal language model is trained from
    // (decisions 0024 / 0034). Against a developer's own engine that is the
    // profile they type with — measured, this harness had quietly put 21 copies
    // of 変換 and 返還 into one, and trained a model from them.
    //
    // So LOCALAPPDATA is redirected before the engine is launched, exactly as
    // the personalisation and user-dictionary harnesses do. An engine that is
    // already up has the real path, so this refuses rather than using it.
    wchar_t temp[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"ohagey-roundtrip-check";
    RemoveTree(scratch);
    CreateDirectoryW(scratch.c_str(), nullptr);
    SetEnvironmentVariableW(L"LOCALAPPDATA", scratch.c_str());
    Say("scratch profile: ", scratch);

    std::wstring pipe;
    EngineClient::PipeName(&pipe);
    Say("pipe: ", pipe);

    // Opened directly rather than through Connect, which would *launch* one
    // (decisions 0015 / 0033) — and the point of the check is to catch an
    // engine that was started with the real profile.
    {
        const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr,
                                         OPEN_EXISTING, 0, nullptr);
        if (probe != INVALID_HANDLE_VALUE)
        {
            CloseHandle(probe);
            printf("An engine is already running. Close it first: this harness confirms\n"
                   "candidates, and those would be learned into the profile you type with.\n");
            return 1;
        }
    }

    EngineClient client;
    // A cold start loads the dictionary and the Zenzai weights before it
    // listens, which takes longer than Connect's own one-second budget.
    bool connected = false;
    for (int attempt = 0; attempt < 60 && !connected; ++attempt)
    {
        connected = client.Connect();
        if (!connected) Sleep(1000);
    }
    if (!connected)
    {
        printf("could not connect (error %lu)\n", GetLastError());
        return 2;
    }
    printf("connected\n\n");

    // ── Ping ────────────────────────────────────────────────────────────────
    printf("Ping\n");
    PingResult ping;
    CallResult r = client.Ping(&ping);
    Check(r == CallResult::Ok, "call succeeded");
    if (r == CallResult::Ok)
    {
        Say("  engineVersion: ", ping.engineVersion);
        printf("  modelLoaded: %s, backend: %d\n",
                ping.modelLoaded ? "true" : "false", static_cast<int>(ping.backend));
        Check(!ping.engineVersion.empty(), "engine_version decoded");
        Check(ping.backend != Backend::Unspecified, "backend decoded");
    }

    // ── Convert ─────────────────────────────────────────────────────────────
    printf("\nConvert(\"へんかん\", n_best=5)\n");
    ConvertResult convert;
    r = client.Convert(L"へんかん", 5, L"", &convert);
    Check(r == CallResult::Ok, "call succeeded");
    if (r == CallResult::Ok)
    {
        Check(!convert.candidates.empty(), "got candidates");
        // n_best is a maximum the engine promises to honour.
        Check(convert.candidates.size() <= 5, "honoured n_best");
        for (size_t i = 0; i < convert.candidates.size() && i < 5; ++i)
        {
            printf("  %zu. ", i + 1);
            Say("", convert.candidates[i].text);
        }
        // Round-tripping UTF-8 both ways is the part most likely to be subtly
        // wrong, so assert the reading came back exactly as sent.
        Check(!convert.candidates.empty() && convert.candidates[0].reading == L"へんかん",
              "reading round-tripped through UTF-8");
        printf("  zenzaiUsed: %s\n", convert.zenzaiUsed ? "true" : "false");
    }

    // ── Convert with context ────────────────────────────────────────────────
    printf("\nConvert(\"きょうはいいてんきですね\") with preceding text\n");
    ConvertResult sentence;
    r = client.Convert(L"きょうはいいてんきですね", 3, L"こんにちは。", &sentence);
    Check(r == CallResult::Ok, "call succeeded");
    if (r == CallResult::Ok && !sentence.candidates.empty())
    {
        Say("  top: ", sentence.candidates[0].text);
    }

    // ── Commit ──────────────────────────────────────────────────────────────
    printf("\nCommit\n");
    r = client.Commit(L"へんかん", L"変換", false);
    Check(r == CallResult::Ok, "empty-body response decoded");

    // RegisterWord used to be exercised here, back when it was expected to
    // fail because the user dictionary was not implemented. It is now
    // (decisions 0026 / 0036), which made this a call that quietly succeeded —
    // writing a word into whichever dictionary the running engine happens to
    // own, which for a developer is the one they type with. The dedicated
    // harness does it against a scratch profile instead:
    // build-and-run-userdict.ps1.

    // ── A bad request must not cost us the connection (decision 0030) ──────
    printf("\nConvert(\"\") — invalid, connection must survive\n");
    ConvertResult empty;
    r = client.Convert(L"", 5, L"", &empty);
    Check(r == CallResult::Status, "got a correlated failure");
    Check(client.LastStatus() == StatusCode::InvalidArgument, "INVALID_ARGUMENT");
    Check(client.IsConnected(), "still connected");

    printf("\nPing again on the same connection\n");
    PingResult ping2;
    r = client.Ping(&ping2);
    Check(r == CallResult::Ok, "connection survived the bad request");

    // ── The path a user actually takes: romaji in, candidates out ──────────
    //
    // This is what the TSF layer does on every keystroke: resolve romaji to
    // kana, then ask the engine. Testing the two halves separately would leave
    // the seam between them — which is where the reading was wrong until the
    // converter existed — unchecked.
    printf("\nromaji -> kana -> engine\n");
    {
        struct Case { const wchar_t* romaji; const wchar_t* expectedKana; };
        const Case cases[] = {
            { L"henkan",   L"へんかん" },
            { L"nihongo",  L"にほんご" },
            { L"sannin",   L"さんにん" },
            { L"gakkou",   L"がっこう" },
        };

        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
        {
            const std::wstring kana = RomajiToKana(cases[i].romaji);
            Say("  ", std::wstring(cases[i].romaji) + L" -> " + kana);
            Check(kana == cases[i].expectedKana, "romaji resolved to the expected kana");

            ConvertResult typed;
            const CallResult typedResult = client.Convert(kana, 3, L"", &typed);
            Check(typedResult == CallResult::Ok && !typed.candidates.empty(),
                  "engine returned candidates for it");
            if (typedResult == CallResult::Ok && !typed.candidates.empty())
            {
                Say("     top: ", typed.candidates[0].text);
            }
        }
    }

    // ── Learning (decisions 0024 / 0025) ───────────────────────────────────
    //
    // Confirming a candidate the engine did not rank first should move it up
    // next time. This is the only way to tell that Commit does anything: the
    // call returns success either way.
    //
    // NOTE: this writes to the real learning store under %LOCALAPPDATA%\Ohagey.
    // That is regenerable, but it does mean running this harness nudges your
    // own conversion rankings.
    printf("\nlearning\n");
    {
        const std::wstring reading = L"へんかん";
        ConvertResult before;
        r = client.Convert(reading, 5, L"", &before);

        if (r == CallResult::Ok && before.candidates.size() >= 2)
        {
            const std::wstring first = before.candidates[0].text;
            const std::wstring second = before.candidates[1].text;
            Say("  before: 1st=", first);
            Say("          2nd=", second);

            // Confirmed several times, not once.
            //
            // Learning accumulates and persists, so this test's starting point
            // is whatever previous runs left behind: a single confirmation is
            // enough from a clean store but not necessarily enough to outweigh
            // a candidate that earlier runs already reinforced. Repeating makes
            // the assertion hold regardless of prior state.
            bool committed = true;
            for (int attempt = 0; attempt < 3; ++attempt)
            {
                if (client.Commit(reading, second, true) != CallResult::Ok) committed = false;
                ConvertResult reconvert;
                client.Convert(reading, 5, L"", &reconvert);
            }
            Check(committed, "committed the second candidate");

            ConvertResult after;
            r = client.Convert(reading, 5, L"", &after);
            Check(r == CallResult::Ok && !after.candidates.empty(), "converted again");
            if (r == CallResult::Ok && !after.candidates.empty())
            {
                Say("  after:  1st=", after.candidates[0].text);
                const bool promoted = (after.candidates[0].text == second);

                if (before.zenzaiUsed)
                {
                    // Not asserted either way here. The learning store feeds
                    // the lattice, which sits underneath the neural model, so
                    // these three confirmations are not expected to move the
                    // top candidate on their own.
                    //
                    // What *does* reach Zenzai's ranking is the personal
                    // language model (decision 0034), and it needs a batch of
                    // commits and a retraining run — too slow and too stateful
                    // to fold into this harness. It has its own:
                    // build-and-run-personalization.ps1.
                    printf("  [ -- ] ranking %s (Zenzai on — see build-and-run-personalization.ps1)\n",
                           promoted ? "changed" : "unchanged");
                }
                else
                {
                    // Dictionary-only: the learning store *is* the ranking, so
                    // a confirmation has to show up.
                    Check(promoted, "the confirmed candidate is now ranked first");
                }
            }
        }
        else
        {
            Check(false, "needed at least two candidates to test learning");
        }
    }

    RemoveTree(scratch);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
            g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
