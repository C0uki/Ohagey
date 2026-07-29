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

    std::wstring pipe;
    EngineClient::PipeName(&pipe);
    Say("pipe: ", pipe);

    EngineClient client;
    if (!client.Connect())
    {
        printf("could not connect (error %lu) — is OhageyEngine running?\n", GetLastError());
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

    // ── RegisterWord: expected to fail, and to say why ─────────────────────
    printf("\nRegisterWord (user dictionary is not implemented — decision 0026)\n");
    r = client.RegisterWord(L"おはぎー", L"Ohagey", L"名詞");
    Check(r == CallResult::Status, "reported as a status failure, not a transport error");
    if (r == CallResult::Status)
    {
        printf("  status: %d\n", static_cast<int>(client.LastStatus()));
        Say("  message: ", client.LastStatusMessage());
    }

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
                    // Expected: Zenzai re-ranks with the neural model and the
                    // learning store feeds the lattice underneath it, so one
                    // confirmation does not move the top candidate.
                    // Personalizing Zenzai itself needs
                    // ZenzaiMode.PersonalizationMode and its n-gram models,
                    // which we do not ship yet.
                    printf("  [ -- ] ranking %s (Zenzai on — learning is not expected to reorder)\n",
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

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
            g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
