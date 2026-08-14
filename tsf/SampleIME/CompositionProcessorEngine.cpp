// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#include "Private.h"
#include "SampleIME.h"
#include "CompositionProcessorEngine.h"
#include "../Ohagey/RomajiKana.h"
#include "TableDictionaryEngine.h"
#include "DictionarySearch.h"
#include "TfInputProcessorProfile.h"
#include "Globals.h"
#include "Compartment.h"
#include "LanguageBar.h"
#include "RegKey.h"

//////////////////////////////////////////////////////////////////////
//
// CSampleIME implementation.
//
//////////////////////////////////////////////////////////////////////

//+---------------------------------------------------------------------------
//
// _AddTextProcessorEngine
//
//----------------------------------------------------------------------------

BOOL CSampleIME::_AddTextProcessorEngine()
{
    LANGID langid = 0;
    CLSID clsid = GUID_NULL;
    GUID guidProfile = GUID_NULL;

    // Get default profile.
    CTfInputProcessorProfile profile;

    if (FAILED(profile.CreateInstance()))
    {
        return FALSE;
    }

    if (FAILED(profile.GetCurrentLanguage(&langid)))
    {
        return FALSE;
    }

    if (FAILED(profile.GetDefaultLanguageProfile(langid, GUID_TFCAT_TIP_KEYBOARD, &clsid, &guidProfile)))
    {
        return FALSE;
    }

    // Is this already added?
    if (_pCompositionProcessorEngine != nullptr)
    {
        LANGID langidProfile = 0;
        GUID guidLanguageProfile = GUID_NULL;

        guidLanguageProfile = _pCompositionProcessorEngine->GetLanguageProfile(&langidProfile);
        if ((langid == langidProfile) && IsEqualGUID(guidProfile, guidLanguageProfile))
        {
            return TRUE;
        }
    }

    // Create composition processor engine
    if (_pCompositionProcessorEngine == nullptr)
    {
        _pCompositionProcessorEngine = new (std::nothrow) CCompositionProcessorEngine();
    }
    if (!_pCompositionProcessorEngine)
    {
        return FALSE;
    }

    // setup composition processor engine
    if (FALSE == _pCompositionProcessorEngine->SetupLanguageProfile(langid, guidProfile, _GetThreadMgr(), _GetClientId(), _IsSecureMode(), _IsComLess()))
    {
        return FALSE;
    }

    return TRUE;
}

//////////////////////////////////////////////////////////////////////
//
// CompositionProcessorEngine implementation.
//
//////////////////////////////////////////////////////////////////////

//+---------------------------------------------------------------------------
//
// ctor
//
//----------------------------------------------------------------------------

CCompositionProcessorEngine::CCompositionProcessorEngine()
{
    _pTableDictionaryEngine = nullptr;
    _pDictionaryFile = nullptr;

    _langid = 0xffff;
    _guidProfile = GUID_NULL;
    _tfClientId = TF_CLIENTID_NULL;

    _pLanguageBar_IMEMode = nullptr;
    _pLanguageBar_DoubleSingleByte = nullptr;
    _pLanguageBar_Punctuation = nullptr;

    _pCompartmentConversion = nullptr;
    _pCompartmentKeyboardOpenEventSink = nullptr;
    _pCompartmentConversionEventSink = nullptr;
    _pCompartmentDoubleSingleByteEventSink = nullptr;
    _pCompartmentPunctuationEventSink = nullptr;

    _hasWildcardIncludedInKeystrokeBuffer = FALSE;

    _isWildcard = FALSE;
    _isDisableWildcardAtFirst = FALSE;
    _hasMakePhraseFromText = FALSE;
    _isKeystrokeSort = FALSE;

    _candidateListPhraseModifier = 0;

    _candidateWndWidth = CAND_WIDTH;

    InitKeyStrokeTable();
}

//+---------------------------------------------------------------------------
//
// dtor
//
//----------------------------------------------------------------------------

CCompositionProcessorEngine::~CCompositionProcessorEngine()
{
    if (_pTableDictionaryEngine)
    {
        delete _pTableDictionaryEngine;
        _pTableDictionaryEngine = nullptr;
    }

    if (_pLanguageBar_IMEMode)
    {
        _pLanguageBar_IMEMode->CleanUp();
        _pLanguageBar_IMEMode->Release();
        _pLanguageBar_IMEMode = nullptr;
    }
    if (_pLanguageBar_DoubleSingleByte)
    {
        _pLanguageBar_DoubleSingleByte->CleanUp();
        _pLanguageBar_DoubleSingleByte->Release();
        _pLanguageBar_DoubleSingleByte = nullptr;
    }
    if (_pLanguageBar_Punctuation)
    {
        _pLanguageBar_Punctuation->CleanUp();
        _pLanguageBar_Punctuation->Release();
        _pLanguageBar_Punctuation = nullptr;
    }

    if (_pCompartmentConversion)
    {
        delete _pCompartmentConversion;
        _pCompartmentConversion = nullptr;
    }
    if (_pCompartmentKeyboardOpenEventSink)
    {
        _pCompartmentKeyboardOpenEventSink->_Unadvise();
        delete _pCompartmentKeyboardOpenEventSink;
        _pCompartmentKeyboardOpenEventSink = nullptr;
    }
    if (_pCompartmentConversionEventSink)
    {
        _pCompartmentConversionEventSink->_Unadvise();
        delete _pCompartmentConversionEventSink;
        _pCompartmentConversionEventSink = nullptr;
    }
    if (_pCompartmentDoubleSingleByteEventSink)
    {
        _pCompartmentDoubleSingleByteEventSink->_Unadvise();
        delete _pCompartmentDoubleSingleByteEventSink;
        _pCompartmentDoubleSingleByteEventSink = nullptr;
    }
    if (_pCompartmentPunctuationEventSink)
    {
        _pCompartmentPunctuationEventSink->_Unadvise();
        delete _pCompartmentPunctuationEventSink;
        _pCompartmentPunctuationEventSink = nullptr;
    }

    if (_pDictionaryFile)
    {
        delete _pDictionaryFile;
        _pDictionaryFile = nullptr;
    }
}

//+---------------------------------------------------------------------------
//
// SetupLanguageProfile
//
// Setup language profile for Composition Processor Engine.
// param
//     [in] LANGID langid = Specify language ID
//     [in] GUID guidLanguageProfile - Specify GUID language profile which GUID is as same as Text Service Framework language profile.
//     [in] ITfThreadMgr - pointer ITfThreadMgr.
//     [in] tfClientId - TfClientId value.
//     [in] isSecureMode - secure mode
// returns
//     If setup succeeded, returns true. Otherwise returns false.
// N.B. For reverse conversion, ITfThreadMgr is NULL, TfClientId is 0 and isSecureMode is ignored.
//+---------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::SetupLanguageProfile(LANGID langid, REFGUID guidLanguageProfile, _In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId, BOOL isSecureMode, BOOL isComLessMode)
{
    BOOL ret = TRUE;
    if ((tfClientId == 0) && (pThreadMgr == nullptr))
    {
        ret = FALSE;
        goto Exit;
    }

    _isComLessMode = isComLessMode;
    _langid = langid;
    _guidProfile = guidLanguageProfile;
    _tfClientId = tfClientId;

    SetupPreserved(pThreadMgr, tfClientId);	
	InitializeSampleIMECompartment(pThreadMgr, tfClientId);
    SetupPunctuationPair();
    SetupLanguageBar(pThreadMgr, tfClientId, isSecureMode);
    SetupKeystroke();
    SetupConfiguration();

    // Start the engine now rather than at the first conversion (decision 0033).
    // It returns immediately and holds no connection; by the time the user has
    // typed a reading the engine is listening, so the first conversion works
    // instead of coming back empty. See EngineClient::Warmup.
    _engineClient.Warmup();

Exit:
    return ret;
}

//+---------------------------------------------------------------------------
//
// AddVirtualKey
// Add virtual key code to Composition Processor Engine for used to parse keystroke data.
// param
//     [in] uCode - Specify virtual key code.
// returns
//     State of Text Processor Engine.
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::AddVirtualKey(WCHAR wch)
{
    if (!wch)
    {
        return FALSE;
    }

    //
    // append one keystroke in buffer.
    //
    DWORD_PTR srgKeystrokeBufLen = _keystrokeBuffer.GetLength();
    PWCHAR pwch = new (std::nothrow) WCHAR[ srgKeystrokeBufLen + 1 ];
    if (!pwch)
    {
        return FALSE;
    }

    memcpy(pwch, _keystrokeBuffer.Get(), srgKeystrokeBufLen * sizeof(WCHAR));
    pwch[ srgKeystrokeBufLen ] = wch;

    if (_keystrokeBuffer.Get())
    {
        delete [] _keystrokeBuffer.Get();
    }

    _keystrokeBuffer.Set(pwch, srgKeystrokeBufLen + 1);

    return TRUE;
}

