// See CandidateRenderer.h.

#include "CandidateRenderer.h"

#include <dwmapi.h>

namespace Ohagey
{
    namespace
    {
        // Yu Gothic UI is the Japanese UI face on Windows 10 and 11. DirectWrite
        // falls back on its own for anything it does not cover, which is the
        // other reason not to hand-position glyphs.
        const wchar_t* const kFontFamily = L"Yu Gothic UI";
        const float kFontSize = 16.0f;
        const float kLabelFontSize = 13.0f;

        // Breathing room around the text. The sample had none, which is most of
        // why it looked like a 2012 sample.
        const float kRowPaddingX = 10.0f;
        const float kRowPaddingY = 4.0f;
        const float kLabelColumnWidth = 22.0f;
        const float kSelectionCornerRadius = 4.0f;

        // Values from dwmapi.h that are only declared in newer SDKs. Defined
        // here so the build does not depend on which Windows SDK is installed;
        // the call fails harmlessly on systems that do not know them.
        const DWORD kDwmwaWindowCornerPreference = 33;
        const DWORD kDwmwaSystemBackdropType = 38;
        const DWORD kDwmwcpRound = 2;
        const DWORD kDwmsbtTransientWindow = 3;   // the "acrylic popup" backdrop

        template <typename T>
        void SafeRelease(T** object)
        {
            if (*object)
            {
                (*object)->Release();
                *object = nullptr;
            }
        }
    }

    CandidateRenderer::~CandidateRenderer()
    {
        Release();
    }

    bool CandidateRenderer::Initialize()
    {
        if (IsAvailable()) return true;

        // Single-threaded: every call comes from the window's own thread, and
        // the multi-threaded factory would add locking for nothing.
        HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &_d2dFactory);
        if (FAILED(hr))
        {
            Release();
            return false;
        }

        hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                 reinterpret_cast<IUnknown**>(&_dwriteFactory));
        if (FAILED(hr))
        {
            Release();
            return false;
        }

        if (!EnsureTextFormats())
        {
            Release();
            return false;
        }
        return true;
    }

    void CandidateRenderer::Release()
    {
        SafeRelease(&_labelFormat);
        SafeRelease(&_textFormat);
        SafeRelease(&_target);
        SafeRelease(&_dwriteFactory);
        SafeRelease(&_d2dFactory);
        _rowHeight = 0.0f;
    }

    bool CandidateRenderer::EnsureTextFormats()
    {
        if (_textFormat && _labelFormat) return true;

        HRESULT hr = _dwriteFactory->CreateTextFormat(
            kFontFamily, nullptr,
            DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
            kFontSize, L"ja-jp", &_textFormat);
        if (FAILED(hr)) return false;

        _textFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
        _textFormat->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        // One candidate per row; wrapping would silently change the row height
        // the window sized itself for.
        _textFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);

        hr = _dwriteFactory->CreateTextFormat(
            kFontFamily, nullptr,
            DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
            kLabelFontSize, L"ja-jp", &_labelFormat);
        if (FAILED(hr)) return false;

        _labelFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        _labelFormat->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        _labelFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);

        // Row height from the font's own metrics, so a user who has scaled
        // their text does not get clipped candidates.
        IDWriteTextLayout* probe = nullptr;
        hr = _dwriteFactory->CreateTextLayout(L"あ", 1, _textFormat, 1000.0f, 1000.0f, &probe);
        if (SUCCEEDED(hr) && probe)
        {
            DWRITE_TEXT_METRICS metrics = {};
            if (SUCCEEDED(probe->GetMetrics(&metrics)))
            {
                _rowHeight = metrics.height + kRowPaddingY * 2.0f;
            }
            probe->Release();
        }
        if (_rowHeight <= 0.0f)
        {
            _rowHeight = kFontSize + kRowPaddingY * 2.0f;
        }
        return true;
    }

    int CandidateRenderer::RowHeight() const
    {
        return static_cast<int>(_rowHeight + 0.5f);
    }

    int CandidateRenderer::LabelColumnWidth() const
    {
        return static_cast<int>(kLabelColumnWidth + 0.5f);
    }

    int CandidateRenderer::MeasureTextWidth(const std::wstring& text) const
    {
        if (!_dwriteFactory || !_textFormat || text.empty()) return 0;

        IDWriteTextLayout* layout = nullptr;
        const HRESULT hr = _dwriteFactory->CreateTextLayout(
            text.c_str(), static_cast<UINT32>(text.size()), _textFormat,
            4096.0f, 4096.0f, &layout);
        if (FAILED(hr) || !layout) return 0;

        DWRITE_TEXT_METRICS metrics = {};
        const HRESULT measured = layout->GetMetrics(&metrics);
        layout->Release();
        if (FAILED(measured)) return 0;

        return static_cast<int>(metrics.widthIncludingTrailingWhitespace + 0.5f);
    }

    bool CandidateRenderer::Draw(HDC dc, const RECT& bounds, const std::vector<CandidateRow>& rows)
    {
        if (!IsAvailable() || !dc) return false;

        if (!_target)
        {
            // Alpha mode IGNORE: this target draws onto a plain window DC,
            // which has no alpha channel to blend into. The Fluent translucency
            // comes from the DWM backdrop behind the window, not from here.
            const D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
                D2D1_RENDER_TARGET_TYPE_DEFAULT,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
                0.0f, 0.0f,
                D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE);

            if (FAILED(_d2dFactory->CreateDCRenderTarget(&properties, &_target)))
            {
                return false;
            }
        }

        if (FAILED(_target->BindDC(dc, &bounds)))
        {
            // The target can outlive the DC it was bound to; if rebinding
            // fails it is unusable, so drop it and let the next paint rebuild.
            SafeRelease(&_target);
            return false;
        }

        const CandidateTheme theme = CandidateTheme::FromSystem();

        _target->BeginDraw();
        _target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        _target->Clear(theme.background);

        const float width = static_cast<float>(bounds.right - bounds.left);
        float y = 0.0f;
        for (size_t i = 0; i < rows.size(); ++i)
        {
            const D2D1_RECT_F rowBounds = D2D1::RectF(0.0f, y, width, y + _rowHeight);
            DrawRow(_target, rows[i], rowBounds, theme);
            y += _rowHeight;
        }

        const HRESULT hr = _target->EndDraw();
        if (hr == D2DERR_RECREATE_TARGET)
        {
            // The device was lost (a display change, a driver reset). Dropping
            // the target is the documented recovery; the next paint rebuilds.
            SafeRelease(&_target);
            return false;
        }
        return SUCCEEDED(hr);
    }

    void CandidateRenderer::DrawRow(ID2D1RenderTarget* target, const CandidateRow& row,
                                    const D2D1_RECT_F& bounds, const CandidateTheme& theme)
    {
        ID2D1SolidColorBrush* brush = nullptr;
        if (FAILED(target->CreateSolidColorBrush(theme.text, &brush)) || !brush) return;

        if (row.selected)
        {
            brush->SetColor(theme.selectionBackground);
            // Inset and rounded: a full-bleed rectangle reads as a 1990s
            // list selection, and Fluent selection sits inside its row.
            const D2D1_ROUNDED_RECT selection = D2D1::RoundedRect(
                D2D1::RectF(bounds.left + 2.0f, bounds.top + 1.0f,
                            bounds.right - 2.0f, bounds.bottom - 1.0f),
                kSelectionCornerRadius, kSelectionCornerRadius);
            target->FillRoundedRectangle(selection, brush);
        }

        const D2D1_RECT_F labelBounds = D2D1::RectF(
            bounds.left, bounds.top, bounds.left + kLabelColumnWidth, bounds.bottom);
        brush->SetColor(row.selected ? theme.selectionText : theme.secondaryText);
        if (!row.label.empty())
        {
            target->DrawText(row.label.c_str(), static_cast<UINT32>(row.label.size()),
                             _labelFormat, labelBounds, brush,
                             D2D1_DRAW_TEXT_OPTIONS_CLIP);
        }

        const D2D1_RECT_F textBounds = D2D1::RectF(
            bounds.left + kLabelColumnWidth + kRowPaddingX * 0.5f, bounds.top,
            bounds.right - kRowPaddingX, bounds.bottom);
        brush->SetColor(row.selected ? theme.selectionText : theme.text);
        if (!row.text.empty())
        {
            target->DrawText(row.text.c_str(), static_cast<UINT32>(row.text.size()),
                             _textFormat, textBounds, brush,
                             D2D1_DRAW_TEXT_OPTIONS_CLIP);
        }

        brush->Release();
    }

    void ApplyFluentWindowStyle(HWND window)
    {
        if (!window) return;

        DWORD corner = kDwmwcpRound;
        DwmSetWindowAttribute(window, kDwmwaWindowCornerPreference, &corner, sizeof(corner));

        DWORD backdrop = kDwmsbtTransientWindow;
        DwmSetWindowAttribute(window, kDwmwaSystemBackdropType, &backdrop, sizeof(backdrop));
    }
}
