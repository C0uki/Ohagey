// See CandidateTheme.h.

#include "CandidateTheme.h"

#include <cmath>

namespace Ohagey
{
    namespace
    {
        bool ReadDword(HKEY root, const wchar_t* subKey, const wchar_t* value, DWORD* out)
        {
            DWORD data = 0;
            DWORD size = sizeof(data);
            DWORD type = 0;
            const LSTATUS status = RegGetValueW(root, subKey, value, RRF_RT_REG_DWORD,
                                                &type, &data, &size);
            if (status != ERROR_SUCCESS) return false;
            *out = data;
            return true;
        }

        D2D1_COLOR_F Rgb(BYTE r, BYTE g, BYTE b, float a = 1.0f)
        {
            return D2D1::ColorF(r / 255.0f, g / 255.0f, b / 255.0f, a);
        }

        /// The system accent colour, or a sensible blue if it cannot be read.
        ///
        /// `AccentColor` is stored ABGR, not ARGB — reading it as ARGB gives a
        /// plausible-looking but wrong colour, which is the kind of mistake
        /// that survives review because the result is still a colour.
        D2D1_COLOR_F SystemAccent(bool darkMode)
        {
            DWORD raw = 0;
            if (ReadDword(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM",
                          L"AccentColor", &raw))
            {
                const BYTE r = static_cast<BYTE>(raw & 0xFF);
                const BYTE g = static_cast<BYTE>((raw >> 8) & 0xFF);
                const BYTE b = static_cast<BYTE>((raw >> 16) & 0xFF);
                return Rgb(r, g, b);
            }
            // Windows' default accent.
            return darkMode ? Rgb(0x60, 0xCD, 0xFF) : Rgb(0x00, 0x78, 0xD4);
        }

        /// sRGB relative luminance, as WCAG defines it.
        ///
        /// The channel values have to be linearized first: sRGB is gamma
        /// encoded, and averaging the encoded values reports mid greys as far
        /// brighter than they look.
        float RelativeLuminance(const D2D1_COLOR_F& color)
        {
            const auto linear = [](float channel)
            {
                return channel <= 0.03928f
                    ? channel / 12.92f
                    : std::pow((channel + 0.055f) / 1.055f, 2.4f);
            };
            return 0.2126f * linear(color.r)
                 + 0.7152f * linear(color.g)
                 + 0.0722f * linear(color.b);
        }

        float ContrastRatioImpl(const D2D1_COLOR_F& a, const D2D1_COLOR_F& b)
        {
            const float la = RelativeLuminance(a);
            const float lb = RelativeLuminance(b);
            const float lighter = la > lb ? la : lb;
            const float darker = la > lb ? lb : la;
            return (lighter + 0.05f) / (darker + 0.05f);
        }

        /// Whether text on `background` should be dark or light.
        ///
        /// The accent colour is user-chosen and can be anything from navy to
        /// pale yellow, so the selected candidate's colour cannot be a constant.
        D2D1_COLOR_F ContrastingTextImpl(const D2D1_COLOR_F& background)
        {
            return ContrastRatioImpl(background, Rgb(0, 0, 0))
                 > ContrastRatioImpl(background, Rgb(0xFF, 0xFF, 0xFF))
                ? Rgb(0x00, 0x00, 0x00)
                : Rgb(0xFF, 0xFF, 0xFF);
        }

        /// Moves `accent` until the selected row is visible against the window.
        ///
        /// Windows lets the user pick an accent that is nearly their window
        /// background — this was found on a machine set to #161616 with the
        /// dark theme, where the selected candidate came out as a black
        /// rectangle on dark grey and simply could not be seen. Selection is
        /// the one thing in this window that has to be obvious.
        ///
        /// Blends toward white or black rather than substituting a different
        /// colour, so the user's choice still shows through wherever it can.
        D2D1_COLOR_F EnsureVisibleSelectionImpl(D2D1_COLOR_F accent,
                                            const D2D1_COLOR_F& background,
                                            bool darkMode)
        {
            // 3:1 is what WCAG asks of a UI component against its surroundings.
            const float required = CandidateTheme::kMinimumSelectionContrast;
            const D2D1_COLOR_F target = darkMode ? Rgb(0xFF, 0xFF, 0xFF) : Rgb(0x00, 0x00, 0x00);

            for (int step = 0; step < 20 && ContrastRatioImpl(accent, background) < required; ++step)
            {
                const float amount = 0.06f;
                accent.r += (target.r - accent.r) * amount;
                accent.g += (target.g - accent.g) * amount;
                accent.b += (target.b - accent.b) * amount;
            }
            return accent;
        }
    }

    const float CandidateTheme::kMinimumSelectionContrast = 3.0f;

    float CandidateTheme::ContrastRatio(const D2D1_COLOR_F& a, const D2D1_COLOR_F& b)
    {
        return ContrastRatioImpl(a, b);
    }

    D2D1_COLOR_F CandidateTheme::TextOn(const D2D1_COLOR_F& background)
    {
        return ContrastingTextImpl(background);
    }

    D2D1_COLOR_F CandidateTheme::SelectionBackgroundFor(const D2D1_COLOR_F& accent,
                                                        const D2D1_COLOR_F& background,
                                                        bool darkMode)
    {
        return EnsureVisibleSelectionImpl(accent, background, darkMode);
    }

    CandidateTheme CandidateTheme::FromSystem()
    {
        CandidateTheme theme;

        // Absent on older systems, where light was the only option.
        DWORD appsUseLightTheme = 1;
        ReadDword(HKEY_CURRENT_USER,
                  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                  L"AppsUseLightTheme", &appsUseLightTheme);
        theme.darkMode = (appsUseLightTheme == 0);

        const D2D1_COLOR_F accent = SystemAccent(theme.darkMode);

        if (theme.darkMode)
        {
            theme.background = Rgb(0x2B, 0x2B, 0x2B, 0.96f);
            theme.text = Rgb(0xFF, 0xFF, 0xFF);
            theme.secondaryText = Rgb(0x9A, 0x9A, 0x9A);
            theme.border = Rgb(0x00, 0x00, 0x00, 0.40f);
        }
        else
        {
            theme.background = Rgb(0xF9, 0xF9, 0xF9, 0.96f);
            theme.text = Rgb(0x1A, 0x1A, 0x1A);
            theme.secondaryText = Rgb(0x60, 0x60, 0x60);
            theme.border = Rgb(0x00, 0x00, 0x00, 0.12f);
        }

        theme.selectionBackground = SelectionBackgroundFor(accent, theme.background, theme.darkMode);
        theme.selectionText = TextOn(theme.selectionBackground);
        return theme;
    }

    bool CandidateTheme::operator!=(const CandidateTheme& other) const
    {
        const auto same = [](const D2D1_COLOR_F& a, const D2D1_COLOR_F& b)
        {
            const float epsilon = 1.0f / 512.0f;
            return std::fabs(a.r - b.r) < epsilon
                && std::fabs(a.g - b.g) < epsilon
                && std::fabs(a.b - b.b) < epsilon
                && std::fabs(a.a - b.a) < epsilon;
        };

        return darkMode != other.darkMode
            || !same(background, other.background)
            || !same(text, other.text)
            || !same(secondaryText, other.secondaryText)
            || !same(selectionBackground, other.selectionBackground)
            || !same(selectionText, other.selectionText)
            || !same(border, other.border);
    }
}