//+---------------------------------------------------------------------------
//
// RemoveVirtualKey
// Remove stored virtual key code.
// param
//     [in] dwIndex   - Specified index.
// returns
//     none.
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::RemoveVirtualKey(DWORD_PTR dwIndex)
{
    DWORD_PTR srgKeystrokeBufLen = _keystrokeBuffer.GetLength();

    if (dwIndex + 1 < srgKeystrokeBufLen)
    {
        // shift following eles left
        memmove((BYTE*)_keystrokeBuffer.Get() + (dwIndex * sizeof(WCHAR)),
            (BYTE*)_keystrokeBuffer.Get() + ((dwIndex + 1) * sizeof(WCHAR)),
            (srgKeystrokeBufLen - dwIndex - 1) * sizeof(WCHAR));
    }

    _keystrokeBuffer.Set(_keystrokeBuffer.Get(), srgKeystrokeBufLen - 1);
}

//+---------------------------------------------------------------------------
//
// PurgeVirtualKey
// Purge stored virtual key code.
// param
//     none.
// returns
//     none.
//----------------------------------------------------------------------------

//+---------------------------------------------------------------------------
//
// GetCandidateListFromEngine     [Ohagey]
//
// Asks the conversion server for candidates (decisions 0004-0007). Replaces the
// sample's table-dictionary lookup, which ran in this process.
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::GetCandidateListFromEngine(const CStringRange& keystrokes,
    const std::wstring& precedingText,
    _Inout_ CSampleImeArray<CCandidateListItem>* pCandidateList)
{
    if (keystrokes.GetLength() == 0)
    {
        return;
    }

    // CStringRange is not null-terminated, so build the string from the range.
    const std::wstring romaji(keystrokes.Get(), static_cast<size_t>(keystrokes.GetLength()));

    // The engine converts readings and expects hiragana, so romaji has to be
    // resolved before it goes on the wire (ConversionService uses `.direct`
    // input for exactly this reason).
    //
    // Derived here rather than kept alongside the keystroke buffer as a second
    // piece of state. RemoveVirtualKey can delete from the middle by index, and
    // keeping a separate converter in step with that is a synchronisation bug
    // waiting to happen; recomputing from the one buffer that is authoritative
    // costs nothing at these lengths.
    const std::wstring readingText = Ohagey::RomajiToKana(romaji);
    if (readingText.empty())
    {
        // Everything typed so far is still mid-syllable — `k`, `ky`. There is
        // no reading to convert yet.
        return;
    }

    Ohagey::ConvertResult result;
    // n_best 0 means "engine default" in ohagey.proto. Sending 0 keeps the
    // decision about how many candidates to produce in one place instead of
    // duplicating it here.
    if (_engineClient.Convert(readingText, 0, precedingText, &result) != Ohagey::CallResult::Ok)
    {
        // No candidates. The engine may be starting, may have exited on its
        // idle timeout, or may have refused this reading; none of those are
        // worth tearing anything down over, and the next keystroke retries.
        return;
    }

    for (size_t i = 0; i < result.candidates.size(); ++i)
    {
        // Held for the whole composition; see the note on _candidateStrings.
        _candidateStrings.push_back(result.candidates[i].text);
        const std::wstring& text = _candidateStrings.back();
        _candidateStrings.push_back(result.candidates[i].reading);
        const std::wstring& itemReading = _candidateStrings.back();

        // Append() default-constructs the element and hands back a pointer to
        // it; it does not take a value.
        CCandidateListItem* pItem = pCandidateList->Append();
        if (!pItem)
        {
            return;
        }
        pItem->_ItemString.Set(text.c_str(), text.length());
        pItem->_FindKeyCode.Set(itemReading.c_str(), itemReading.length());
    }
}

//+---------------------------------------------------------------------------
//
// NotifyCommitted     [Ohagey]
//
// Feeds the confirmed reading/candidate pair back to the engine so it can
// learn (decisions 0024 / 0025).
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::NotifyCommitted(const CStringRange& committedText, BOOL updateLearning)
{
    if (committedText.GetLength() == 0 || _keystrokeBuffer.GetLength() == 0)
    {
        return;
    }

    const std::wstring romaji(_keystrokeBuffer.Get(), static_cast<size_t>(_keystrokeBuffer.GetLength()));
    const std::wstring reading = Ohagey::RomajiToKana(romaji);
    if (reading.empty())
    {
        // Nothing resolved into kana, so there is no reading to associate the
        // text with. Learning from that would key the store on nothing.
        return;
    }

    const std::wstring text(committedText.Get(), static_cast<size_t>(committedText.GetLength()));

    // The result is deliberately ignored. A commit that does not reach the
    // engine costs the user a learning opportunity; it must not cost them the
    // text they just typed, which is already in the document by now.
    _engineClient.Commit(reading, text, updateLearning ? true : false);
}

void CCompositionProcessorEngine::PurgeVirtualKey()
{
    // Ohagey: the composition is over, so nothing can still be pointing at the
    // candidate strings. This is the only place they are released — freeing
    // them when the next candidate list is fetched would pull the rug out from
    // under a candidate window that is still showing the previous one.
    _candidateStrings.clear();
    _displayReading.clear();

    if (_keystrokeBuffer.Get())
    {
        delete [] _keystrokeBuffer.Get();
        _keystrokeBuffer.Set(NULL, 0);
    }
}

WCHAR CCompositionProcessorEngine::GetVirtualKey(DWORD_PTR dwIndex) 
{ 
    if (dwIndex < _keystrokeBuffer.GetLength())
    {
        return *(_keystrokeBuffer.Get() + dwIndex);
    }
    return 0;
}
//+---------------------------------------------------------------------------
//
// GetReadingStrings
// Retrieves string from Composition Processor Engine.
// param
//     [out] pReadingStrings - Specified returns pointer of CUnicodeString.
// returns
//     none
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::GetReadingStrings(_Inout_ CSampleImeArray<CStringRange> *pReadingStrings, _Out_ BOOL *pIsWildcardIncluded)
{
    // [Ohagey] Show kana, not the romaji that produced it.
    //
    // The sample handed back the keystroke buffer verbatim, which was correct
    // when keystrokes *were* the reading. Typing `henkan` has to put へんかん in
    // the composition, not `henkan`.
    //
    // Unresolved romaji stays visible — after `ky` the user needs to see that
    // they typed it — which is why this uses Display() rather than the reading
    // that goes to the engine.
    //
    // The string is a member because CStringRange owns nothing: a local would
    // be gone before the caller put it in the composition.

    // Wildcards were a table-dictionary feature and the search that used them
    // is gone (see GetCandidateList); Japanese input has no `*` or `?`.
    _hasWildcardIncludedInKeystrokeBuffer = FALSE;
    *pIsWildcardIncluded = FALSE;

    if (pReadingStrings->Count() != 0 || _keystrokeBuffer.GetLength() == 0)
    {
        return;
    }

    const std::wstring romaji(_keystrokeBuffer.Get(), static_cast<size_t>(_keystrokeBuffer.GetLength()));
    _displayReading = Ohagey::RomajiToDisplay(romaji);
    if (_displayReading.empty())
    {
        return;
    }

    CStringRange* pNewString = pReadingStrings->Append();
    if (pNewString)
    {
        pNewString->Set(_displayReading.c_str(), _displayReading.length());
    }
}

//+---------------------------------------------------------------------------
//
// GetCandidateList
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::GetCandidateList(_Inout_ CSampleImeArray<CCandidateListItem> *pCandidateList, BOOL isIncrementalWordSearch, BOOL isWildcardSearch, const std::wstring& precedingText)
{
    // [Ohagey] Rewritten: candidates come from the engine (decisions 0004-0007).
    //
    // The sample distinguished plain, incremental and wildcard searches because
    // all three were ways of walking its table dictionary, and it let the user
    // type `*` and `?` into the reading. None of that survives the move to a
    // conversion server: the engine converts a reading, and a Japanese IME has
    // no wildcard input to begin with. All three callers get the same thing.
    isIncrementalWordSearch;
    isWildcardSearch;

    if (!IsDictionaryAvailable())
    {
        return;
    }

    GetCandidateListFromEngine(_keystrokeBuffer, precedingText, pCandidateList);
}

