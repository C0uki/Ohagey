// THIS CODE AND INFORMATION IS PROVIDED "AS IS" WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
// PARTICULAR PURPOSE.
//
// Copyright (c) Microsoft Corporation. All rights reserved

#pragma once
#include "resource.h"

#define TEXTSERVICE_MODEL        L"Apartment"
// Japanese, not the Simplified Chinese the sample registered under.
//
// This is what Windows files the input method under. Left as it came, the
// installer registers a *Chinese* IME called "Sample IME": everything builds,
// regsvr32 succeeds, the CLSID appears in the registry, and it never shows up
// in the Japanese input methods because it was never offered to them. Nothing
// reports an error at any point (decision 0021).
#define TEXTSERVICE_LANGID       MAKELANGID(LANG_JAPANESE, SUBLANG_JAPANESE_JAPAN)
#define TEXTSERVICE_ICON_INDEX   -IDIS_SAMPLEIME

#define IME_MODE_ON_ICON_INDEX      IDI_IME_MODE_ON
#define IME_MODE_OFF_ICON_INDEX     IDI_IME_MODE_OFF
#define IME_MODE_ON_DARK_ICON_INDEX  IDI_IME_MODE_ON_DARK
#define IME_MODE_OFF_DARK_ICON_INDEX IDI_IME_MODE_OFF_DARK
#define IME_DOUBLE_ON_INDEX         IDI_DOUBLE_SINGLE_BYTE_ON
#define IME_DOUBLE_OFF_INDEX        IDI_DOUBLE_SINGLE_BYTE_OFF
#define IME_PUNCTUATION_ON_INDEX    IDI_PUNCTUATION_ON
#define IME_PUNCTUATION_OFF_INDEX   IDI_PUNCTUATION_OFF

// The candidate window font. IDS_DEFAULT_FONT in SampleIME.rc is the copy
// actually loaded; this one is unreferenced and kept only so the two do not
// disagree.
//
// Left as it came, candidates are drawn in a Simplified Chinese face. That is
// not cosmetic: CJK codepoints are unified, so the same kanji has a different
// regional shape and Japanese text renders subtly wrong. CreateFont never
// reports it -- asking for a face that is wrong for the text still succeeds.
#define SAMPLEIME_FONT_DEFAULT L"Yu Gothic UI"

//---------------------------------------------------------------------
// defined Candidated Window
//---------------------------------------------------------------------
#define CANDWND_ROW_WIDTH				(30)
#define CANDWND_BORDER_COLOR			(RGB(0x00, 0x00, 0x00))
#define CANDWND_BORDER_WIDTH			(2)
#define CANDWND_NUM_COLOR				(RGB(0xB4, 0xB4, 0xB4))
#define CANDWND_SELECTED_ITEM_COLOR		(RGB(0xFF, 0xFF, 0xFF))
#define CANDWND_SELECTED_BK_COLOR		(RGB(0xA6, 0xA6, 0x00))
#define CANDWND_ITEM_COLOR				(RGB(0x00, 0x00, 0x00))

//---------------------------------------------------------------------
// defined modifier
//---------------------------------------------------------------------
#define _TF_MOD_ON_KEYUP_SHIFT_ONLY    (0x00010000 | TF_MOD_ON_KEYUP)
#define _TF_MOD_ON_KEYUP_CONTROL_ONLY  (0x00020000 | TF_MOD_ON_KEYUP)
#define _TF_MOD_ON_KEYUP_ALT_ONLY      (0x00040000 | TF_MOD_ON_KEYUP)

#define CAND_WIDTH     (13)      // * tmMaxCharWidth

//---------------------------------------------------------------------
// string length of CLSID
//---------------------------------------------------------------------
#define CLSID_STRLEN    (38)  // strlen("{xxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx}")