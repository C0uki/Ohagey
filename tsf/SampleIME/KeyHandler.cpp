// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#include "Private.h"
#include "Globals.h"
#include "EditSession.h"
#include "SampleIME.h"
#include "CandidateListUIPresenter.h"
#include "CompositionProcessorEngine.h"
#include "../Ohagey/OhageyLog.h"

//////////////////////////////////////////////////////////////////////
//
// CSampleIME class
//
//////////////////////////////////////////////////////////////////////

//+---------------------------------------------------------------------------
//
// _IsRangeCovered
//
// Returns TRUE if pRangeTest is entirely contained within pRangeCover.
//
//----------------------------------------------------------------------------

BOOL CSampleIME::_IsRangeCovered(TfEditCookie ec, _In_ ITfRange *pRangeTest, _In_ ITfRange *pRangeCover)
{
    LONG lResult = 0;;

    if (FAILED(pRangeCover->CompareStart(ec, pRangeTest, TF_ANCHOR_START, &lResult)) 
        || (lResult > 0))
    {
        return FALSE;
    }

    if (FAILED(pRangeCover->CompareEnd(ec, pRangeTest, TF_ANCHOR_END, &lResult)) 
        || (lResult < 0))
    {
        return FALSE;
    }

    return TRUE;
}

//+---------------------------------------------------------------------------
//
// _DeleteCandidateList
//
//----------------------------------------------------------------------------

VOID CSampleIME::_DeleteCandidateList(BOOL isForce, _In_opt_ ITfContext *pContext)
{
    isForce;pContext;

    CCompositionProcessorEngine* pCompositionProcessorEngine = nullptr;
    pCompositionProcessorEngine = _pCompositionProcessorEngine;
    pCompositionProcessorEngine->PurgeVirtualKey();

    if (_pCandidateListUIPresenter)
    {
        _pCandidateListUIPresenter->_EndCandidateList();

        _candidateMode = CANDIDATE_NONE;
        _isCandidateWithWildcard = FALSE;
    }
}

