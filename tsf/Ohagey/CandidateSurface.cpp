// See CandidateSurface.h.

#include "CandidateSurface.h"

namespace Ohagey
{
    namespace
    {
        template <typename T>
        void SafeRelease(T** object)
        {
            if (*object)
            {
                (*object)->Release();
                *object = nullptr;
            }
        }

        // A swap chain needs a non-zero size even before the window has one.
        UINT AtLeastOne(UINT value) { return value == 0 ? 1u : value; }
    }

    CandidateSurface::~CandidateSurface()
    {
        Release();
    }

    bool CandidateSurface::Initialize()
    {
        if (IsAvailable()) return true;

        // BGRA support is required to put Direct2D on top of this device.
        // Hardware first, then WARP: a session with no usable adapter (some
        // remote desktop configurations) still gets a candidate window, just
        // rendered on the CPU.
        const D3D_DRIVER_TYPE driverTypes[] = { D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP };
        HRESULT hr = E_FAIL;
        for (size_t i = 0; i < ARRAYSIZE(driverTypes) && FAILED(hr); ++i)
        {
            hr = D3D11CreateDevice(nullptr, driverTypes[i], nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION,
                                   &_d3dDevice, nullptr, nullptr);
        }
        if (FAILED(hr)) { Release(); return false; }

        IDXGIDevice* dxgiDevice = nullptr;
        if (FAILED(_d3dDevice->QueryInterface(__uuidof(IDXGIDevice),
                                              reinterpret_cast<void**>(&dxgiDevice))))
        {
            Release();
            return false;
        }

        // Own factory rather than the renderer's: that one is an ID2D1Factory,
        // and creating a device off a DXGI device needs ID2D1Factory1.
        const D2D1_FACTORY_OPTIONS options = {};
        hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                               __uuidof(ID2D1Factory1), &options,
                               reinterpret_cast<void**>(&_d2dFactory));
        if (SUCCEEDED(hr)) hr = _d2dFactory->CreateDevice(dxgiDevice, &_d2dDevice);
        if (SUCCEEDED(hr))
        {
            hr = _d2dDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &_d2dContext);
        }

        IDXGIAdapter* adapter = nullptr;
        if (SUCCEEDED(hr)) hr = dxgiDevice->GetAdapter(&adapter);
        if (SUCCEEDED(hr))
        {
            hr = adapter->GetParent(__uuidof(IDXGIFactory2),
                                    reinterpret_cast<void**>(&_dxgiFactory));
        }
        SafeRelease(&adapter);

        if (SUCCEEDED(hr))
        {
            hr = DCompositionCreateDevice(dxgiDevice, __uuidof(IDCompositionDevice),
                                          reinterpret_cast<void**>(&_dcompDevice));
        }
        SafeRelease(&dxgiDevice);

        if (FAILED(hr)) { Release(); return false; }
        return true;
    }

    bool CandidateSurface::CreateSwapChain(HWND window)
    {
        window;

        DXGI_SWAP_CHAIN_DESC1 description = {};
        description.Width = AtLeastOne(_width);
        description.Height = AtLeastOne(_height);
        description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        description.SampleDesc.Count = 1;
        description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        // Two buffers with FLIP_SEQUENTIAL: the minimum a composition swap
        // chain accepts, and there is nothing to gain from more for a window
        // that repaints on a keystroke.
        description.BufferCount = 2;
        description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        // Premultiplied alpha is what the compositor expects; without it the
        // translucent background comes out wrong wherever it overlaps content.
        description.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;

        return SUCCEEDED(_dxgiFactory->CreateSwapChainForComposition(
            _d3dDevice, &description, nullptr, &_swapChain));
    }

    bool CandidateSurface::Attach(HWND window, UINT width, UINT height)
    {
        if (!IsAvailable() || !window) return false;

        _width = AtLeastOne(width);
        _height = AtLeastOne(height);

        if (!_swapChain && !CreateSwapChain(window)) return false;

        // TRUE for topmost: the candidate window sits above its owner.
        if (FAILED(_dcompDevice->CreateTargetForHwnd(window, TRUE, &_dcompTarget))) return false;
        if (FAILED(_dcompDevice->CreateVisual(&_dcompVisual))) return false;
        if (FAILED(_dcompVisual->SetContent(_swapChain))) return false;
        if (FAILED(_dcompTarget->SetRoot(_dcompVisual))) return false;
        return SUCCEEDED(_dcompDevice->Commit());
    }

    bool CandidateSurface::Resize(UINT width, UINT height)
    {
        width = AtLeastOne(width);
        height = AtLeastOne(height);
        if (width == _width && height == _height) return true;
        if (!_swapChain) { _width = width; _height = height; return true; }

        // The back buffer holds a reference to the buffer being resized; the
        // resize fails while it is alive.
        ReleaseBackBuffer();

        if (FAILED(_swapChain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0)))
        {
            return false;
        }
        _width = width;
        _height = height;
        return true;
    }

    bool CandidateSurface::BindBackBuffer()
    {
        if (_backBuffer) return true;

        IDXGISurface* surface = nullptr;
        if (FAILED(_swapChain->GetBuffer(0, __uuidof(IDXGISurface),
                                         reinterpret_cast<void**>(&surface))))
        {
            return false;
        }

        const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));

        const HRESULT hr = _d2dContext->CreateBitmapFromDxgiSurface(surface, &properties, &_backBuffer);
        SafeRelease(&surface);
        return SUCCEEDED(hr);
    }

    void CandidateSurface::ReleaseBackBuffer()
    {
        if (_d2dContext) _d2dContext->SetTarget(nullptr);
        SafeRelease(&_backBuffer);
    }

    ID2D1DeviceContext* CandidateSurface::Begin()
    {
        if (!IsAvailable() || !_swapChain || _drawing) return nullptr;
        if (!BindBackBuffer()) return nullptr;

        _d2dContext->SetTarget(_backBuffer);
        _d2dContext->BeginDraw();
        _drawing = true;
        return _d2dContext;
    }

    bool CandidateSurface::End()
    {
        if (!_drawing) return false;
        _drawing = false;

        const HRESULT drawn = _d2dContext->EndDraw();

        // Before Present, while buffer 0 is still the one just drawn.
        if (_capture)
        {
            if (SUCCEEDED(drawn)) CopyBackBuffer(_capture);
            _capture = nullptr;
        }
        if (FAILED(drawn))
        {
            // A lost device (display change, driver reset) invalidates
            // everything here. Tearing the stack down lets the next paint
            // rebuild it; keeping it would fail forever.
            Release();
            return false;
        }

        // Present(0): no vsync wait. The candidate window follows typing, and
        // blocking a keystroke for up to a frame to avoid tearing on a popup
        // that rarely moves is the wrong trade.
        if (FAILED(_swapChain->Present(0, 0))) return false;
        return SUCCEEDED(_dcompDevice->Commit());
    }

    bool CandidateSurface::CopyBackBuffer(std::vector<uint8_t>* bgra) const
    {
        if (!_swapChain || !_d3dDevice) return false;

        ID3D11Texture2D* back = nullptr;
        if (FAILED(_swapChain->GetBuffer(0, __uuidof(ID3D11Texture2D),
                                         reinterpret_cast<void**>(&back))))
        {
            return false;
        }

        D3D11_TEXTURE2D_DESC description = {};
        back->GetDesc(&description);
        description.Usage = D3D11_USAGE_STAGING;
        description.BindFlags = 0;
        description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        description.MiscFlags = 0;

        ID3D11Texture2D* staging = nullptr;
        HRESULT hr = _d3dDevice->CreateTexture2D(&description, nullptr, &staging);

        ID3D11DeviceContext* context = nullptr;
        if (SUCCEEDED(hr)) _d3dDevice->GetImmediateContext(&context);

        if (SUCCEEDED(hr) && context)
        {
            context->CopyResource(staging, back);

            D3D11_MAPPED_SUBRESOURCE mapped = {};
            hr = context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(hr))
            {
                bgra->resize(static_cast<size_t>(_width) * _height * 4);
                const uint8_t* source = static_cast<const uint8_t*>(mapped.pData);
                for (UINT y = 0; y < _height; ++y)
                {
                    memcpy(bgra->data() + static_cast<size_t>(y) * _width * 4,
                           source + static_cast<size_t>(y) * mapped.RowPitch,
                           static_cast<size_t>(_width) * 4);
                }
                context->Unmap(staging, 0);
            }
        }

        SafeRelease(&context);
        SafeRelease(&staging);
        SafeRelease(&back);
        return SUCCEEDED(hr);
    }

    void CandidateSurface::Release()
    {
        ReleaseBackBuffer();
        SafeRelease(&_dcompVisual);
        SafeRelease(&_dcompTarget);
        SafeRelease(&_dcompDevice);
        SafeRelease(&_swapChain);
        SafeRelease(&_dxgiFactory);
        SafeRelease(&_d2dContext);
        SafeRelease(&_d2dDevice);
        SafeRelease(&_d2dFactory);
        SafeRelease(&_d3dDevice);
        _width = 0;
        _height = 0;
        _drawing = false;
        _capture = nullptr;
    }
}
