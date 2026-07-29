// Renders the candidate window to a bitmap so the drawing can be looked at.
//
// Registering a TSF text service needs administrator rights, so the only way to
// see what CandidateRenderer produces during development is to drive it
// directly. This draws a representative candidate list into a DIB and writes it
// out; build-and-run-preview.ps1 converts the result to PNG.
//
// It also prints the theme it read, because "the colours look wrong" and "the
// theme was read wrong" are different bugs.

#include "../CandidateRenderer.h"
#include "../CandidateTheme.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace Ohagey;

namespace
{
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

    bool WriteBmp(const wchar_t* path, HBITMAP bitmap, HDC dc, int width, int height)
    {
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        // Negative height would give a top-down DIB; BMP files on disk are
        // conventionally bottom-up, so let GetDIBits flip it for us.
        info.bmiHeader.biHeight = height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;

        const DWORD imageSize = static_cast<DWORD>(width) * height * 4;
        std::vector<BYTE> pixels(imageSize);
        if (!GetDIBits(dc, bitmap, 0, static_cast<UINT>(height), pixels.data(), &info, DIB_RGB_COLORS))
        {
            return false;
        }

        BITMAPFILEHEADER header = {};
        header.bfType = 0x4D42;   // "BM"
        header.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
        header.bfSize = header.bfOffBits + imageSize;

        FILE* file = nullptr;
        if (_wfopen_s(&file, path, L"wb") != 0 || !file) return false;
        fwrite(&header, sizeof(header), 1, file);
        fwrite(&info.bmiHeader, sizeof(info.bmiHeader), 1, file);
        fwrite(pixels.data(), 1, imageSize, file);
        fclose(file);
        return true;
    }
}

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);
    const wchar_t* outputPath = (argc > 1) ? argv[1] : L"candidate-preview.bmp";

    const CandidateTheme theme = CandidateTheme::FromSystem();
    printf("theme: %s\n", theme.darkMode ? "dark" : "light");
    printf("  accent      rgb(%.0f, %.0f, %.0f)\n",
           theme.selectionBackground.r * 255, theme.selectionBackground.g * 255,
           theme.selectionBackground.b * 255);
    printf("  selection text %s\n", theme.selectionText.r > 0.5f ? "white" : "black");

    CandidateRenderer renderer;
    if (!renderer.Initialize())
    {
        printf("FAILED: Direct2D/DirectWrite unavailable\n");
        return 1;
    }

    // A realistic page: what `へんかん` produces, with a longer entry to show
    // that the width is measured rather than assumed.
    const wchar_t* candidates[] = { L"変換", L"返還", L"変換した文章", L"へんかん", L"ヘンカン" };
    std::vector<CandidateRow> rows;
    for (int i = 0; i < 5; ++i)
    {
        CandidateRow row;
        row.label = std::to_wstring(i + 1);
        row.text = candidates[i];
        row.selected = (i == 1);
        rows.push_back(row);
    }

    // Width from the widest candidate, so nothing is clipped — the metric the
    // GDI path got wrong by assuming every glyph was tmAveCharWidth across.
    int textWidth = 0;
    for (size_t i = 0; i < rows.size(); ++i)
    {
        const int width = renderer.MeasureTextWidth(rows[i].text);
        if (width > textWidth) textWidth = width;
    }
    const int width = renderer.LabelColumnWidth() + textWidth + 28;
    const int height = renderer.RowHeight() * static_cast<int>(rows.size());
    printf("row height %d px, measured width %d px -> %dx%d\n",
           renderer.RowHeight(), textWidth, width, height);

    HDC screen = GetDC(nullptr);
    HDC memory = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
    HGDIOBJ previous = SelectObject(memory, bitmap);

    RECT bounds = { 0, 0, width, height };
    const bool drawn = renderer.Draw(memory, bounds, rows);
    printf("draw: %s\n", drawn ? "ok" : "FAILED");

    bool written = false;
    if (drawn)
    {
        SelectObject(memory, previous);
        written = WriteBmp(outputPath, bitmap, memory, width, height);
        printf("wrote %s: %s\n", Utf8(outputPath).c_str(), written ? "ok" : "FAILED");
    }
    else
    {
        SelectObject(memory, previous);
    }

    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return (drawn && written) ? 0 : 1;
}
