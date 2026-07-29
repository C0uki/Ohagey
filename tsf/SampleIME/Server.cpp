// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#include "Private.h"
#include "Globals.h"
#include "../Ohagey/OhageySeh.h"
#include "SampleIME.h"

// from Register.cpp
BOOL RegisterProfiles();
void UnregisterProfiles();
BOOL RegisterCategories();
void UnregisterCategories();
BOOL RegisterServer();
void UnregisterServer();

void FreeGlobalObjects(void);

class CClassFactory;
static CClassFactory* classFactoryObjects[1] = { nullptr };

//+---------------------------------------------------------------------------
//
//  DllAddRef
//
//----------------------------------------------------------------------------

void DllAddRef(void)
{
    InterlockedIncrement(&Global::dllRefCount);
}

//+---------------------------------------------------------------------------
//
//  DllRelease
//
//----------------------------------------------------------------------------

void DllRelease(void)
{
    if (InterlockedDecrement(&Global::dllRefCount) < 0)
    {
        EnterCriticalSection(&Global::CS);

        if (nullptr != classFactoryObjects[0])
        {
            FreeGlobalObjects();
        }
        assert(Global::dllRefCount == -1);

        LeaveCriticalSection(&Global::CS);
    }
}

//+---------------------------------------------------------------------------
//
//  CClassFactory declaration with IClassFactory Interface
//
//----------------------------------------------------------------------------

class CClassFactory : public IClassFactory
{
public:
    // IUnknown methods
    STDMETHODIMP QueryInterface(REFIID riid, _Outptr_ void **ppvObj);
    STDMETHODIMP_(ULONG) AddRef(void);
    STDMETHODIMP_(ULONG) Release(void);

    // IClassFactory methods
    STDMETHODIMP CreateInstance(_In_opt_ IUnknown *pUnkOuter, _In_ REFIID riid, _COM_Outptr_ void **ppvObj);
    STDMETHODIMP LockServer(BOOL fLock);

    // Constructor
    CClassFactory(REFCLSID rclsid, HRESULT (*pfnCreateInstance)(IUnknown *pUnkOuter, REFIID riid, void **ppvObj))
        : _rclsid(rclsid)
    {
        _pfnCreateInstance = pfnCreateInstance;
    }

public:
    REFCLSID _rclsid;
    HRESULT (*_pfnCreateInstance)(IUnknown *pUnkOuter, REFIID riid, _COM_Outptr_ void **ppvObj);
private:
	CClassFactory& operator=(const CClassFactory& rhn) {rhn;};
};

//+---------------------------------------------------------------------------
//
//  CClassFactory::QueryInterface
//
//----------------------------------------------------------------------------

STDAPI CClassFactory::QueryInterface(REFIID riid, _Outptr_ void **ppvObj)
{
    if (IsEqualIID(riid, IID_IClassFactory) || IsEqualIID(riid, IID_IUnknown))
    {
        *ppvObj = this;
        DllAddRef();
        return NOERROR;
    }
    *ppvObj = nullptr;

    return E_NOINTERFACE;
}

//+---------------------------------------------------------------------------
//
//  CClassFactory::AddRef
//
//----------------------------------------------------------------------------

STDAPI_(ULONG) CClassFactory::AddRef()
{
    DllAddRef();
    return (Global::dllRefCount + 1);
}

//+---------------------------------------------------------------------------
//
//  CClassFactory::Release
//
//----------------------------------------------------------------------------

STDAPI_(ULONG) CClassFactory::Release()
{
    DllRelease();
    return (Global::dllRefCount + 1);
}

//+---------------------------------------------------------------------------
//
//  CClassFactory::CreateInstance
//
//----------------------------------------------------------------------------

STDAPI CClassFactory::CreateInstance(_In_opt_ IUnknown *pUnkOuter, _In_ REFIID riid, _COM_Outptr_ void **ppvObj)
{
    return _pfnCreateInstance(pUnkOuter, riid, ppvObj);
}

//+---------------------------------------------------------------------------
//
//  CClassFactory::LockServer
//
//----------------------------------------------------------------------------

STDAPI CClassFactory::LockServer(BOOL fLock)
{
    if (fLock)
    {
        DllAddRef();
    }
    else
    {
        DllRelease();
    }

    return S_OK;
}

//+---------------------------------------------------------------------------
//
//  BuildGlobalObjects
//
//----------------------------------------------------------------------------