//+---------------------------------------------------------------------------
//
// GetCandidateStringInConverted
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::GetCandidateStringInConverted(CStringRange &searchString, _In_ CSampleImeArray<CCandidateListItem> *pCandidateList)
{
    // [Ohagey] Not supported.
    //
    // The sample searched its table dictionary backwards — given a converted
    // string, find the keystrokes that would have produced it — to offer
    // "you could have typed this" hints. That is a property of an in-process
    // table; ohagey.proto has no reverse lookup and the engine does not index
    // one. Adding it would mean a new message and a decision to go with it.
    //
    // Returning nothing leaves the candidate window without those hints, which
    // is a missing convenience rather than a broken conversion.
    searchString;
    pCandidateList;
}

//+---------------------------------------------------------------------------
//
// IsPunctuation
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsPunctuation(WCHAR wch)
{
    for (int i = 0; i < ARRAYSIZE(Global::PunctuationTable); i++)
    {
        if (Global::PunctuationTable[i]._Code == wch)
        {
            return TRUE;
        }
    }

    for (UINT j = 0; j < _PunctuationPair.Count(); j++)
    {
        CPunctuationPair* pPuncPair = _PunctuationPair.GetAt(j);

        if (pPuncPair->_punctuation._Code == wch)
        {
            return TRUE;
        }
    }

    for (UINT k = 0; k < _PunctuationNestPair.Count(); k++)
    {
        CPunctuationNestPair* pPuncNestPair = _PunctuationNestPair.GetAt(k);

        if (pPuncNestPair->_punctuation_begin._Code == wch)
        {
            return TRUE;
        }
        if (pPuncNestPair->_punctuation_end._Code == wch)
        {
            return TRUE;
        }
    }
    return FALSE;
}

//+---------------------------------------------------------------------------
//
// GetPunctuationPair
//
//----------------------------------------------------------------------------

WCHAR CCompositionProcessorEngine::GetPunctuation(WCHAR wch)
{
    for (int i = 0; i < ARRAYSIZE(Global::PunctuationTable); i++)
    {
        if (Global::PunctuationTable[i]._Code == wch)
        {
            return Global::PunctuationTable[i]._Punctuation;
        }
    }

    for (UINT j = 0; j < _PunctuationPair.Count(); j++)
    {
        CPunctuationPair* pPuncPair = _PunctuationPair.GetAt(j);

        if (pPuncPair->_punctuation._Code == wch)
        {
            if (! pPuncPair->_isPairToggle)
            {
                pPuncPair->_isPairToggle = TRUE;
                return pPuncPair->_punctuation._Punctuation;
            }
            else
            {
                pPuncPair->_isPairToggle = FALSE;
                return pPuncPair->_pairPunctuation;
            }
        }
    }

    for (UINT k = 0; k < _PunctuationNestPair.Count(); k++)
    {
        CPunctuationNestPair* pPuncNestPair = _PunctuationNestPair.GetAt(k);

        if (pPuncNestPair->_punctuation_begin._Code == wch)
        {
            if (pPuncNestPair->_nestCount++ == 0)
            {
                return pPuncNestPair->_punctuation_begin._Punctuation;
            }
            else
            {
                return pPuncNestPair->_pairPunctuation_begin;
            }
        }
        if (pPuncNestPair->_punctuation_end._Code == wch)
        {
            if (--pPuncNestPair->_nestCount == 0)
            {
                return pPuncNestPair->_punctuation_end._Punctuation;
            }
            else
            {
                return pPuncNestPair->_pairPunctuation_end;
            }
        }
    }
    return 0;
}

//+---------------------------------------------------------------------------
//
// IsDoubleSingleByte
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsDoubleSingleByte(WCHAR wch)
{
    if (L' ' <= wch && wch <= L'~')
    {
        return TRUE;
    }
    return FALSE;
}

//+---------------------------------------------------------------------------
//
// SetupKeystroke
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetupKeystroke()
{
    SetKeystrokeTable(&_KeystrokeComposition);
    return;
}

//+---------------------------------------------------------------------------
//
// SetKeystrokeTable
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetKeystrokeTable(_Inout_ CSampleImeArray<_KEYSTROKE> *pKeystroke)
{
    for (int i = 0; i < ARRAYSIZE(_keystrokeTable); i++)
    {
        _KEYSTROKE* pKS = nullptr;

        pKS = pKeystroke->Append();
        if (!pKS)
        {
            break;
        }
        *pKS = _keystrokeTable[i];
    }
}

//+---------------------------------------------------------------------------
//
// SetupPreserved
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetupPreserved(_In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId)
{
    // [Ohagey] The keys a Japanese keyboard actually has.
    //
    // The sample toggled input mode on Shift pressed and released alone -- the
    // Simplified Chinese convention. On a Japanese keyboard that is both wrong
    // and hostile: 半角/全角 and 英数 are *printed on the keycaps* and did
    // nothing, while Shift, which everyone presses to type a capital, flipped
    // the mode.
    //
    // 半角/全角 arrives as VK_KANJI on a 106/109 layout. VK_OEM_AUTO and
    // VK_OEM_ENLW are the same key as some drivers and remappers report it;
    // registering all three costs nothing and means the key works wherever it
    // comes from.
    //
    // VK_CAPITAL with no modifier is the 英数 key. On a JIS keyboard 英数 is
    // the primary legend and CapsLock is the shifted one, which is why this is
    // bound bare -- Shift+CapsLock is left alone and still toggles caps.
    TF_PRESERVEDKEY preservedKeyImeMode;
    preservedKeyImeMode.uVKey = VK_KANJI;
    preservedKeyImeMode.uModifiers = 0;
    SetPreservedKey(Global::SampleIMEGuidImeModePreserveKey, preservedKeyImeMode, Global::ImeModeDescription, &_PreservedKey_IMEMode);
    AddPreservedKey(&_PreservedKey_IMEMode, VK_OEM_AUTO, 0);
    AddPreservedKey(&_PreservedKey_IMEMode, VK_OEM_ENLW, 0);

    // 英数. Registering VK_CAPITAL alone was not enough -- reported as the key
    // still doing nothing -- so the whole family the JIS keycap can arrive as
    // is registered:
    //
    //   VK_OEM_ATTN (0xF0) is VK_DBE_ALPHANUMERIC, which is what the 英数 key
    //     reports while an IME is active. It is almost certainly the one that
    //     was missing.
    //   VK_CAPITAL, plain and with Shift, because which of the two the key
    //     produces depends on the layout driver, and on a JIS keyboard 英数 is
    //     the primary legend either way.
    //
    // Registering several costs one table entry each and removes the guesswork;
    // a key that never arrives simply never fires.
    AddPreservedKey(&_PreservedKey_IMEMode, VK_OEM_ATTN, 0);
    AddPreservedKey(&_PreservedKey_IMEMode, VK_OEM_ATTN, TF_MOD_SHIFT);
    AddPreservedKey(&_PreservedKey_IMEMode, VK_CAPITAL, 0);
    AddPreservedKey(&_PreservedKey_IMEMode, VK_CAPITAL, TF_MOD_SHIFT);

    TF_PRESERVEDKEY preservedKeyDoubleSingleByte;
    preservedKeyDoubleSingleByte.uVKey = VK_SPACE;
    preservedKeyDoubleSingleByte.uModifiers = TF_MOD_SHIFT;
    SetPreservedKey(Global::SampleIMEGuidDoubleSingleBytePreserveKey, preservedKeyDoubleSingleByte, Global::DoubleSingleByteDescription, &_PreservedKey_DoubleSingleByte);

    TF_PRESERVEDKEY preservedKeyPunctuation;
    preservedKeyPunctuation.uVKey = VK_OEM_PERIOD;
    preservedKeyPunctuation.uModifiers = TF_MOD_CONTROL;
    SetPreservedKey(Global::SampleIMEGuidPunctuationPreserveKey, preservedKeyPunctuation, Global::PunctuationDescription, &_PreservedKey_Punctuation);

    InitPreservedKey(&_PreservedKey_IMEMode, pThreadMgr, tfClientId);
    InitPreservedKey(&_PreservedKey_DoubleSingleByte, pThreadMgr, tfClientId);
    InitPreservedKey(&_PreservedKey_Punctuation, pThreadMgr, tfClientId);

    return;
}

//+---------------------------------------------------------------------------
//
// SetKeystrokeTable
//
//----------------------------------------------------------------------------

// [Ohagey] A second (third, fourth) key for the same toggle.
//
// InitPreservedKey already walks TSFPreservedKeyTable, so several keys can
// share one GUID and one description; the sample simply never needed more than
// one. 半角/全角 does: it reaches us as VK_KANJI, VK_OEM_AUTO or VK_OEM_ENLW
// depending on the driver, and all of them mean the same thing to the user.
void CCompositionProcessorEngine::AddPreservedKey(_Inout_ XPreservedKey *pXPreservedKey, UINT vKey, UINT modifiers)
{
    TF_PRESERVEDKEY *pKey = pXPreservedKey->TSFPreservedKeyTable.Append();
    if (!pKey)
    {
        return;
    }
    pKey->uVKey = vKey;
    pKey->uModifiers = modifiers;
}

