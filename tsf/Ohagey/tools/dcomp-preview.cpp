// Renders the candidate window through the real DirectComposition path and
// reads the result back (decision 0011).
//
// The composed output never lands in any window's DC, so the HDC-based preview
// cannot see it. This creates an actual WS_EX_NOREDIRECTIONBITMAP window,
// attaches a composition swap chain, draws, and reads the buffer the compositor
// was handed. If the stack is wrong the picture comes out wrong — which is the
// only way to find out short of registering the text service.
//
// Build and run: tsf/Ohagey/tools/build-and-run-dcomp.ps1

#include "../CandidateRenderer.h"
#include "../CandidateSurface.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace Ohagey;

namespace
{
    int g_failures = 0;

    void Check(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }

    LRESULT CALLBACK WindowProc(HWND h, UINT m, WPARAM w, LPARAM l)
    {
        return DefWindowProcW(h, m, w, l);
    }

    HWND CreateCompositionWindow(int width, int height)
    {
        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = WindowProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"OhageyDCompPreview";
        RegisterClassExW(&wc);

        // The same flags the candidate window uses when composition is on.
        return CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP,
            wc.lpszClassName, nullptr, WS_POPUP,
            0, 0, width, height, nullptr, nullptr, wc.hInstance, nullptr);
    }

    bool WriteBmp(const wchar_t* path, const std::vector<uint8_t>& bgra, int width, int height)
    {
        BITMAPINFOHEADER info = {};
        info.biSize = sizeof(info);
        info.biWidth = width;
        // Negative: the surface is top-down, BMP files are bottom-up.
        info.biHeight = -height;
        info.biPlanes = 1;
        info.biBitCount = 32;
        info.biCompression = BI_RGB;

        BITMAPFILEHEADER header = {};
        header.bfType = 0x4D42;
        header.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
        header.bfSize = header.bfOffBits + static_cast<DWORD>(bgra.size());

        FILE* file = nullptr;
        if (_wfopen_s(&file, path, L"wb") != 0 || !file) return false;
        fwrite(&header, sizeof(header), 1, file);
        fwrite(&info, sizeof(info), 1, file);
        fwrite(bgra.data(), 1, bgra.size(), file);
        fclose(file);
        return true;
    }
}

int wmain(int argc, wchar_t** argv)
{
    SetConsoleOutputCP(CP_UTF8);
    const wchar_t* outputPath = (argc > 1) ? argv[1] : L"dcomp-preview.bmp";

    CandidateRenderer renderer;
    Check(renderer.Initialize(), "DirectWrite started");

    CandidateSurface surface;
    Check(surface.Initialize(), "the D3D11 / D2D / DirectComposition stack started");
    if (!surface.IsAvailable())
    {
        printf("\ncannot continue without a composition device\n");
        return 1;
    }

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

    int textWidth = 0;
    for (size_t i = 0; i < rows.size(); ++i)
    {
        const int w = renderer.MeasureTextWidth(rows[i].text);
        if (w > textWidth) textWidth = w;
    }
    const int width = renderer.LabelColumnWidth() + textWidth + 28;
    const int height = renderer.RowHeight() * static_cast<int>(rows.size());

    HWND window = CreateCompositionWindow(width, height);
    Check(window != nullptr, "created a WS_EX_NOREDIRECTIONBITMAP window");
    if (!window) return 1;

    Check(surface.Attach(window, static_cast<UINT>(width), static_cast<UINT>(height)),
          "attached a composition swap chain to it");

    // Asked for before drawing: the copy has to happen inside the draw, after
    // EndDraw and before Present. See CandidateSurface::CaptureNextFrame.
    std::vector<uint8_t> pixels;
    surface.CaptureNextFrame(&pixels);

    Check(renderer.Draw(surface, rows), "drew and presented a frame");
    Check(!pixels.empty(), "captured the composed frame");
    Check(pixels.size() == static_cast<size_t>(width) * height * 4, "the frame is the expected size");

    // A frame of nothing but zeroes means the draw did not reach the surface,
    // which would otherwise look exactly like success.
    bool anyInk = false;
    for (size_t i = 0; i < pixels.size() && !anyInk; ++i)
    {
        if (pixels[i] != 0) anyInk = true;
    }
    Check(anyInk, "the frame is not blank");

    if (anyInk)
    {
        Check(WriteBmp(outputPath, pixels, width, height), "wrote the frame out");
    }

    printf("  %dx%d\n", width, height);
    DestroyWindow(window);

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