void BuildGlobalObjects(void)
{
    classFactoryObjects[0] = new (std::nothrow) CClassFactory(Global::SampleIMECLSID, CSampleIME::CreateInstance);
}

//+---------------------------------------------------------------------------
//
//  FreeGlobalObjects
//
//----------------------------------------------------------------------------

void FreeGlobalObjects(void)
{
    for (int i = 0; i < ARRAYSIZE(classFactoryObjects); i++)
    {
        if (nullptr != classFactoryObjects[i])
        {
            delete classFactoryObjects[i];
            classFactoryObjects[i] = nullptr;
        }
    }

    DeleteObject(Global::defaultlFontHandle);
}

//+---------------------------------------------------------------------------
//
//  DllGetClassObject
//
//----------------------------------------------------------------------------
_Check_return_
static HRESULT DllGetClassObjectImpl(
	_In_ REFCLSID rclsid, 
	_In_ REFIID riid, 
	_Outptr_ void** ppv)
{
    if (classFactoryObjects[0] == nullptr)
    {
        EnterCriticalSection(&Global::CS);

        // need to check ref again after grabbing mutex
        if (classFactoryObjects[0] == nullptr)
        {
            BuildGlobalObjects();
        }

        LeaveCriticalSection(&Global::CS);
    }

    if (IsEqualIID(riid, IID_IClassFactory) ||
        IsEqualIID(riid, IID_IUnknown))
    {
        for (int i = 0; i < ARRAYSIZE(classFactoryObjects); i++)
        {
            if (nullptr != classFactoryObjects[i] &&
                IsEqualGUID(rclsid, classFactoryObjects[i]->_rclsid))
            {
                *ppv = (void *)classFactoryObjects[i];
                DllAddRef();    // class factory holds DLL ref count
                return NOERROR;
            }
        }
    }

    *ppv = nullptr;

    return CLASS_E_CLASSNOTAVAILABLE;
}

//+---------------------------------------------------------------------------
//
//  DllCanUnloadNow
//
//----------------------------------------------------------------------------

static HRESULT DllCanUnloadNowImpl(void)
{
    if (Global::dllRefCount >= 0)
    {
        return S_FALSE;
    }

    return S_OK;
}

//+---------------------------------------------------------------------------
//
//  DllUnregisterServer
//
//----------------------------------------------------------------------------

static HRESULT DllUnregisterServerImpl(void)
{
    UnregisterProfiles();
    UnregisterCategories();
    UnregisterServer();

    return S_OK;
}

//+---------------------------------------------------------------------------
//
//  DllRegisterServer
//
//----------------------------------------------------------------------------

static HRESULT DllRegisterServerImpl(void)
{
    if ((!RegisterServer()) || (!RegisterProfiles()) || (!RegisterCategories()))
    {
        DllUnregisterServerImpl();
        return E_FAIL;
    }
    return S_OK;
}

//+---------------------------------------------------------------------------
//
//  [Ohagey] SEH guards for the exported entry points (decision 0017).
//
//  These are called by the loader and by COM. A fault escaping one of them
//  lands in the host application with nobody left to handle it, so each is a
//  thin wrapper around the real body; __try cannot share a function with C++
//  object unwinding, and none of these wrappers declares anything with a
//  destructor.
//
//----------------------------------------------------------------------------

STDAPI DllGetClassObject(_In_ REFCLSID rclsid, _In_ REFIID riid, _Outptr_ void** ppv)
{
    __try
    {
        return DllGetClassObjectImpl(rclsid, riid, ppv);
    }
    __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
    {
        // The caller keeps ppv; leave it null rather than whatever the fault
        // left behind, or COM will release a pointer that was never valid.
        if (ppv) *ppv = nullptr;
        return E_UNEXPECTED;
    }
}

STDAPI DllCanUnloadNow(void)
{
    __try
    {
        return DllCanUnloadNowImpl();
    }
    __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
    {
        // S_FALSE means "keep me loaded". After a fault we cannot say whether
        // anything still points into this DLL, and unloading it then would turn
        // a contained fault into the host jumping into freed pages.
        return S_FALSE;
    }
}

STDAPI DllUnregisterServer(void)
{
    __try
    {
        return DllUnregisterServerImpl();
    }
    __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
    {
        return E_UNEXPECTED;
    }
}

STDAPI DllRegisterServer(void)
{
    __try
    {
        return DllRegisterServerImpl();
    }
    __except (Ohagey::SehFilter(GetExceptionCode(), GetExceptionInformation()))
    {
        return E_UNEXPECTED;
    }
}