void CCompositionProcessorEngine::SetPreservedKey(const CLSID clsid, TF_PRESERVEDKEY & tfPreservedKey, _In_z_ LPCWSTR pwszDescription, _Out_ XPreservedKey *pXPreservedKey)
{
    pXPreservedKey->Guid = clsid;

    TF_PRESERVEDKEY *ptfPsvKey1 = pXPreservedKey->TSFPreservedKeyTable.Append();
    if (!ptfPsvKey1)
    {
        return;
    }
    *ptfPsvKey1 = tfPreservedKey;

	size_t srgKeystrokeBufLen = 0;
	if (StringCchLength(pwszDescription, STRSAFE_MAX_CCH, &srgKeystrokeBufLen) != S_OK)
    {
        return;
    }
    pXPreservedKey->Description = new (std::nothrow) WCHAR[srgKeystrokeBufLen + 1];
    if (!pXPreservedKey->Description)
    {
        return;
    }

    StringCchCopy((LPWSTR)pXPreservedKey->Description, srgKeystrokeBufLen, pwszDescription);

    return;
}
//+---------------------------------------------------------------------------
//
// InitPreservedKey
//
// Register a hot key.
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::InitPreservedKey(_In_ XPreservedKey *pXPreservedKey, _In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId)
{
    ITfKeystrokeMgr *pKeystrokeMgr = nullptr;

    if (IsEqualGUID(pXPreservedKey->Guid, GUID_NULL))
    {
        return FALSE;
    }

    if (pThreadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void **)&pKeystrokeMgr) != S_OK)
    {
        return FALSE;
    }

    for (UINT i = 0; i < pXPreservedKey->TSFPreservedKeyTable.Count(); i++)
    {
        TF_PRESERVEDKEY preservedKey = *pXPreservedKey->TSFPreservedKeyTable.GetAt(i);
        preservedKey.uModifiers &= 0xffff;

		size_t lenOfDesc = 0;
		if (StringCchLength(pXPreservedKey->Description, STRSAFE_MAX_CCH, &lenOfDesc) != S_OK)
        {
            return FALSE;
        }
        pKeystrokeMgr->PreserveKey(tfClientId, pXPreservedKey->Guid, &preservedKey, pXPreservedKey->Description, static_cast<ULONG>(lenOfDesc));
    }

    pKeystrokeMgr->Release();

    return TRUE;
}

//+---------------------------------------------------------------------------
//
// CheckShiftKeyOnly
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::CheckShiftKeyOnly(_In_ CSampleImeArray<TF_PRESERVEDKEY> *pTSFPreservedKeyTable)
{
    for (UINT i = 0; i < pTSFPreservedKeyTable->Count(); i++)
    {
        TF_PRESERVEDKEY *ptfPsvKey = pTSFPreservedKeyTable->GetAt(i);

        if (((ptfPsvKey->uModifiers & (_TF_MOD_ON_KEYUP_SHIFT_ONLY & 0xffff0000)) && !Global::IsShiftKeyDownOnly) ||
            ((ptfPsvKey->uModifiers & (_TF_MOD_ON_KEYUP_CONTROL_ONLY & 0xffff0000)) && !Global::IsControlKeyDownOnly) ||
            ((ptfPsvKey->uModifiers & (_TF_MOD_ON_KEYUP_ALT_ONLY & 0xffff0000)) && !Global::IsAltKeyDownOnly)         )
        {
            return FALSE;
        }
    }

    return TRUE;
}

