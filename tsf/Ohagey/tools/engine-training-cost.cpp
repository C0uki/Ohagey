// Sends enough commits to trigger one personalisation training run
// (decision 0034).
//
// Exists to answer a question the roadmap left open: retraining happens every
// 20 commits, so "I corrected the same word three times" does nothing. Whether
// that threshold can come down depends on what a training run costs, and the
// cost is not a constant — training reads the whole corpus every time, so it
// grows with how long someone has been using the IME.
//
// This half just drives the commits. The corpus is seeded, the engine is
// launched and the timing is read from its log by
// build-and-run-training-cost.ps1, which is also what keeps this off the
// profile you actually type with (LOCALAPPDATA is redirected before the engine
// starts).

#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "../OhageyProtocol.h"

using namespace Ohagey;

int wmain(int argc, wchar_t** argv)
{
    // One more than the threshold would be wasteful; exactly the threshold is
    // what a real user reaches. Passed in so the harness stays in charge of
    // what it is measuring.
    const int commits = argc > 1 ? _wtoi(argv[1]) : 20;

    EngineClient client;
    if (!client.Connect())
    {
        printf("could not connect — the harness starts the engine itself\n");
        return 2;
    }

    // Distinct phrases rather than one repeated: an n-gram model trained on a
    // single line is not the shape of anything, and the timing would not
    // reflect a real corpus.
    for (int i = 0; i < commits; ++i)
    {
        wchar_t reading[64];
        wchar_t text[64];
        swprintf_s(reading, L"てすとぶんしょう%d", i);
        swprintf_s(text, L"テスト文章%d", i);
        // updateLearning: without it the engine drops the commit before it
        // reaches the corpus, and there is nothing to train on.
        if (client.Commit(reading, text, true) != CallResult::Ok)
        {
            printf("commit %d failed\n", i);
            return 1;
        }
    }

    printf("sent %d commits\n", commits);
    return 0;
}
