// Romaji -> kana input conversion.
//
// The engine converts *readings*, and expects hiragana: ConversionService feeds
// the converter with `.direct` input, which means "the TSF layer has already
// resolved romaji to kana". Nothing in the vendored SampleIME did that — its
// keystroke buffer held ASCII for Chinese Pinyin — so this fills the gap.
//
// Deliberately free of Windows and of TSF so it can be tested on its own; the
// interesting behaviour here is all in the edge cases (sokuon, trailing n,
// the several spellings of the same kana) and those deserve tests rather than
// a careful read.

#pragma once

#include <string>

namespace Ohagey
{
    // Accumulates keystrokes and produces kana.
    //
    // Input arrives one character at a time because that is how an IME sees it,
    // and because most of the difficulty is in what to do while a syllable is
    // still incomplete: after `k` there is no kana yet, after `ky` still none,
    // and after `n` there is one only if what follows says so.
    class RomajiKana
    {
    public:
        // Feeds one keystroke. Returns false if the character is not something
        // this converter handles, in which case nothing was consumed.
        bool Append(wchar_t ch);

        // Removes the last keystroke's worth of input.
        //
        // Backs out one *character of romaji*, not one kana: someone who typed
        // `kyo` and hits backspace expects to be editing `kyo`, not to lose the
        // whole syllable. The kana is recomputed from what is left.
        void Backspace();

        void Clear();

        bool IsEmpty() const { return _romaji.empty(); }

        // The romaji typed so far, as typed.
        const std::wstring& Romaji() const { return _romaji; }

        // Kana for every syllable that has resolved.
        const std::wstring& Kana() const { return _kana; }

        // Romaji that has not resolved into kana yet (`k`, `ky`, a lone `n`).
        const std::wstring& Pending() const { return _pending; }

        // What to send the engine as the reading.
        //
        // This is `Kana()` plus one special case: a trailing lone `n`, which
        // becomes ん. Someone who typed `hon` means ほん, and refusing to convert
        // until they type another `n` would be a strange IME. Any other pending
        // romaji is dropped — `ky` is not a reading, and sending it would ask
        // the engine to convert letters.
        std::wstring Reading() const;

        // Kana plus unresolved romaji, which is what the user should see in the
        // composition while typing.
        std::wstring Display() const { return _kana + _pending; }

    private:
        // Rebuilds _kana and _pending from _romaji. Used by Backspace, where
        // undoing the effect of one character in place is far more error-prone
        // than replaying the input.
        void Rebuild();

        std::wstring _romaji;
        std::wstring _kana;
        std::wstring _pending;
    };

    // Converts a whole romaji string in one go. Same rules as feeding it
    // character by character.
    std::wstring RomajiToKana(const std::wstring& romaji);
}