//+---------------------------------------------------------------------------
//
// OnPreservedKey
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::OnPreservedKey(REFGUID rguid, _Out_ BOOL *pIsEaten, _In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId)
{
    if (IsEqualGUID(rguid, _PreservedKey_IMEMode.Guid))
    {
        if (!CheckShiftKeyOnly(&_PreservedKey_IMEMode.TSFPreservedKeyTable))
        {
            *pIsEaten = FALSE;
            return;
        }
        BOOL isOpen = FALSE;
        CCompartment CompartmentKeyboardOpen(pThreadMgr, tfClientId, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
        CompartmentKeyboardOpen._GetCompartmentBOOL(isOpen);
        CompartmentKeyboardOpen._SetCompartmentBOOL(isOpen ? FALSE : TRUE);

        *pIsEaten = TRUE;
    }
    else if (IsEqualGUID(rguid, _PreservedKey_DoubleSingleByte.Guid))
    {
        if (!CheckShiftKeyOnly(&_PreservedKey_DoubleSingleByte.TSFPreservedKeyTable))
        {
            *pIsEaten = FALSE;
            return;
        }
        BOOL isDouble = FALSE;
        CCompartment CompartmentDoubleSingleByte(pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentDoubleSingleByte);
        CompartmentDoubleSingleByte._GetCompartmentBOOL(isDouble);
        CompartmentDoubleSingleByte._SetCompartmentBOOL(isDouble ? FALSE : TRUE);
        *pIsEaten = TRUE;
    }
    else if (IsEqualGUID(rguid, _PreservedKey_Punctuation.Guid))
    {
        if (!CheckShiftKeyOnly(&_PreservedKey_Punctuation.TSFPreservedKeyTable))
        {
            *pIsEaten = FALSE;
            return;
        }
        BOOL isPunctuation = FALSE;
        CCompartment CompartmentPunctuation(pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentPunctuation);
        CompartmentPunctuation._GetCompartmentBOOL(isPunctuation);
        CompartmentPunctuation._SetCompartmentBOOL(isPunctuation ? FALSE : TRUE);
        *pIsEaten = TRUE;
    }
    else
    {
        *pIsEaten = FALSE;
    }
    *pIsEaten = TRUE;
}

//+---------------------------------------------------------------------------
//
// SetupConfiguration
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetupConfiguration()
{
    _isWildcard = TRUE;
    _isDisableWildcardAtFirst = TRUE;
    _hasMakePhraseFromText = TRUE;
    _isKeystrokeSort = TRUE;
    _candidateWndWidth = CAND_WIDTH;

    SetInitialCandidateListRange();

    SetDefaultCandidateTextFont();

    return;
}

//+---------------------------------------------------------------------------
//
// SetupLanguageBar
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetupLanguageBar(_In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId, BOOL isSecureMode)
{
    DWORD dwEnable = 1;
    CreateLanguageBarButton(dwEnable, GUID_LBI_INPUTMODE, Global::LangbarImeModeDescription, Global::ImeModeDescription, Global::ImeModeOnIcoIndex, Global::ImeModeOffIcoIndex, &_pLanguageBar_IMEMode, isSecureMode);
    CreateLanguageBarButton(dwEnable, Global::SampleIMEGuidLangBarDoubleSingleByte, Global::LangbarDoubleSingleByteDescription, Global::DoubleSingleByteDescription, Global::DoubleSingleByteOnIcoIndex, Global::DoubleSingleByteOffIcoIndex, &_pLanguageBar_DoubleSingleByte, isSecureMode);
    CreateLanguageBarButton(dwEnable, Global::SampleIMEGuidLangBarPunctuation, Global::LangbarPunctuationDescription, Global::PunctuationDescription, Global::PunctuationOnIcoIndex, Global::PunctuationOffIcoIndex, &_pLanguageBar_Punctuation, isSecureMode);

    InitLanguageBar(_pLanguageBar_IMEMode, pThreadMgr, tfClientId, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    InitLanguageBar(_pLanguageBar_DoubleSingleByte, pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentDoubleSingleByte);
    InitLanguageBar(_pLanguageBar_Punctuation, pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentPunctuation);

    _pCompartmentConversion = new (std::nothrow) CCompartment(pThreadMgr, tfClientId, GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION);
    _pCompartmentKeyboardOpenEventSink = new (std::nothrow) CCompartmentEventSink(CompartmentCallback, this);
    _pCompartmentConversionEventSink = new (std::nothrow) CCompartmentEventSink(CompartmentCallback, this);
    _pCompartmentDoubleSingleByteEventSink = new (std::nothrow) CCompartmentEventSink(CompartmentCallback, this);
    _pCompartmentPunctuationEventSink = new (std::nothrow) CCompartmentEventSink(CompartmentCallback, this);

    if (_pCompartmentKeyboardOpenEventSink)
    {
        _pCompartmentKeyboardOpenEventSink->_Advise(pThreadMgr, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    }
    if (_pCompartmentConversionEventSink)
    {
        _pCompartmentConversionEventSink->_Advise(pThreadMgr, GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION);
    }
    if (_pCompartmentDoubleSingleByteEventSink)
    {
        _pCompartmentDoubleSingleByteEventSink->_Advise(pThreadMgr, Global::SampleIMEGuidCompartmentDoubleSingleByte);
    }
    if (_pCompartmentPunctuationEventSink)
    {
        _pCompartmentPunctuationEventSink->_Advise(pThreadMgr, Global::SampleIMEGuidCompartmentPunctuation);
    }

    return;
}

//+---------------------------------------------------------------------------
//
// CreateLanguageBarButton
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::CreateLanguageBarButton(DWORD dwEnable, GUID guidLangBar, _In_z_ LPCWSTR pwszDescriptionValue, _In_z_ LPCWSTR pwszTooltipValue, DWORD dwOnIconIndex, DWORD dwOffIconIndex, _Outptr_result_maybenull_ CLangBarItemButton **ppLangBarItemButton, BOOL isSecureMode)
{
	dwEnable;

    if (ppLangBarItemButton)
    {
        *ppLangBarItemButton = new (std::nothrow) CLangBarItemButton(guidLangBar, pwszDescriptionValue, pwszTooltipValue, dwOnIconIndex, dwOffIconIndex, isSecureMode);
    }

    return;
}

//+---------------------------------------------------------------------------
//
// InitLanguageBar
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::InitLanguageBar(_In_ CLangBarItemButton *pLangBarItemButton, _In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId, REFGUID guidCompartment)
{
    if (pLangBarItemButton)
    {
        if (pLangBarItemButton->_AddItem(pThreadMgr) == S_OK)
        {
            if (pLangBarItemButton->_RegisterCompartment(pThreadMgr, tfClientId, guidCompartment))
            {
                return TRUE;
            }
        }
    }
    return FALSE;
}

//+---------------------------------------------------------------------------
//
// SetupPunctuationPair
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::SetupPunctuationPair()
{
    // [Ohagey] Empty, deliberately.
    //
    // The sample registered three substitutions that a Japanese IME must not
    // make:
    //
    //   " -> U+201C/U+201D and ' -> U+2018/U+2019, alternating open and close.
    //     Western typographic quotes. Anyone typing a quotation mark into code,
    //     a search box or a path wants the one on the key.
    //
    //   < and > -> U+300A/U+3008 and U+300B/U+3009, the Chinese book-title
    //     marks 《》 and 〈〉. Japanese uses 「」 for quotation, which is on the
    //     bracket keys in PunctuationTable, and needs the comparison operators
    //     to stay comparison operators.
    //
    // Both mechanisms are left in place — they are how a pairing IME would do
    // this — but Japanese has nothing to put in them. `IsPunctuation` iterates
    // empty arrays and falls through, so the keys reach the document unchanged.
}

void CCompositionProcessorEngine::InitializeSampleIMECompartment(_In_ ITfThreadMgr *pThreadMgr, TfClientId tfClientId)
{
	// set initial mode
    CCompartment CompartmentKeyboardOpen(pThreadMgr, tfClientId, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    CompartmentKeyboardOpen._SetCompartmentBOOL(TRUE);

    CCompartment CompartmentDoubleSingleByte(pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentDoubleSingleByte);
    CompartmentDoubleSingleByte._SetCompartmentBOOL(FALSE);

    CCompartment CompartmentPunctuation(pThreadMgr, tfClientId, Global::SampleIMEGuidCompartmentPunctuation);
    CompartmentPunctuation._SetCompartmentBOOL(TRUE);

    PrivateCompartmentsUpdated(pThreadMgr);
}
//+---------------------------------------------------------------------------
//
// CompartmentCallback
//
//----------------------------------------------------------------------------

// static
HRESULT CCompositionProcessorEngine::CompartmentCallback(_In_ void *pv, REFGUID guidCompartment)
{
    CCompositionProcessorEngine* fakeThis = (CCompositionProcessorEngine*)pv;
    if (nullptr == fakeThis)
    {
        return E_INVALIDARG;
    }

    ITfThreadMgr* pThreadMgr = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfThreadMgr, (void**)&pThreadMgr);
    if (FAILED(hr))
    {
        return E_FAIL;
    }

    if (IsEqualGUID(guidCompartment, Global::SampleIMEGuidCompartmentDoubleSingleByte) ||
        IsEqualGUID(guidCompartment, Global::SampleIMEGuidCompartmentPunctuation))
    {
        fakeThis->PrivateCompartmentsUpdated(pThreadMgr);
    }
    else if (IsEqualGUID(guidCompartment, GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION) ||
        IsEqualGUID(guidCompartment, GUID_COMPARTMENT_KEYBOARD_INPUTMODE_SENTENCE))
    {
        fakeThis->ConversionModeCompartmentUpdated(pThreadMgr);
    }
    else if (IsEqualGUID(guidCompartment, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE))
    {
        fakeThis->KeyboardOpenCompartmentUpdated(pThreadMgr);
    }

    pThreadMgr->Release();
    pThreadMgr = nullptr;

    return S_OK;
}

//+---------------------------------------------------------------------------
//
// UpdatePrivateCompartments
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::ConversionModeCompartmentUpdated(_In_ ITfThreadMgr *pThreadMgr)
{
    if (!_pCompartmentConversion)
    {
        return;
    }

    DWORD conversionMode = 0;
    if (FAILED(_pCompartmentConversion->_GetCompartmentDWORD(conversionMode)))
    {
        return;
    }

    BOOL isDouble = FALSE;
    CCompartment CompartmentDoubleSingleByte(pThreadMgr, _tfClientId, Global::SampleIMEGuidCompartmentDoubleSingleByte);
    if (SUCCEEDED(CompartmentDoubleSingleByte._GetCompartmentBOOL(isDouble)))
    {
        if (!isDouble && (conversionMode & TF_CONVERSIONMODE_FULLSHAPE))
        {
            CompartmentDoubleSingleByte._SetCompartmentBOOL(TRUE);
        }
        else if (isDouble && !(conversionMode & TF_CONVERSIONMODE_FULLSHAPE))
        {
            CompartmentDoubleSingleByte._SetCompartmentBOOL(FALSE);
        }
    }
    BOOL isPunctuation = FALSE;
    CCompartment CompartmentPunctuation(pThreadMgr, _tfClientId, Global::SampleIMEGuidCompartmentPunctuation);
    if (SUCCEEDED(CompartmentPunctuation._GetCompartmentBOOL(isPunctuation)))
    {
        if (!isPunctuation && (conversionMode & TF_CONVERSIONMODE_SYMBOL))
        {
            CompartmentPunctuation._SetCompartmentBOOL(TRUE);
        }
        else if (isPunctuation && !(conversionMode & TF_CONVERSIONMODE_SYMBOL))
        {
            CompartmentPunctuation._SetCompartmentBOOL(FALSE);
        }
    }

    BOOL fOpen = FALSE;
    CCompartment CompartmentKeyboardOpen(pThreadMgr, _tfClientId, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    if (SUCCEEDED(CompartmentKeyboardOpen._GetCompartmentBOOL(fOpen)))
    {
        if (fOpen && !(conversionMode & TF_CONVERSIONMODE_NATIVE))
        {
            CompartmentKeyboardOpen._SetCompartmentBOOL(FALSE);
        }
        else if (!fOpen && (conversionMode & TF_CONVERSIONMODE_NATIVE))
        {
            CompartmentKeyboardOpen._SetCompartmentBOOL(TRUE);
        }
    }
}

//+---------------------------------------------------------------------------
//
// PrivateCompartmentsUpdated()
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::PrivateCompartmentsUpdated(_In_ ITfThreadMgr *pThreadMgr)
{
    if (!_pCompartmentConversion)
    {
        return;
    }

    DWORD conversionMode = 0;
    DWORD conversionModePrev = 0;
    if (FAILED(_pCompartmentConversion->_GetCompartmentDWORD(conversionMode)))
    {
        return;
    }

    conversionModePrev = conversionMode;

    BOOL isDouble = FALSE;
    CCompartment CompartmentDoubleSingleByte(pThreadMgr, _tfClientId, Global::SampleIMEGuidCompartmentDoubleSingleByte);
    if (SUCCEEDED(CompartmentDoubleSingleByte._GetCompartmentBOOL(isDouble)))
    {
        if (!isDouble && (conversionMode & TF_CONVERSIONMODE_FULLSHAPE))
        {
            conversionMode &= ~TF_CONVERSIONMODE_FULLSHAPE;
        }
        else if (isDouble && !(conversionMode & TF_CONVERSIONMODE_FULLSHAPE))
        {
            conversionMode |= TF_CONVERSIONMODE_FULLSHAPE;
        }
    }

    BOOL isPunctuation = FALSE;
    CCompartment CompartmentPunctuation(pThreadMgr, _tfClientId, Global::SampleIMEGuidCompartmentPunctuation);
    if (SUCCEEDED(CompartmentPunctuation._GetCompartmentBOOL(isPunctuation)))
    {
        if (!isPunctuation && (conversionMode & TF_CONVERSIONMODE_SYMBOL))
        {
            conversionMode &= ~TF_CONVERSIONMODE_SYMBOL;
        }
        else if (isPunctuation && !(conversionMode & TF_CONVERSIONMODE_SYMBOL))
        {
            conversionMode |= TF_CONVERSIONMODE_SYMBOL;
        }
    }

    if (conversionMode != conversionModePrev)
    {
        _pCompartmentConversion->_SetCompartmentDWORD(conversionMode);
    }
}

//+---------------------------------------------------------------------------
//
// KeyboardOpenCompartmentUpdated
//
//----------------------------------------------------------------------------

void CCompositionProcessorEngine::KeyboardOpenCompartmentUpdated(_In_ ITfThreadMgr *pThreadMgr)
{
    if (!_pCompartmentConversion)
    {
        return;
    }

    DWORD conversionMode = 0;
    DWORD conversionModePrev = 0;
    if (FAILED(_pCompartmentConversion->_GetCompartmentDWORD(conversionMode)))
    {
        return;
    }

    conversionModePrev = conversionMode;

    BOOL isOpen = FALSE;
    CCompartment CompartmentKeyboardOpen(pThreadMgr, _tfClientId, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    if (SUCCEEDED(CompartmentKeyboardOpen._GetCompartmentBOOL(isOpen)))
    {
        if (isOpen && !(conversionMode & TF_CONVERSIONMODE_NATIVE))
        {
            conversionMode |= TF_CONVERSIONMODE_NATIVE;
        }
        else if (!isOpen && (conversionMode & TF_CONVERSIONMODE_NATIVE))
        {
            conversionMode &= ~TF_CONVERSIONMODE_NATIVE;
        }
    }

    if (conversionMode != conversionModePrev)
    {
        _pCompartmentConversion->_SetCompartmentDWORD(conversionMode);
    }
}


//////////////////////////////////////////////////////////////////////
//
// XPreservedKey implementation.
//
//////////////////////////////////////////////////////////////////////

//+---------------------------------------------------------------------------
//
// UninitPreservedKey
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::XPreservedKey::UninitPreservedKey(_In_ ITfThreadMgr *pThreadMgr)
{
    ITfKeystrokeMgr* pKeystrokeMgr = nullptr;

    if (IsEqualGUID(Guid, GUID_NULL))
    {
        return FALSE;
    }

    if (FAILED(pThreadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void **)&pKeystrokeMgr)))
    {
        return FALSE;
    }

    for (UINT i = 0; i < TSFPreservedKeyTable.Count(); i++)
    {
        TF_PRESERVEDKEY pPreservedKey = *TSFPreservedKeyTable.GetAt(i);
        pPreservedKey.uModifiers &= 0xffff;

        pKeystrokeMgr->UnpreserveKey(Guid, &pPreservedKey);
    }

    pKeystrokeMgr->Release();

    return TRUE;
}

CCompositionProcessorEngine::XPreservedKey::XPreservedKey()
{
    Guid = GUID_NULL;
    Description = nullptr;
}

CCompositionProcessorEngine::XPreservedKey::~XPreservedKey()
{
    ITfThreadMgr* pThreadMgr = nullptr;

    HRESULT hr = CoCreateInstance(CLSID_TF_ThreadMgr, NULL, CLSCTX_INPROC_SERVER, IID_ITfThreadMgr, (void**)&pThreadMgr);
    if (SUCCEEDED(hr))
    {
        UninitPreservedKey(pThreadMgr);
        pThreadMgr->Release();
        pThreadMgr = nullptr;
    }

    if (Description)
    {
        delete [] Description;
    }
}
//+---------------------------------------------------------------------------
//
// CSampleIME::CreateInstance 
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::CreateInstance(REFCLSID rclsid, REFIID riid, _Outptr_result_maybenull_ LPVOID* ppv, _Out_opt_ HINSTANCE* phInst, BOOL isComLessMode)
{
    HRESULT hr = S_OK;
    if (phInst == nullptr)
    {
        return E_INVALIDARG;
    }

    *phInst = nullptr;

    if (!isComLessMode)
    {
        hr = ::CoCreateInstance(rclsid, 
            NULL, 
            CLSCTX_INPROC_SERVER,
            riid,
            ppv);
    }
    else
    {
        hr = CSampleIME::ComLessCreateInstance(rclsid, riid, ppv, phInst);
    }

    return hr;
}

//+---------------------------------------------------------------------------
//
// CSampleIME::ComLessCreateInstance
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::ComLessCreateInstance(REFGUID rclsid, REFIID riid, _Outptr_result_maybenull_ void **ppv, _Out_opt_ HINSTANCE *phInst)
{
    HRESULT hr = S_OK;
    HINSTANCE sampleIMEDllHandle = nullptr;
    WCHAR wchPath[MAX_PATH] = {'\0'};
    WCHAR szExpandedPath[MAX_PATH] = {'\0'};
    DWORD dwCnt = 0;
    *ppv = nullptr;

    hr = phInst ? S_OK : E_FAIL;
    if (SUCCEEDED(hr))
    {
        *phInst = nullptr;
        hr = CSampleIME::GetComModuleName(rclsid, wchPath, ARRAYSIZE(wchPath));
        if (SUCCEEDED(hr))
        {
            dwCnt = ExpandEnvironmentStringsW(wchPath, szExpandedPath, ARRAYSIZE(szExpandedPath));
            hr = (0 < dwCnt && dwCnt <= ARRAYSIZE(szExpandedPath)) ? S_OK : E_FAIL;
            if (SUCCEEDED(hr))
            {
                sampleIMEDllHandle = LoadLibraryEx(szExpandedPath, NULL, 0);
                hr = sampleIMEDllHandle ? S_OK : E_FAIL;
                if (SUCCEEDED(hr))
                {
                    *phInst = sampleIMEDllHandle;
                    FARPROC pfn = GetProcAddress(sampleIMEDllHandle, "DllGetClassObject");
                    hr = pfn ? S_OK : E_FAIL;
                    if (SUCCEEDED(hr))
                    {
                        IClassFactory *pClassFactory = nullptr;
                        hr = ((HRESULT (STDAPICALLTYPE *)(REFCLSID rclsid, REFIID riid, LPVOID *ppv))(pfn))(rclsid, IID_IClassFactory, (void **)&pClassFactory);
                        if (SUCCEEDED(hr) && pClassFactory)
                        {
                            hr = pClassFactory->CreateInstance(NULL, riid, ppv);
                            pClassFactory->Release();
                        }
                    }
                }
            }
        }
    }

    if (!SUCCEEDED(hr) && phInst && *phInst)
    {
        FreeLibrary(*phInst);
        *phInst = 0;
    }
    return hr;
}

//+---------------------------------------------------------------------------
//
// CSampleIME::GetComModuleName
//
//----------------------------------------------------------------------------

HRESULT CSampleIME::GetComModuleName(REFGUID rclsid, _Out_writes_(cchPath)WCHAR* wchPath, DWORD cchPath)
{
    HRESULT hr = S_OK;

    CRegKey key;
    WCHAR wchClsid[CLSID_STRLEN + 1];
    hr = CLSIDToString(rclsid, wchClsid) ? S_OK : E_FAIL;
    if (SUCCEEDED(hr))
    {
        WCHAR wchKey[MAX_PATH];
        hr = StringCchPrintfW(wchKey, ARRAYSIZE(wchKey), L"CLSID\\%s\\InProcServer32", wchClsid);
        if (SUCCEEDED(hr))
        {
            hr = (key.Open(HKEY_CLASSES_ROOT, wchKey, KEY_READ) == ERROR_SUCCESS) ? S_OK : E_FAIL;
            if (SUCCEEDED(hr))
            {
                WCHAR wszModel[MAX_PATH];
                ULONG cch = ARRAYSIZE(wszModel);
                hr = (key.QueryStringValue(L"ThreadingModel", wszModel, &cch) == ERROR_SUCCESS) ? S_OK : E_FAIL;
                if (SUCCEEDED(hr))
                {
                    if (CompareStringOrdinal(wszModel, 
                        -1, 
                        L"Apartment", 
                        -1,
                        TRUE) == CSTR_EQUAL)
                    {
                        hr = (key.QueryStringValue(NULL, wchPath, &cchPath) == ERROR_SUCCESS) ? S_OK : E_FAIL;
                    }
                    else
                    {
                        hr = E_FAIL;
                    }
                }
            }
        }
    }

    return hr;
}

void CCompositionProcessorEngine::InitKeyStrokeTable()
{
    for (int i = 0; i < 26; i++)
    {
        _keystrokeTable[i].VirtualKey = 'A' + i;
        _keystrokeTable[i].Modifiers = 0;
        _keystrokeTable[i].Function = FUNCTION_INPUT;
    }

    // [Ohagey] The long-vowel key, which the sample had no use for.
    //
    // A pinyin IME needs the 26 letters and nothing else. Japanese needs one
    // more: the reading of コーヒー or データ contains ー, and it is typed with
    // the minus key. Without this entry the key never reaches the reading
    // buffer -- it falls through to the punctuation path, which settles the
    // composition and inserts a character beside it, so those words cannot be
    // typed at all.
    //
    // RomajiToKana has mapped '-' to ー from the start; nothing fed it.
    _keystrokeTable[26].VirtualKey = VK_OEM_MINUS;
    _keystrokeTable[26].Modifiers = 0;
    _keystrokeTable[26].Function = FUNCTION_INPUT;
}

void CCompositionProcessorEngine::ShowAllLanguageBarIcons()
{
    SetLanguageBarStatus(TF_LBI_STATUS_HIDDEN, FALSE);
}

void CCompositionProcessorEngine::HideAllLanguageBarIcons()
{
    SetLanguageBarStatus(TF_LBI_STATUS_HIDDEN, TRUE);
}

void CCompositionProcessorEngine::SetInitialCandidateListRange()
{
    for (DWORD i = 1; i <= 10; i++)
    {
        DWORD* pNewIndexRange = nullptr;

        pNewIndexRange = _candidateListIndexRange.Append();
        if (pNewIndexRange != nullptr)
        {
            if (i != 10)
            {
                *pNewIndexRange = i;
            }
            else
            {
                *pNewIndexRange = 0;
            }
        }
    }
}

void CCompositionProcessorEngine::SetDefaultCandidateTextFont()
{
    // Candidate Text Font
    if (Global::defaultlFontHandle == nullptr)
    {
		WCHAR fontName[50] = {'\0'}; 
		LoadString(Global::dllInstanceHandle, IDS_DEFAULT_FONT, fontName, 50);
        Global::defaultlFontHandle = CreateFont(-MulDiv(10, GetDeviceCaps(GetDC(NULL), LOGPIXELSY), 72), 0, 0, 0, FW_MEDIUM, 0, 0, 0, 0, 0, 0, 0, 0, fontName);
        if (!Global::defaultlFontHandle)
        {
			LOGFONT lf;
			SystemParametersInfo(SPI_GETICONTITLELOGFONT, sizeof(LOGFONT), &lf, 0);
            // Fall back to the default GUI font on failure.
            Global::defaultlFontHandle = CreateFont(-MulDiv(10, GetDeviceCaps(GetDC(NULL), LOGPIXELSY), 72), 0, 0, 0, FW_MEDIUM, 0, 0, 0, 0, 0, 0, 0, 0, lf.lfFaceName);
        }
    }
}

//////////////////////////////////////////////////////////////////////
//
//    CCompositionProcessorEngine
//
//////////////////////////////////////////////////////////////////////

//+---------------------------------------------------------------------------
//
// CCompositionProcessorEngine::IsVirtualKeyNeed
//
// Test virtual key code need to the Composition Processor Engine.
// param
//     [in] uCode - Specify virtual key code.
//     [in/out] pwch       - char code
//     [in] fComposing     - Specified composing.
//     [in] fCandidateMode - Specified candidate mode.
//     [out] pKeyState     - Returns function regarding virtual key.
// returns
//     If engine need this virtual key code, returns true. Otherwise returns false.
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsVirtualKeyNeed(UINT uCode, _In_reads_(1) WCHAR *pwch, BOOL fComposing, CANDIDATE_MODE candidateMode, BOOL hasCandidateWithWildcard, _Out_opt_ _KEYSTROKE_STATE *pKeyState)
{
    if (pKeyState)
    {
        pKeyState->Category = CATEGORY_NONE;
        pKeyState->Function = FUNCTION_NONE;
    }

    if (candidateMode == CANDIDATE_ORIGINAL || candidateMode == CANDIDATE_PHRASE || candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION)
    {
        fComposing = FALSE;
    }

    if (fComposing || candidateMode == CANDIDATE_INCREMENTAL || candidateMode == CANDIDATE_NONE)
    {
        if (IsVirtualKeyKeystrokeComposition(uCode, pKeyState, FUNCTION_NONE))
        {
            return TRUE;
        }
        else if ((IsWildcard() && IsWildcardChar(*pwch) && !IsDisableWildcardAtFirst()) ||
            (IsWildcard() && IsWildcardChar(*pwch) &&  IsDisableWildcardAtFirst() && _keystrokeBuffer.GetLength()))
        {
            if (pKeyState)
            {
                pKeyState->Category = CATEGORY_COMPOSING;
                pKeyState->Function = FUNCTION_INPUT;
            }
            return TRUE;
        }
        else if (_hasWildcardIncludedInKeystrokeBuffer && uCode == VK_SPACE)
        {
            if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_CONVERT_WILDCARD; } return TRUE;
        }
    }

    if (candidateMode == CANDIDATE_ORIGINAL || candidateMode == CANDIDATE_PHRASE || candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION)
    {
        BOOL isRetCode = TRUE;
        if (IsVirtualKeyKeystrokeCandidate(uCode, pKeyState, candidateMode, &isRetCode, &_KeystrokeCandidate))
        {
            return isRetCode;
        }

        if (hasCandidateWithWildcard)
        {
            if (IsVirtualKeyKeystrokeCandidate(uCode, pKeyState, candidateMode, &isRetCode, &_KeystrokeCandidateWildcard))
            {
                return isRetCode;
            }
        }

        // Candidate list could not handle key. We can try to restart the composition.
        if (IsVirtualKeyKeystrokeComposition(uCode, pKeyState, FUNCTION_INPUT))
        {
            if (candidateMode != CANDIDATE_ORIGINAL)
            {
                return TRUE;
            }
            else
            {
                if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_FINALIZE_CANDIDATELIST_AND_INPUT; } 
                return TRUE;
            }
        }
    } 

    // CANDIDATE_INCREMENTAL should process Keystroke.Candidate virtual keys.
    else if (candidateMode == CANDIDATE_INCREMENTAL)
    {
        BOOL isRetCode = TRUE;
        if (IsVirtualKeyKeystrokeCandidate(uCode, pKeyState, candidateMode, &isRetCode, &_KeystrokeCandidate))
        {
            return isRetCode;
        }
    }

    if (!fComposing && candidateMode != CANDIDATE_ORIGINAL && candidateMode != CANDIDATE_PHRASE && candidateMode != CANDIDATE_WITH_NEXT_COMPOSITION) 
    {
        if (IsVirtualKeyKeystrokeComposition(uCode, pKeyState, FUNCTION_INPUT))
        {
            return TRUE;
        }
    }

    // System pre-defined keystroke
    if (fComposing)
    {
        if ((candidateMode != CANDIDATE_INCREMENTAL))
        {
            switch (uCode)
            {
            case VK_LEFT:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_LEFT; } return TRUE;
            case VK_RIGHT:  if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_RIGHT; } return TRUE;
            case VK_RETURN: if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_FINALIZE_CANDIDATELIST; } return TRUE;
            case VK_ESCAPE: if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_CANCEL; } return TRUE;
            case VK_BACK:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_BACKSPACE; } return TRUE;

            case VK_UP:     if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_UP; } return TRUE;
            case VK_DOWN:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_DOWN; } return TRUE;
            case VK_PRIOR:  if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_PAGE_UP; } return TRUE;
            case VK_NEXT:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_PAGE_DOWN; } return TRUE;

            case VK_HOME:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_PAGE_TOP; } return TRUE;
            case VK_END:    if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_MOVE_PAGE_BOTTOM; } return TRUE;

            case VK_SPACE:  if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_CONVERT; } return TRUE;
            }
        }
        else if ((candidateMode == CANDIDATE_INCREMENTAL))
        {
            switch (uCode)
            {
                // VK_LEFT, VK_RIGHT - set *pIsEaten = FALSE for application could move caret left or right.
                // and for CUAS, invoke _HandleCompositionCancel() edit session due to ignore CUAS default key handler for send out terminate composition
            case VK_LEFT:
            case VK_RIGHT:
                {
                    if (pKeyState)
                    {
                        pKeyState->Category = CATEGORY_INVOKE_COMPOSITION_EDIT_SESSION;
                        pKeyState->Function = FUNCTION_CANCEL;
                    }
                }
                return FALSE;

            case VK_RETURN: if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_FINALIZE_CANDIDATELIST; } return TRUE;
            case VK_ESCAPE: if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_CANCEL; } return TRUE;

                // VK_BACK - remove one char from reading string.
            case VK_BACK:   if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_BACKSPACE; } return TRUE;

            case VK_UP:     if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_UP; } return TRUE;
            case VK_DOWN:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_DOWN; } return TRUE;
            case VK_PRIOR:  if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_UP; } return TRUE;
            case VK_NEXT:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_DOWN; } return TRUE;

            case VK_HOME:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_TOP; } return TRUE;
            case VK_END:    if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_BOTTOM; } return TRUE;

            case VK_SPACE:
                {
                    if (candidateMode == CANDIDATE_INCREMENTAL)
                    {
                        if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_CONVERT; } return TRUE;
                    }
                    else
                    {
                        if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_CONVERT; } return TRUE;
                    }
                }
            }
        }
    }

    if ((candidateMode == CANDIDATE_ORIGINAL) || (candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION))
    {
        switch (uCode)
        {
        case VK_UP:     if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_UP; } return TRUE;
        case VK_DOWN:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_DOWN; } return TRUE;
        case VK_PRIOR:  if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_UP; } return TRUE;
        case VK_NEXT:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_DOWN; } return TRUE;
        case VK_HOME:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_TOP; } return TRUE;
        case VK_END:    if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_MOVE_PAGE_BOTTOM; } return TRUE;
        case VK_RETURN: if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_FINALIZE_CANDIDATELIST; } return TRUE;
        case VK_SPACE:  if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_CONVERT; } return TRUE;
        case VK_BACK:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_CANCEL; } return TRUE;

        case VK_ESCAPE:
            {
                if (candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION)
                {
                    if (pKeyState)
                    {
                        pKeyState->Category = CATEGORY_INVOKE_COMPOSITION_EDIT_SESSION;
                        pKeyState->Function = FUNCTION_FINALIZE_TEXTSTORE;
                    }
                    return TRUE;
                }
                else
                {
                    if (pKeyState)
                    {
                        pKeyState->Category = CATEGORY_CANDIDATE;
                        pKeyState->Function = FUNCTION_CANCEL;
                    }
                    return TRUE;
                }
            }
        }

        if (candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION)
        {
            if (IsVirtualKeyKeystrokeComposition(uCode, NULL, FUNCTION_NONE))
            {
                if (pKeyState) { pKeyState->Category = CATEGORY_COMPOSING; pKeyState->Function = FUNCTION_FINALIZE_TEXTSTORE_AND_INPUT; } return TRUE;
            }
        }
    }

    if (candidateMode == CANDIDATE_PHRASE)
    {
        switch (uCode)
        {
        case VK_UP:     if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_UP; } return TRUE;
        case VK_DOWN:   if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_DOWN; } return TRUE;
        case VK_PRIOR:  if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_PAGE_UP; } return TRUE;
        case VK_NEXT:   if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_PAGE_DOWN; } return TRUE;
        case VK_HOME:   if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_PAGE_TOP; } return TRUE;
        case VK_END:    if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_MOVE_PAGE_BOTTOM; } return TRUE;
        case VK_RETURN: if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_FINALIZE_CANDIDATELIST; } return TRUE;
        case VK_SPACE:  if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_CONVERT; } return TRUE;
        case VK_ESCAPE: if (pKeyState) { pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_CANCEL; } return TRUE;
        case VK_BACK:   if (pKeyState) { pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_CANCEL; } return TRUE;
        }
    }

    if (IsKeystrokeRange(uCode, pKeyState, candidateMode))
    {
        return TRUE;
    }
    else if (pKeyState && pKeyState->Category != CATEGORY_NONE)
    {
        return FALSE;
    }

    if (*pwch && !IsVirtualKeyKeystrokeComposition(uCode, pKeyState, FUNCTION_NONE))
    {
        if (pKeyState)
        {
            pKeyState->Category = CATEGORY_INVOKE_COMPOSITION_EDIT_SESSION;
            pKeyState->Function = FUNCTION_FINALIZE_TEXTSTORE;
        }
        return FALSE;
    }

    return FALSE;
}

