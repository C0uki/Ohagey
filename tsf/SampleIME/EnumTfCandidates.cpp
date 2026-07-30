// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#include "private.h"
#include "../Ohagey/OhageySeh.h"
#include "EnumTfCandidates.h"

HRESULT CEnumTfCandidates::CreateInstance(_Out_ CEnumTfCandidates **ppobj, _In_ const CSampleImeArray<ITfCandidateString*> &rgelm, UINT currentNum)
{
    if (ppobj == nullptr)
    {
        return E_INVALIDARG;
    }
    *ppobj = nullptr;

    *ppobj = new (std::nothrow) CEnumTfCandidates(rgelm, currentNum);
    if (*ppobj == nullptr) 
    {
        return E_OUTOFMEMORY;
    }

    return S_OK;
}

HRESULT CEnumTfCandidates::CreateInstance(REFIID riid, _Out_ void **ppvObj, _In_ const CSampleImeArray<ITfCandidateString*> &rgelm, UINT currentNum)
{
    if (ppvObj == nullptr)
    {
        return E_POINTER;
    }
    *ppvObj = nullptr;

    *ppvObj = new (std::nothrow) CEnumTfCandidates(rgelm, currentNum);
    if (*ppvObj == nullptr) 
    {
        return E_OUTOFMEMORY;
    }

    return ((CEnumTfCandidates*)(*ppvObj))->QueryInterface(riid, ppvObj);
}

CEnumTfCandidates::CEnumTfCandidates(_In_ const CSampleImeArray<ITfCandidateString*> &rgelm, UINT currentNum)
{
    _refCount = 0;
    _rgelm = rgelm;
    _currentCandidateStrIndex = currentNum;
}

CEnumTfCandidates::~CEnumTfCandidates()
{
}

//
// IUnknown methods
//
HRESULT CEnumTfCandidates::QueryInterfaceImpl(REFIID riid, _Outptr_ void **ppvObj)
{
    if (ppvObj == nullptr)
    {
        return E_POINTER;
    }
    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, __uuidof(IEnumTfCandidates)))
    {
        *ppvObj = (IEnumTfCandidates*)this;
    }

    if (*ppvObj == nullptr)
    {
        return E_NOINTERFACE;
    }

    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CEnumTfCandidates::AddRef()
{
    return (ULONG)InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) CEnumTfCandidates::Release()
{
    ULONG cRef = (ULONG)InterlockedDecrement(&_refCount);
    if (0 < cRef)
    {
        return cRef;
    }

    delete this;
    return 0;
}


//
// IEnumTfCandidates methods
//
HRESULT CEnumTfCandidates::NextImpl(ULONG ulCount, _Out_ ITfCandidateString **ppObj, _Out_ ULONG *pcFetched)
{
    ULONG fetched = 0;
    if (ppObj == nullptr)
    {
        return E_INVALIDARG;
    }
    *ppObj = nullptr;

    while ((fetched < ulCount) && (_currentCandidateStrIndex < _rgelm.Count()))
    {
        *ppObj = *_rgelm.GetAt(_currentCandidateStrIndex);
        _currentCandidateStrIndex++;
        fetched++;
    }

    if (pcFetched)
    {
        *pcFetched = fetched;
    }

    return (fetched == ulCount) ? S_OK : S_FALSE;
}

HRESULT CEnumTfCandidates::SkipImpl(ULONG ulCount)
{
    while ((0 < ulCount) && (_currentCandidateStrIndex < _rgelm.Count()))
    {
        _currentCandidateStrIndex++;
        ulCount--;
    }

    return (0 < ulCount) ? S_FALSE : S_OK;
}

HRESULT CEnumTfCandidates::ResetImpl()
{
    _currentCandidateStrIndex = 0;
    return S_OK;
}

HRESULT CEnumTfCandidates::CloneImpl(_Out_ IEnumTfCandidates **ppEnum)
{
    return CreateInstance(__uuidof(IEnumTfCandidates), (void**)ppEnum, _rgelm, _currentCandidateStrIndex);
}

//+---------------------------------------------------------------------------
//
//  [Ohagey] SEH guards (decision 0017).
//
//  One line each; the bodies above are the ...Impl functions they call. See
//  tsf/Ohagey/OhageySeh.h for why the split is necessary and what is not
//  guarded (IUnknown's AddRef and Release).
//
//----------------------------------------------------------------------------

OHAGEY_SEH_HRESULT_OUT(CEnumTfCandidates, QueryInterface, (REFIID riid, _Outptr_ void **ppvObj), (riid, ppvObj), ppvObj)

OHAGEY_SEH_HRESULT(CEnumTfCandidates, Next, (ULONG ulCount, _Out_ ITfCandidateString **ppObj, _Out_ ULONG *pcFetched), (ulCount, ppObj, pcFetched))

OHAGEY_SEH_HRESULT(CEnumTfCandidates, Skip, (ULONG ulCount), (ulCount))

OHAGEY_SEH_HRESULT(CEnumTfCandidates, Reset, (), ())

OHAGEY_SEH_HRESULT(CEnumTfCandidates, Clone, (_Out_ IEnumTfCandidates **ppEnum), (ppEnum))
