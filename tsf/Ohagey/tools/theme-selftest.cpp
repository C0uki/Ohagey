// Tests the candidate window's colour rules (decision 0012).
//
// The invariant worth guarding is that the selected candidate stays visible.
// Windows lets the user pick any accent colour, including one that matches
// their window background — this was found on a machine set to #161616 with
// the dark theme, where selection came out as a black rectangle on dark grey.
//
// Whether that happens depends on a setting of the machine running the code, so
// it cannot be left to whatever the developer's accent happens to be.
//
// Build and run: tsf/Ohagey/tools/build-and-run-theme.ps1

#include "../CandidateTheme.h"

#include <cstdio>

using namespace Ohagey;

namespace
{
    int g_failures = 0;

    D2D1_COLOR_F Rgb(int r, int g, int b)
    {
        return D2D1::ColorF(r / 255.0f, g / 255.0f, b / 255.0f, 1.0f);
    }

    void Check(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }

    struct Named { const char* name; D2D1_COLOR_F color; };
}

int main()
{
    const D2D1_COLOR_F darkWindow = Rgb(0x2B, 0x2B, 0x2B);
    const D2D1_COLOR_F lightWindow = Rgb(0xF9, 0xF9, 0xF9);

    printf("contrast ratio\n");
    Check(CandidateTheme::ContrastRatio(Rgb(0, 0, 0), Rgb(255, 255, 255)) > 20.9f,
          "black on white is 21:1");
    Check(CandidateTheme::ContrastRatio(Rgb(80, 80, 80), Rgb(80, 80, 80)) < 1.01f,
          "a colour against itself is 1:1");

    // Accents a user can actually select, including the pathological ones.
    const Named accents[] = {
        { "near-black  #161616", Rgb(0x16, 0x16, 0x16) },
        { "near-white  #F2F2F2", Rgb(0xF2, 0xF2, 0xF2) },
        { "windows blue #0078D4", Rgb(0x00, 0x78, 0xD4) },
        { "pale yellow #FFF4A3", Rgb(0xFF, 0xF4, 0xA3) },
        { "deep navy   #001B3D", Rgb(0x00, 0x1B, 0x3D) },
        { "hot pink    #E3008C", Rgb(0xE3, 0x00, 0x8C) },
        { "mid grey    #2B2B2B", Rgb(0x2B, 0x2B, 0x2B) },
    };

    for (int dark = 0; dark <= 1; ++dark)
    {
        const D2D1_COLOR_F window = dark ? darkWindow : lightWindow;
        printf("\nselection on the %s theme\n", dark ? "dark" : "light");

        for (size_t i = 0; i < sizeof(accents) / sizeof(accents[0]); ++i)
        {
            const D2D1_COLOR_F selection =
                CandidateTheme::SelectionBackgroundFor(accents[i].color, window, dark != 0);
            const D2D1_COLOR_F text = CandidateTheme::TextOn(selection);

            const float againstWindow = CandidateTheme::ContrastRatio(selection, window);
            const float againstText = CandidateTheme::ContrastRatio(selection, text);

            char label[160];
            // The selection has to be distinguishable from the window...
            sprintf_s(label, "%-22s selection vs window %4.1f:1", accents[i].name, againstWindow);
            Check(againstWindow >= CandidateTheme::kMinimumSelectionContrast - 0.01f, label);

            // ...and the candidate on it has to be readable.
            sprintf_s(label, "%-22s text vs selection    %4.1f:1", accents[i].name, againstText);
            Check(againstText >= 4.5f, label);
        }
    }

    printf("\nthe user's accent is kept when it already works\n");
    {
        // #0078D4 on white needs no help; adjusting it anyway would override a
        // choice the user made for no reason.
        const D2D1_COLOR_F accent = Rgb(0x00, 0x78, 0xD4);
        const D2D1_COLOR_F selection =
            CandidateTheme::SelectionBackgroundFor(accent, lightWindow, false);
        Check(CandidateTheme::ContrastRatio(selection, accent) < 1.05f,
              "an accent that already contrasts is left alone");
    }

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