//+---------------------------------------------------------------------------
//
// CCompositionProcessorEngine::IsVirtualKeyKeystrokeComposition
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsVirtualKeyKeystrokeComposition(UINT uCode, _Out_opt_ _KEYSTROKE_STATE *pKeyState, KEYSTROKE_FUNCTION function)
{
    if (pKeyState == nullptr)
    {
        return FALSE;
    }

    pKeyState->Category = CATEGORY_NONE;
    pKeyState->Function = FUNCTION_NONE;

    for (UINT i = 0; i < _KeystrokeComposition.Count(); i++)
    {
        _KEYSTROKE *pKeystroke = nullptr;

        pKeystroke = _KeystrokeComposition.GetAt(i);

        if ((pKeystroke->VirtualKey == uCode) && Global::CheckModifiers(Global::ModifiersValue, pKeystroke->Modifiers))
        {
            if (function == FUNCTION_NONE)
            {
                pKeyState->Category = CATEGORY_COMPOSING;
                pKeyState->Function = pKeystroke->Function;
                return TRUE;
            }
            else if (function == pKeystroke->Function)
            {
                pKeyState->Category = CATEGORY_COMPOSING;
                pKeyState->Function = pKeystroke->Function;
                return TRUE;
            }
        }
    }

    return FALSE;
}

