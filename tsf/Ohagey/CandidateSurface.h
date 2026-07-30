// DirectComposition surface for the candidate window (decision 0011).
//
// Step two of two. Step one drew Direct2D onto the window's HDC through an
// ID2D1DCRenderTarget, which works but goes through DWM's redirection bitmap:
// every frame is copied once more than it needs to be. Decision 0011 chose
// DirectComposition for latency, and this is that.
//
// What changes:
//   - the window is created WS_EX_NOREDIRECTIONBITMAP, so DWM allocates no
//     redirection surface for it at all;
//   - a composition swap chain is attached to a DComp visual, and the
//     compositor presents it directly;
//   - the surface has real per-pixel alpha, so the window can be translucent
//     without a layered window.
//
// What does not change: everything the renderer draws. It works against an
// ID2D1RenderTarget either way, which is why the drawing survived the move.
//
// ── Falling back ────────────────────────────────────────────────────────────
//
// If this cannot start — an ancient machine, a broken driver, a session with no
// usable adapter — the caller creates an ordinary window and keeps the HDC
// path. That decision has to be made *before* the window exists, because
// WS_EX_NOREDIRECTIONBITMAP makes GDI drawing impossible: a window created for
// DComp cannot fall back later.

#pragma once

#include <windows.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <vector>

namespace Ohagey
{
    class CandidateSurface
    {
    public:
        CandidateSurface() = default;
        ~CandidateSurface();

        CandidateSurface(const CandidateSurface&) = delete;
        CandidateSurface& operator=(const CandidateSurface&) = delete;

        /// Builds the device stack without a window.
        ///
        /// Separate from `Attach` so the caller can find out whether
        /// DirectComposition is usable *before* deciding how to create the
        /// window. Getting that order wrong means a window that can be drawn to
        /// by neither path.
        bool Initialize();
        bool IsAvailable() const { return _d2dContext != nullptr; }

        /// Binds to a window created with WS_EX_NOREDIRECTIONBITMAP.
        bool Attach(HWND window, UINT width, UINT height);

        void Release();

        /// Resizes the swap chain. Cheap to call with unchanged dimensions.
        bool Resize(UINT width, UINT height);

        /// Starts a frame. Returns the context to draw into, or null.
        ID2D1DeviceContext* Begin();

        /// Finishes the frame and puts it on screen.
        bool End();

        UINT Width() const { return _width; }
        UINT Height() const { return _height; }

        /// Asks for the next frame to be copied out as BGRA.
        ///
        /// For the preview harness: composed output never lands in a window DC,
        /// so reading the buffer the compositor was handed is the only way to
        /// see what this produced.
        ///
        /// It has to happen inside `End`, between EndDraw and Present. This is
        /// a flip-model swap chain: after Present, buffer 0 is a *different*
        /// buffer, and reading it afterwards returns whatever was there before
        /// — which looks exactly like a frame that failed to draw.
        ///
        /// Cleared once used, so a capture never applies to a later frame by
        /// accident.
        void CaptureNextFrame(std::vector<uint8_t>* into) { _capture = into; }

    private:
        bool CopyBackBuffer(std::vector<uint8_t>* bgra) const;
        bool CreateSwapChain(HWND window);
        bool BindBackBuffer();
        void ReleaseBackBuffer();

        ID3D11Device* _d3dDevice = nullptr;
        ID2D1Factory1* _d2dFactory = nullptr;
        ID2D1Device* _d2dDevice = nullptr;
        ID2D1DeviceContext* _d2dContext = nullptr;
        IDXGIFactory2* _dxgiFactory = nullptr;
        IDXGISwapChain1* _swapChain = nullptr;
        ID2D1Bitmap1* _backBuffer = nullptr;
        IDCompositionDevice* _dcompDevice = nullptr;
        IDCompositionTarget* _dcompTarget = nullptr;
        IDCompositionVisual* _dcompVisual = nullptr;

        UINT _width = 0;
        UINT _height = 0;
        bool _drawing = false;
        std::vector<uint8_t>* _capture = nullptr;
    };
}
