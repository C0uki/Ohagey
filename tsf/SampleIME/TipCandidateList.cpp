// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#include "private.h"
#include "../Ohagey/OhageySeh.h"
#include "TipCandidateList.h"
#include "EnumTfCandidates.h"
#include "TipCandidateString.h"

HRESULT CTipCandidateList::CreateInstance(_Outptr_ ITfCandidateList **ppobj, size_t candStrReserveSize)
{  
    if (ppobj == nullptr)
    {
        return E_INVALIDARG;
    }
    *ppobj = nullptr;

    *ppobj = new (std::nothrow) CTipCandidateList(candStrReserveSize);
    if (*ppobj == nullptr) 
    {
        return E_OUTOFMEMORY;
    }

    return S_OK;
}

HRESULT CTipCandidateList::CreateInstance(REFIID riid, _Outptr_ void **ppvObj, size_t candStrReserveSize)
{  
    if (ppvObj == nullptr)
    {
        return E_INVALIDARG;
    }
    *ppvObj = nullptr;

    *ppvObj = new (std::nothrow) CTipCandidateList(candStrReserveSize);
    if (*ppvObj == nullptr) 
    {
        return E_OUTOFMEMORY;
    }

    return ((CTipCandidateList*)(*ppvObj))->QueryInterface(riid, ppvObj);
}

CTipCandidateList::CTipCandidateList(size_t candStrReserveSize)
{
    _refCount = 0;

    if (0 < candStrReserveSize)
    {
        _tfCandStrList.reserve(candStrReserveSize);
    }
}

CTipCandidateList::~CTipCandidateList()
{
}

HRESULT CTipCandidateList::QueryInterfaceImpl(REFIID riid, _Outptr_ void **ppvObj)
{
    if (ppvObj == nullptr)
    {
        return E_POINTER;
    }
    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown))
    {
        *ppvObj = (ITfCandidateList*)this;
    }
    else if (IsEqualIID(riid, IID_ITfCandidateList))
    {
        *ppvObj = (ITfCandidateList*)this;
    }

    if (*ppvObj == nullptr)
    {
        return E_NOINTERFACE;
    }

    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CTipCandidateList::AddRef()
{
    return (ULONG)InterlockedIncrement((LONG*)&_refCount);
}

STDMETHODIMP_(ULONG) CTipCandidateList::Release()
{
    ULONG  cRefT  = (ULONG)InterlockedDecrement((LONG*)&_refCount);
    if (0 < cRefT)
    {
        return cRefT;
    }

    delete this;

    return 0;
}

HRESULT CTipCandidateList::EnumCandidatesImpl(_Outptr_ IEnumTfCandidates **ppEnum)
{
    return CEnumTfCandidates::CreateInstance(IID_IEnumTfCandidates, (void**)ppEnum, _tfCandStrList);
}

HRESULT CTipCandidateList::GetCandidateImpl(ULONG nIndex, _Outptr_result_maybenull_ ITfCandidateString **ppCandStr)
{
    if (ppCandStr == nullptr)
    {
        return E_POINTER;
    }
    *ppCandStr = nullptr;

    ULONG sizeCandStr = (ULONG)_tfCandStrList.Count();
    if (sizeCandStr <= nIndex)
    {
        return E_FAIL;
    }

    for (UINT i = 0; i < _tfCandStrList.Count(); i++)
    {
        ITfCandidateString** ppCandStrCur = _tfCandStrList.GetAt(i);
        ULONG indexCur = 0;
        if ((nullptr != ppCandStrCur) && (SUCCEEDED((*ppCandStrCur)->GetIndex(&indexCur))))
        {
            if (nIndex == indexCur)
            {
                BSTR bstr;
                CTipCandidateString* pTipCandidateStrCur = (CTipCandidateString*)(*ppCandStrCur);
                pTipCandidateStrCur->GetString(&bstr);

                CTipCandidateString::CreateInstance(IID_ITfCandidateString, (void**)ppCandStr);

                if (nullptr != (*ppCandStr))
                {
                    CTipCandidateString* pTipCandidateStr = (CTipCandidateString*)(*ppCandStr);
                    pTipCandidateStr->SetString((LPCWSTR)bstr, SysStringLen(bstr));
                }

                SysFreeString(bstr);

                break;
            }
        }
    }
    return S_OK;
}

HRESULT CTipCandidateList::GetCandidateNumImpl(_Out_ ULONG *pnCnt)
{
    if (pnCnt == nullptr)
    {
        return E_POINTER;
    }

    *pnCnt = (ULONG)(_tfCandStrList.Count());
    return S_OK;
}

HRESULT CTipCandidateList::SetResultImpl(ULONG nIndex, TfCandidateResult imcr)
{
    nIndex;imcr;

    return E_NOTIMPL;
}

HRESULT CTipCandidateList::SetCandidateImpl(_In_ ITfCandidateString **ppCandStr)
{
    if (ppCandStr == nullptr)
    {
        return E_POINTER;
    }

    ITfCandidateString** ppCandLast = _tfCandStrList.Append();
    if (ppCandLast)
    {
        *ppCandLast = *ppCandStr;
    }

    return S_OK;
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

OHAGEY_SEH_HRESULT_OUT(CTipCandidateList, QueryInterface, (REFIID riid, _Outptr_ void **ppvObj), (riid, ppvObj), ppvObj)

OHAGEY_SEH_HRESULT_OUT(CTipCandidateList, EnumCandidates, (_Outptr_ IEnumTfCandidates **ppEnum), (ppEnum), ppEnum)

OHAGEY_SEH_HRESULT_OUT(CTipCandidateList, GetCandidate, (ULONG nIndex, _Outptr_result_maybenull_ ITfCandidateString **ppCandStr), (nIndex, ppCandStr), ppCandStr)

OHAGEY_SEH_HRESULT(CTipCandidateList, GetCandidateNum, (_Out_ ULONG *pnCnt), (pnCnt))

OHAGEY_SEH_HRESULT(CTipCandidateList, SetResult, (ULONG nIndex, TfCandidateResult imcr), (nIndex, imcr))

OHAGEY_SEH_HRESULT(CTipCandidateList, SetCandidate, (_In_ ITfCandidateString **ppCandStr), (ppCandStr))