//+---------------------------------------------------------------------------
//
// CCompositionProcessorEngine::IsVirtualKeyKeystrokeCandidate
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsVirtualKeyKeystrokeCandidate(UINT uCode, _In_ _KEYSTROKE_STATE *pKeyState, CANDIDATE_MODE candidateMode, _Out_ BOOL *pfRetCode, _In_ CSampleImeArray<_KEYSTROKE> *pKeystrokeMetric)
{
    if (pfRetCode == nullptr)
    {
        return FALSE;
    }
    *pfRetCode = FALSE;

    for (UINT i = 0; i < pKeystrokeMetric->Count(); i++)
    {
        _KEYSTROKE *pKeystroke = nullptr;

        pKeystroke = pKeystrokeMetric->GetAt(i);

        if ((pKeystroke->VirtualKey == uCode) && Global::CheckModifiers(Global::ModifiersValue, pKeystroke->Modifiers))
        {
            *pfRetCode = TRUE;
            if (pKeyState)
            {
                pKeyState->Category = (candidateMode == CANDIDATE_ORIGINAL ? CATEGORY_CANDIDATE :
                    candidateMode == CANDIDATE_PHRASE ? CATEGORY_PHRASE : CATEGORY_CANDIDATE);

                pKeyState->Function = pKeystroke->Function;
            }
            return TRUE;
        }
    }

    return FALSE;
}

