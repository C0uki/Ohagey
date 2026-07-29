// Candidate window drawing with Direct2D + DirectWrite (decisions 0011 / 0012).
//
// Replaces the sample's ExtTextOut/FillRect painting. DirectWrite matters here
// beyond looks: it shapes and measures Japanese properly, where the GDI path
// positioned everything on a grid of `tmAveCharWidth` cells and assumed every
// glyph fit one.
//
// STEP ONE OF TWO. This draws onto the window's HDC through an
// ID2D1DCRenderTarget, so the existing WM_PAINT plumbing keeps working.
// Decision 0011 wants DirectComposition, which needs a differently created
// window (WS_EX_NOREDIRECTIONBITMAP and a visual tree) and touches BaseWindow.
// Everything below the render target — layout, text formats, brushes, the
// drawing itself — carries over unchanged when that happens.

#pragma once

#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

#include <string>
#include <vector>

#include "CandidateTheme.h"

namespace Ohagey
{
    struct CandidateRow
    {
        // The digit the user presses to pick this candidate.
        std::wstring label;
        std::wstring text;
        bool selected = false;
    };

    class CandidateRenderer
    {
    public:
        CandidateRenderer() = default;
        ~CandidateRenderer();

        CandidateRenderer(const CandidateRenderer&) = delete;
        CandidateRenderer& operator=(const CandidateRenderer&) = delete;

        // Creates the device-independent resources. Failing is survivable: the
        // caller falls back to the GDI path rather than leaving the user
        // without a candidate window.
        bool Initialize();
        void Release();
        bool IsAvailable() const { return _dwriteFactory != nullptr && _d2dFactory != nullptr; }

        // Draws the whole window. `bounds` is in pixels, client-relative.
        bool Draw(HDC dc, const RECT& bounds, const std::vector<CandidateRow>& rows);

        // Height of one row, in pixels, for the window's sizing and hit
        // testing. Derived from the font's own metrics rather than a constant.
        int RowHeight() const;

        // Width needed to show `text` without clipping, in pixels.
        int MeasureTextWidth(const std::wstring& text) const;

        // Width reserved for the index column, in pixels.
        int LabelColumnWidth() const;

    private:
        bool EnsureTextFormats();
        void DrawRow(ID2D1RenderTarget* target, const CandidateRow& row,
                     const D2D1_RECT_F& bounds, const CandidateTheme& theme);

        ID2D1Factory* _d2dFactory = nullptr;
        IDWriteFactory* _dwriteFactory = nullptr;
        ID2D1DCRenderTarget* _target = nullptr;
        IDWriteTextFormat* _textFormat = nullptr;
        IDWriteTextFormat* _labelFormat = nullptr;
        float _rowHeight = 0.0f;
    };

    // Asks DWM for rounded corners and a Fluent backdrop (decision 0012).
    //
    // Both attributes are Windows 11; on anything older DwmSetWindowAttribute
    // fails and the window simply looks like it did before, which is why the
    // result is not checked.
    void ApplyFluentWindowStyle(HWND window);
}
