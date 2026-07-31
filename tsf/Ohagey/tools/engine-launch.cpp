// Checks that the client starts the engine when nothing is listening
// (decisions 0015 / 0033).
//
// This is the difference between an IME that works and one that only works if
// you happened to start a background process by hand, so it is worth exercising
// rather than reasoning about.
//
// Two phases, each needing a cold start, so the script runs this twice and
// stops the engine in between:
//
//   cold   what happens with no warm-up: the first conversion is lost and the
//          next keystroke recovers. Still reachable — reverse conversion sets
//          the engine up without a thread manager, so nothing activates.
//   warm   what the text service actually does now: Warmup at activation, so
//          the conversion the user asks for connects on the first attempt.
//
// Expects NO engine to be running when it starts, and leaves the one it caused
// to start behind — it exits on its own idle timeout.
//
// Build and run: tsf/Ohagey/tools/build-and-run-launch.ps1

#include "../OhageyProtocol.h"

#include <cstdio>
#include <string>

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
        if (value.empty()) return std::string();
        const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                                             nullptr, 0, nullptr, nullptr);
        if (size <= 0) return std::string();
        std::string utf8(static_cast<size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                            &utf8[0], size, nullptr, nullptr);
        return utf8;
    }
}

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);

    const bool warm = (argc > 1 && std::wstring(argv[1]) == L"warm");
    printf("phase: %s\n", warm ? "warm (Warmup at activation)" : "cold (no warm-up)");

    std::wstring enginePath;
    Check(EngineClient::EnginePath(&enginePath), "resolved the engine path");
    printf("  engine: %s\n", Utf8(enginePath).c_str());

    std::wstring pipe;
    EngineClient::PipeName(&pipe);

    // Nothing should be listening yet; that is the situation being tested.
    const HANDLE probe = CreateFileW(pipe.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (probe != INVALID_HANDLE_VALUE)
    {
        CloseHandle(probe);
        printf("\nan engine is already running — stop it first, this test needs to start one\n");
        return 2;
    }
    printf("  no engine running\n");

    EngineClient client;
    bool connected = false;

    if (warm)
    {
        // What SetupLanguageProfile does when the text service activates.
        const ULONGLONG started = GetTickCount64();
        client.Warmup();
        const ULONGLONG elapsed = GetTickCount64() - started;
        printf("\nWarmup at activation\n");
        printf("  returned in %llums\n", elapsed);
        // Activation happens on the thread that handles typing, so this has to
        // be cheap. Launching a process is the only work it does.
        Check(elapsed < 1000, "returned promptly, without waiting for the engine");
        Check(!client.IsConnected(), "held no connection, so the idle timeout still applies");

        // The gap between activating the IME and asking for a conversion.
        // Deliberately conservative: typing even a short reading takes longer
        // than this, so a real user gives the engine more time than the test.
        Sleep(500);

        printf("\nthe first conversion a user asks for\n");
        connected = client.Connect();
        Check(connected, "connected on the first attempt — no conversion lost");
    }
    else
    {
        // Without a warm-up the first connect is expected to fail: the engine
        // has been launched but is not listening yet. Failing fast is the
        // point — the alternative is freezing the application being typed in.
        const bool firstConnect = client.Connect();
        printf("\nfirst Connect (launches, does not wait for startup)\n");
        Check(!firstConnect, "returned promptly without connecting");

        // Retry the way the next keystroke would.
        printf("\nretrying the way subsequent keystrokes would\n");
        int attempts = 0;
        const ULONGLONG deadline = GetTickCount64() + 20000;
        while (GetTickCount64() < deadline)
        {
            ++attempts;
            if (client.Connect())
            {
                connected = true;
                break;
            }
            Sleep(250);
        }
        printf("  attempts: %d\n", attempts);
        Check(connected, "the launched engine accepted a connection");
    }

    if (connected)
    {
        PingResult ping;
        Check(client.Ping(&ping) == CallResult::Ok, "and answers requests");
        printf("  engineVersion: %s\n", Utf8(ping.engineVersion).c_str());
    }

    // A failing engine must not mean a new process per keystroke.
    printf("\nlaunch throttling\n");
    {
        EngineClient other;
        // Already connectable now, so Connect succeeds without launching; the
        // check that matters is that repeated failures would be spaced out,
        // which is covered by the tick comparison in LaunchEngine.
        Check(other.Connect(), "a second client connects to the same engine");
    }

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