//+---------------------------------------------------------------------------
//
// CCompositionProcessorEngine::IsKeyKeystrokeRange
//
//----------------------------------------------------------------------------

BOOL CCompositionProcessorEngine::IsKeystrokeRange(UINT uCode, _Out_ _KEYSTROKE_STATE *pKeyState, CANDIDATE_MODE candidateMode)
{
    if (pKeyState == nullptr)
    {
        return FALSE;
    }

    pKeyState->Category = CATEGORY_NONE;
    pKeyState->Function = FUNCTION_NONE;

    if (_candidateListIndexRange.IsRange(uCode))
    {
        if (candidateMode == CANDIDATE_PHRASE)
        {
            // Candidate phrase could specify modifier
            if ((GetCandidateListPhraseModifier() == 0 && Global::ModifiersValue == 0) ||
                (GetCandidateListPhraseModifier() != 0 && Global::CheckModifiers(Global::ModifiersValue, GetCandidateListPhraseModifier())))
            {
                pKeyState->Category = CATEGORY_PHRASE; pKeyState->Function = FUNCTION_SELECT_BY_NUMBER;
                return TRUE;
            }
            else
            {
                pKeyState->Category = CATEGORY_INVOKE_COMPOSITION_EDIT_SESSION; pKeyState->Function = FUNCTION_FINALIZE_TEXTSTORE_AND_INPUT;
                return FALSE;
            }
        }
        else if (candidateMode == CANDIDATE_WITH_NEXT_COMPOSITION)
        {
            // Candidate phrase could specify modifier
            if ((GetCandidateListPhraseModifier() == 0 && Global::ModifiersValue == 0) ||
                (GetCandidateListPhraseModifier() != 0 && Global::CheckModifiers(Global::ModifiersValue, GetCandidateListPhraseModifier())))
            {
                pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_SELECT_BY_NUMBER;
                return TRUE;
            }
            // else next composition
        }
        else if (candidateMode != CANDIDATE_NONE)
        {
            pKeyState->Category = CATEGORY_CANDIDATE; pKeyState->Function = FUNCTION_SELECT_BY_NUMBER;
            return TRUE;
        }
    }
    return FALSE;
}