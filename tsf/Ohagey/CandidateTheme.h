// Colours for the candidate window, following the system (decision 0012).
//
// Read from the registry rather than through Windows.UI.ViewManagement:
// WinRT would pull an activation dependency into a DLL that loads into every
// application the user types in, which is the same reasoning as decision 0032.
// The two values we need have lived at these keys since Windows 10.

#pragma once

#include <windows.h>
#include <d2d1.h>

namespace Ohagey
{
    struct CandidateTheme
    {
        bool darkMode = false;

        D2D1_COLOR_F background;
        D2D1_COLOR_F text;
        // The index number down the left: present but not competing with the
        // candidate itself.
        D2D1_COLOR_F secondaryText;
        D2D1_COLOR_F selectionBackground;
        D2D1_COLOR_F selectionText;
        D2D1_COLOR_F border;

        // Reads the current system appearance. Cheap enough to call whenever
        // the window repaints, which is also how it picks up a theme change
        // without needing to listen for one.
        static CandidateTheme FromSystem();

        // True when the two describe a different appearance, so a cached
        // theme can be compared against a freshly read one.
        bool operator!=(const CandidateTheme& other) const;

        // ── The colour rules, separated from reading the registry ───────────
        //
        // Public so they can be tested against accents the machine running the
        // tests does not happen to be set to. The invariant that matters —
        // that the selected candidate stays visible — is not something to find
        // out about from a user whose accent is the same colour as their
        // window background.

        // WCAG relative-luminance contrast ratio, 1.0 (identical) to 21.0.
        static float ContrastRatio(const D2D1_COLOR_F& a, const D2D1_COLOR_F& b);

        // The accent, moved far enough from `background` to be visible.
        static D2D1_COLOR_F SelectionBackgroundFor(const D2D1_COLOR_F& accent,
                                                   const D2D1_COLOR_F& background,
                                                   bool darkMode);

        // Black or white, whichever reads better on `background`.
        static D2D1_COLOR_F TextOn(const D2D1_COLOR_F& background);

        // What `SelectionBackgroundFor` guarantees against the window
        // background, and what a UI component needs under WCAG.
        static const float kMinimumSelectionContrast;
    };
}
