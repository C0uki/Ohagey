// Round-trips the hand-written wire codec against a real OhageyEngine.
//
// This is the check that makes decision 0032 defensible. The engine encodes
// with swift-protobuf's generated code, so anything this client gets wrong —
// a field number, a varint, UTF-8 handling, the oneof shape — shows up here.
// Reading our own encoder back with our own decoder would prove nothing.
//
// Build and run: tsf/Ohagey/tools/build-and-run.ps1 (engine must be running).

#include "../OhageyProtocol.h"

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

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
            g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