//+---------------------------------------------------------------------------
//
// _HandleComplete
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleComplete(TfEditCookie ec, _In_ ITfContext *pContext)
{
    _DeleteCandidateList(FALSE, pContext);

    // just terminate the composition
    _TerminateComposition(ec, pContext);

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCancel
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCancel(TfEditCookie ec, _In_ ITfContext *pContext)
{
    _RemoveDummyCompositionForComposing(ec, _pComposition);

    _DeleteCandidateList(FALSE, pContext);

    _TerminateComposition(ec, pContext);

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionInput
//
// If the keystroke happens within a composition, eat the key and return S_OK.
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionInput(TfEditCookie ec, _In_ ITfContext *pContext, WCHAR wch)
{
    ITfRange* pRangeComposition = nullptr;
    TF_SELECTION tfSelection;
    ULONG fetched = 0;
    BOOL isCovered = TRUE;

    CCompositionProcessorEngine* pCompositionProcessorEngine = nullptr;
    pCompositionProcessorEngine = _pCompositionProcessorEngine;

    // [Ohagey] "A candidate window is up" is `_candidateMode`, not the pointer.
    //
    // This asks: is the user typing a character while a candidate list is
    // showing? If so, settle what is there before starting the new one.
    //
    // The pointer cannot answer that. `_DeleteCandidateList` — which runs on
    // every teardown path, including after a commit — calls
    // `_EndCandidateList` and sets `_candidateMode = CANDIDATE_NONE`, but
    // leaves `_pCandidateListUIPresenter` non-null. So once the user has
    // converted **once**, this condition is true for every keystroke
    // afterwards, and each one runs `_HandleCompositionFinalize`: the second
    // character of the next word ends the composition, commits the first
    // character on its own, and `_HandleCancel` purges the reading buffer.
    // The reading can never grow past one character again, so conversion
    // never happens a second time.
    //
    // That is the reported "変換が一回限り", and it is not new: the sample
    // masked it by setting CANDIDATE_INCREMENTAL from the per-keystroke
    // candidate fetch, which happened to make this condition false whenever
    // the engine returned anything. Removing that fetch (see
    // `_HandleCompositionInputWorker`) removed the mask, not the bug.
    //
    // Left as a mode test rather than fixed by deleting the presenter in
    // `_DeleteCandidateList`: that runs from profile deactivation and from
    // composition teardown, the object is reference counted and TSF may hold
    // it, and this DLL lives inside the user's applications (decision 0017).
    if ((_pCandidateListUIPresenter != nullptr)
        && (_candidateMode != CANDIDATE_INCREMENTAL)
        && (_candidateMode != CANDIDATE_NONE))
    {
        _HandleCompositionFinalize(ec, pContext, FALSE);
    }

    // Start the new (std::nothrow) compositon if there is no composition.
    if (!_IsComposing())
    {
        _StartComposition(pContext);
    }

    // first, test where a keystroke would go in the document if we did an insert
    if (pContext->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &tfSelection, &fetched) != S_OK || fetched != 1)
    {
        return S_FALSE;
    }

    // is the insertion point covered by a composition?
    if (SUCCEEDED(_pComposition->GetRange(&pRangeComposition)))
    {
        isCovered = _IsRangeCovered(ec, tfSelection.range, pRangeComposition);

        pRangeComposition->Release();

        if (!isCovered)
        {
            goto Exit;
        }
    }

    // Add virtual key to composition processor engine
    pCompositionProcessorEngine->AddVirtualKey(wch);

    _HandleCompositionInputWorker(pCompositionProcessorEngine, ec, pContext);

Exit:
    tfSelection.range->Release();
    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionInputWorker
//
// If the keystroke happens within a composition, eat the key and return S_OK.
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionInputWorker(_In_ CCompositionProcessorEngine *pCompositionProcessorEngine, TfEditCookie ec, _In_ ITfContext *pContext)
{
    HRESULT hr = S_OK;
    CSampleImeArray<CStringRange> readingStrings;
    BOOL isWildcardIncluded = TRUE;

    //
    // Get reading string from composition processor engine
    //
    pCompositionProcessorEngine->GetReadingStrings(&readingStrings, &isWildcardIncluded);

    for (UINT index = 0; index < readingStrings.Count(); index++)
    {
        hr = _AddComposingAndChar(ec, pContext, readingStrings.GetAt(index));
        if (FAILED(hr))
        {
            return hr;
        }
    }

    // [Ohagey] Typing does not convert.
    //
    // The sample asked the dictionary for candidates on every keystroke and
    // popped the candidate window open as you typed. That is how a pinyin IME
    // works: there is no useful intermediate form, so you are always choosing
    // from a list. Japanese has one -- the kana above -- and conversion is a
    // thing the user asks for, with space.
    //
    // Keeping the sample's behaviour was not just stylistically wrong, it was
    // slow. Every keystroke became a full round trip to the engine, and every
    // request rebuilds the lattice from nothing (decision 0034 stops the
    // composition first, to keep the candidate order from oscillating). That
    // is a measured 137ms each. Typing `nihongo` spent seven of them, and the
    // engine had burned twelve seconds of CPU after a few words of testing --
    // which is exactly what "sluggish" felt like from the keyboard.
    //
    // So: show the kana, and wait to be asked. `_HandleCompositionConvert`
    // does the conversion when the user presses the conversion key.
    //
    // A candidate window left over from a previous conversion is emptied
    // rather than left standing: the reading just changed under it, so what
    // it is showing is an answer to a question nobody is asking any more.
    isWildcardIncluded;

    if (_pCandidateListUIPresenter)
    {
        _pCandidateListUIPresenter->_ClearList();
    }

    return hr;
}
//+---------------------------------------------------------------------------
//
// _CreateAndStartCandidate
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_CreateAndStartCandidate(_In_ CCompositionProcessorEngine *pCompositionProcessorEngine, TfEditCookie ec, _In_ ITfContext *pContext)
{
    HRESULT hr = S_OK;

    if (((_candidateMode == CANDIDATE_PHRASE) && (_pCandidateListUIPresenter))
        || ((_candidateMode == CANDIDATE_NONE) && (_pCandidateListUIPresenter)))
    {
        // Recreate candidate list
        _pCandidateListUIPresenter->_EndCandidateList();
        delete _pCandidateListUIPresenter;
        _pCandidateListUIPresenter = nullptr;

        _candidateMode = CANDIDATE_NONE;
        _isCandidateWithWildcard = FALSE;
    }

    if (_pCandidateListUIPresenter == nullptr)
    {
        _pCandidateListUIPresenter = new (std::nothrow) CCandidateListUIPresenter(this, Global::AtomCandidateWindow,
            CATEGORY_CANDIDATE,
            pCompositionProcessorEngine->GetCandidateListIndexRange(),
            FALSE);
        if (!_pCandidateListUIPresenter)
        {
            return E_OUTOFMEMORY;
        }

        _candidateMode = CANDIDATE_INCREMENTAL;
        _isCandidateWithWildcard = FALSE;

        // we don't cache the document manager object. So get it from pContext.
        ITfDocumentMgr* pDocumentMgr = nullptr;
        if (SUCCEEDED(pContext->GetDocumentMgr(&pDocumentMgr)))
        {
            // get the composition range.
            ITfRange* pRange = nullptr;
            if (SUCCEEDED(_pComposition->GetRange(&pRange)))
            {
                hr = _pCandidateListUIPresenter->_StartCandidateList(_tfClientId, pDocumentMgr, pContext, ec, pRange, pCompositionProcessorEngine->GetCandidateWindowWidth());
                pRange->Release();
            }
            pDocumentMgr->Release();
        }
    }

    return hr;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionFinalize
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionFinalize(TfEditCookie ec, _In_ ITfContext *pContext, BOOL isCandidateList)
{
    HRESULT hr = S_OK;

    // [Ohagey] `_candidateMode`, again, for the same reason as in
    // `_HandleCompositionInput`: the presenter outlives the window it drew.
    //
    // Without it, Enter on plain kana — 無変換で確定 — took the candidate
    // branch, asked a list that had already ended for its selection, got
    // nothing, and fell through to `_HandleCancel`, which **threw the kana
    // away**. It worked exactly until the user's first conversion, because
    // that is when the pointer stops being null and never becomes null again.
    //
    // Reported as not being able to commit without converting, which is what
    // it was: the composition was discarded rather than committed.
    if (isCandidateList && _pCandidateListUIPresenter && (_candidateMode != CANDIDATE_NONE))
    {
        // Finalize selected candidate string from CCandidateListUIPresenter
        DWORD_PTR candidateLen = 0;
        const WCHAR *pCandidateString = nullptr;

        candidateLen = _pCandidateListUIPresenter->_GetSelectedCandidateString(&pCandidateString);

        CStringRange candidateString;
        candidateString.Set(pCandidateString, candidateLen);

        if (candidateLen)
        {
            // Finalize character
            hr = _AddCharAndFinalize(ec, pContext, &candidateString);
            if (FAILED(hr))
            {
                return hr;
            }

            // [Ohagey] Tell the engine what the user settled on so it can learn
            // (decisions 0024 / 0025).
            //
            // Here, not after _HandleCancel below: that tears the composition
            // down, and the reading is derived from the keystroke buffer it
            // clears. Also only on success — learning from a candidate that
            // never made it into the document would teach the engine a choice
            // the user never got.
            //
            // Secure mode covers the logon screen and UAC, where remembering
            // what was typed is wrong whatever the user's learning setting
            // says. It does not cover an ordinary password field inside a
            // normal application; TSF does not tell us about those here, and
            // handling them needs the per-context disabled state instead.
            CCompositionProcessorEngine* pEngine = _pCompositionProcessorEngine;
            if (pEngine)
            {
                pEngine->NotifyCommitted(candidateString, _IsSecureMode() ? FALSE : TRUE);
            }
        }
    }
    else
    {
        // Finalize current text store strings
        if (_IsComposing())
        {
            ULONG fetched = 0;
            TF_SELECTION tfSelection;

            if (FAILED(pContext->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &tfSelection, &fetched)) || fetched != 1)
            {
                return S_FALSE;
            }

            ITfRange* pRangeComposition = nullptr;
            if (SUCCEEDED(_pComposition->GetRange(&pRangeComposition)))
            {
                if (_IsRangeCovered(ec, tfSelection.range, pRangeComposition))
                {
                    // [Ohagey] Read before the composition is ended: after
                    // `_EndComposition` there is no range to ask.
                    //
                    // 無変換確定 is text the user wrote, so it belongs in the
                    // corpus the personal model trains on (decisions 0024 /
                    // 0025). The pair it teaches the learning store is reading
                    // = surface, which cannot change a conversion's ranking —
                    // but it does make the kana form itself rise as a
                    // candidate for that reading, which is what Microsoft IME
                    // does after the same keystroke.
                    //
                    // Before `_HandleCancel` below, which purges the keystroke
                    // buffer `NotifyCommitted` derives the reading from — the
                    // same ordering constraint as the other two call sites.
                    WCHAR committed[PRECEDING_TEXT_MAX + 1] = {'\0'};
                    ULONG length = 0;
                    if (SUCCEEDED(pRangeComposition->GetText(ec, 0, committed,
                                                             PRECEDING_TEXT_MAX, &length))
                        && length > 0)
                    {
                        CStringRange committedRange;
                        committedRange.Set(committed, length);

                        CCompositionProcessorEngine* pEngine = _pCompositionProcessorEngine;
                        if (pEngine)
                        {
                            pEngine->NotifyCommitted(committedRange,
                                                     _IsSecureMode() ? FALSE : TRUE);
                        }
                    }

                    _EndComposition(pContext);
                }

                pRangeComposition->Release();
            }

            tfSelection.range->Release();
        }
    }

    _HandleCancel(ec, pContext);

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _GetPrecedingText     [Ohagey]
//
// The committed text immediately before the composition (decision 0034).
//
// Zenzai takes it as `leftSideContext` and uses it to choose between readings
// that are otherwise tied -- 「はし」 after 「川に」 is not the same word as
// 「はし」 after 「ご飯を」. Nothing is learned from it, so unlike
// personalisation there is nothing here that can be taught a mistake.
//
// Read fresh at each conversion rather than tracked as we go: the user can
// click elsewhere, edit behind the caret, or switch documents between one
// conversion and the next, and a cached copy would then be a confident answer
// about the wrong place.
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_GetPrecedingText(TfEditCookie ec, _In_ ITfContext *pContext, _Out_ std::wstring *pText)
{
    pContext;
    pText->clear();

    if (_pComposition == nullptr)
    {
        Ohagey::Log("preceding: no composition");
        return S_FALSE;
    }

    ITfRange* pRangeComposition = nullptr;
    const HRESULT hrRange = _pComposition->GetRange(&pRangeComposition);
    if (FAILED(hrRange) || pRangeComposition == nullptr)
    {
        Ohagey::Log("preceding: GetRange 0x%08X", hrRange);
        return S_FALSE;
    }

    HRESULT hr = S_FALSE;
    ITfRange* pRangeBefore = nullptr;
    if (SUCCEEDED(pRangeComposition->Clone(&pRangeBefore)) && pRangeBefore != nullptr)
    {
        // Collapse onto the composition's start, then pull the start back: the
        // range then covers the characters immediately before it. Near the top
        // of a document ShiftStart simply moves less, and GetText respects that.
        if (SUCCEEDED(pRangeBefore->Collapse(ec, TF_ANCHOR_START)))
        {
            // `shifted` is required by the signature but deliberately not
            // tested. The first version gated on `shifted < 0`, assuming the
            // count comes back signed for a backward shift. Notepad's text
            // store does report it signed -- the log shows -2, -4, -7 -- so
            // that guard was **not** what kept this empty; the build under
            // test was simply never the one loaded. The guard is gone anyway:
            // the interface does not promise a sign, and there is nothing to
            // protect against, because a start that did not move leaves an
            // empty range and GetText returns nothing.
            LONG shifted = 0;
            const HRESULT hrShift = pRangeBefore->ShiftStart(ec, -PRECEDING_TEXT_MAX, &shifted, nullptr);
            if (SUCCEEDED(hrShift))
            {
                WCHAR buffer[PRECEDING_TEXT_MAX + 1] = {'\0'};
                ULONG fetched = 0;
                const HRESULT hrText = pRangeBefore->GetText(ec, 0, buffer, PRECEDING_TEXT_MAX, &fetched);
                // Counts and HRESULTs only -- never the characters. See OhageyLog.h.
                Ohagey::Log("preceding: shift 0x%08X moved %ld, GetText 0x%08X fetched %lu",
                            hrShift, shifted, hrText, fetched);
                if (SUCCEEDED(hrText) && fetched > 0)
                {
                    pText->assign(buffer, fetched);
                    hr = S_OK;
                }
            }
            else
            {
                Ohagey::Log("preceding: ShiftStart 0x%08X", hrShift);
            }
        }
        else
        {
            Ohagey::Log("preceding: Collapse failed");
        }
        pRangeBefore->Release();
    }
    pRangeComposition->Release();

    // Cut at the last line break. Context is what the sentence is running on,
    // and the paragraph above is a different sentence -- feeding it in would
    // ask the model to continue something the user already finished.
    const size_t lastBreak = pText->find_last_of(L"\r\n");
    if (lastBreak != std::wstring::npos)
    {
        pText->erase(0, lastBreak + 1);
    }

    Ohagey::Log("preceding: returning %zu chars", pText->size());
    return hr;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionConvert
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionConvert(TfEditCookie ec, _In_ ITfContext *pContext, BOOL isWildcardSearch)
{
    HRESULT hr = S_OK;

    CSampleImeArray<CCandidateListItem> candidateList;

    //
    // Get candidate string from composition processor engine
    //
    CCompositionProcessorEngine* pCompositionProcessorEngine = nullptr;
    pCompositionProcessorEngine = _pCompositionProcessorEngine;
    // [Ohagey] What the user already wrote, to the left of what they are
    // converting now (decision 0034).
    //
    // The protocol has carried this field since decision 0007 and the engine
    // has used it since decision 0034 -- but the TSF side sent an empty string,
    // so every request in a real session logged `preceding 0` and the feature
    // was measured only in a harness. This is the missing end.
    std::wstring precedingText;
    _GetPrecedingText(ec, pContext, &precedingText);

    pCompositionProcessorEngine->GetCandidateList(&candidateList, FALSE, isWildcardSearch, precedingText);

    // If there is no candlidate listin the current reading string, we don't do anything. Just wait for
    // next char to be ready for the conversion with it.
    int nCount = candidateList.Count();
    if (nCount)
    {
        if (_pCandidateListUIPresenter)
        {
            _pCandidateListUIPresenter->_EndCandidateList();
            delete _pCandidateListUIPresenter;
            _pCandidateListUIPresenter = nullptr;

            _candidateMode = CANDIDATE_NONE;
            _isCandidateWithWildcard = FALSE;
        }

        // 
        // create an instance of the candidate list class.
        // 
        if (_pCandidateListUIPresenter == nullptr)
        {
            _pCandidateListUIPresenter = new (std::nothrow) CCandidateListUIPresenter(this, Global::AtomCandidateWindow,
                CATEGORY_CANDIDATE,
                pCompositionProcessorEngine->GetCandidateListIndexRange(),
                FALSE);
            if (!_pCandidateListUIPresenter)
            {
                return E_OUTOFMEMORY;
            }

            _candidateMode = CANDIDATE_ORIGINAL;
        }

        _isCandidateWithWildcard = isWildcardSearch;

        // we don't cache the document manager object. So get it from pContext.
        ITfDocumentMgr* pDocumentMgr = nullptr;
        if (SUCCEEDED(pContext->GetDocumentMgr(&pDocumentMgr)))
        {
            // get the composition range.
            ITfRange* pRange = nullptr;
            if (SUCCEEDED(_pComposition->GetRange(&pRange)))
            {
                hr = _pCandidateListUIPresenter->_StartCandidateList(_tfClientId, pDocumentMgr, pContext, ec, pRange, pCompositionProcessorEngine->GetCandidateWindowWidth());
                pRange->Release();
            }
            pDocumentMgr->Release();
        }
        if (SUCCEEDED(hr))
        {
            _pCandidateListUIPresenter->_SetText(&candidateList, FALSE);
        }
    }

    return hr;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionBackspace
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionBackspace(TfEditCookie ec, _In_ ITfContext *pContext)
{
    ITfRange* pRangeComposition = nullptr;
    TF_SELECTION tfSelection;
    ULONG fetched = 0;
    BOOL isCovered = TRUE;

    // Start the new (std::nothrow) compositon if there is no composition.
    if (!_IsComposing())
    {
        return S_OK;
    }

    // first, test where a keystroke would go in the document if we did an insert
    if (FAILED(pContext->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &tfSelection, &fetched)) || fetched != 1)
    {
        return S_FALSE;
    }

    // is the insertion point covered by a composition?
    if (SUCCEEDED(_pComposition->GetRange(&pRangeComposition)))
    {
        isCovered = _IsRangeCovered(ec, tfSelection.range, pRangeComposition);

        pRangeComposition->Release();

        if (!isCovered)
        {
            goto Exit;
        }
    }

    //
    // Add virtual key to composition processor engine
    //
    CCompositionProcessorEngine* pCompositionProcessorEngine = nullptr;
    pCompositionProcessorEngine = _pCompositionProcessorEngine;

    DWORD_PTR vKeyLen = pCompositionProcessorEngine->GetVirtualKeyLength();

    if (vKeyLen)
    {
        pCompositionProcessorEngine->RemoveVirtualKey(vKeyLen - 1);

        if (pCompositionProcessorEngine->GetVirtualKeyLength())
        {
            _HandleCompositionInputWorker(pCompositionProcessorEngine, ec, pContext);
        }
        else
        {
            _HandleCancel(ec, pContext);
        }
    }

Exit:
    tfSelection.range->Release();
    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionArrowKey
//
// Update the selection within a composition.
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionArrowKey(TfEditCookie ec, _In_ ITfContext *pContext, KEYSTROKE_FUNCTION keyFunction)
{
    ITfRange* pRangeComposition = nullptr;
    TF_SELECTION tfSelection;
    ULONG fetched = 0;

    // get the selection
    if (FAILED(pContext->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &tfSelection, &fetched))
        || fetched != 1)
    {
        // no selection, eat the keystroke
        return S_OK;
    }

    // get the composition range
    if (FAILED(_pComposition->GetRange(&pRangeComposition)))
    {
        goto Exit;
    }

    // For incremental candidate list
    if (_pCandidateListUIPresenter)
    {
        _pCandidateListUIPresenter->AdviseUIChangedByArrowKey(keyFunction);
    }

    pContext->SetSelection(ec, 1, &tfSelection);

    pRangeComposition->Release();

Exit:
    tfSelection.range->Release();
    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionPunctuation
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionPunctuation(TfEditCookie ec, _In_ ITfContext *pContext, WCHAR wch)
{
    HRESULT hr = S_OK;

    if (_candidateMode != CANDIDATE_NONE && _pCandidateListUIPresenter)
    {
        DWORD_PTR candidateLen = 0;
        const WCHAR* pCandidateString = nullptr;

        candidateLen = _pCandidateListUIPresenter->_GetSelectedCandidateString(&pCandidateString);

        CStringRange candidateString;
        candidateString.Set(pCandidateString, candidateLen);

        if (candidateLen)
        {
            _AddComposingAndChar(ec, pContext, &candidateString);
        }
    }
    //
    // Get punctuation char from composition processor engine
    //
    CCompositionProcessorEngine* pCompositionProcessorEngine = nullptr;
    pCompositionProcessorEngine = _pCompositionProcessorEngine;

    WCHAR punctuation = pCompositionProcessorEngine->GetPunctuation(wch);

    CStringRange punctuationString;
    punctuationString.Set(&punctuation, 1);

    // Finalize character
    hr = _AddCharAndFinalize(ec, pContext, &punctuationString);
    if (FAILED(hr))
    {
        return hr;
    }

    _HandleCancel(ec, pContext);

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _HandleCompositionDoubleSingleByte
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::_HandleCompositionDoubleSingleByte(TfEditCookie ec, _In_ ITfContext *pContext, WCHAR wch)
{
    HRESULT hr = S_OK;

    WCHAR fullWidth = Global::FullWidthCharTable[wch - 0x20];

    CStringRange fullWidthString;
    fullWidthString.Set(&fullWidth, 1);

    // Finalize character
    hr = _AddCharAndFinalize(ec, pContext, &fullWidthString);
    if (FAILED(hr))
    {
        return hr;
    }

    _HandleCancel(ec, pContext);

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// _InvokeKeyHandler
//
// This text service is interested in handling keystrokes to demonstrate the
// use the compositions. Some apps will cancel compositions if they receive
// keystrokes while a compositions is ongoing.
//
// param
//    [in] uCode - virtual key code of WM_KEYDOWN wParam
//    [in] dwFlags - WM_KEYDOWN lParam
//    [in] dwKeyFunction - Function regarding virtual key
//----------------------------------------------------------------------------

HRESULT CSampleIME::_InvokeKeyHandler(_In_ ITfContext *pContext, UINT code, WCHAR wch, DWORD flags, _KEYSTROKE_STATE keyState)
{
    flags;

    CKeyHandlerEditSession* pEditSession = nullptr;
    HRESULT hr = E_FAIL;

    // we'll insert a char ourselves in place of this keystroke
    pEditSession = new (std::nothrow) CKeyHandlerEditSession(this, pContext, code, wch, keyState);
    if (pEditSession == nullptr)
    {
        goto Exit;
    }

    //
    // Call CKeyHandlerEditSession::DoEditSession().
    //
    // Do not specify TF_ES_SYNC so edit session is not invoked on WinWord
    //
    hr = pContext->RequestEditSession(_tfClientId, pEditSession, TF_ES_ASYNCDONTCARE | TF_ES_READWRITE, &hr);

    pEditSession->Release();

Exit:
    return hr;
}
