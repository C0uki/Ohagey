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

        // What the user should see in the composition while typing: kana, plus
        // any romaji still mid-syllable.
        //
        // A trailing lone `n` shows as ん, the same as `Reading()` converts it.
        // Someone typing `hon` expects to see ほん, not ほn — and if they go on
        // to type `a` it becomes ほな, which is exactly what recomputing from
        // the romaji gives.
        std::wstring Display() const;

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
    //
    // Returns the *reading*: resolved kana, with a trailing lone `n` closed to
    // ん. Anything else still mid-syllable is dropped, because `ky` is not a
    // reading and the engine has nothing to do with it.
    std::wstring RomajiToKana(const std::wstring& romaji);

    // What to show in the composition while typing: resolved kana followed by
    // whatever romaji has not resolved yet.
    //
    // Differs from `RomajiToKana` on purpose. The reading is what the engine is
    // asked to convert; this is what the user is looking at, and someone who
    // has typed `ky` needs to see that they typed it.
    std::wstring RomajiToDisplay(const std::wstring& romaji);

    // How much romaji to keep when backspace deletes one **kana**.
    //
    // Backspace removes one character of what the user is looking at, which is
    // `RomajiToDisplay` — not one keystroke. Those are the same thing in a
    // pinyin IME and different in a Japanese one:
    //
    //     おはぎ  (ohagi)  -> one keystroke -> おはg   the reported bug
    //                      -> one kana     -> おは
    //
    // Computed by shortening the romaji until the display shortens, rather
    // than by a reverse table: `ohagi` -> `ohag` still displays three
    // characters, because an unresolved consonant shows as itself. Counting
    // keystrokes cannot see that; counting the result can.
    //
    // ⚠️ A syllable with no shorter spelling collapses further than one kana:
    // `kyo` displays きょ, and no prefix of `kyo` displays き, so backspace
    // lands on `k`. Keeping き would mean rewriting the buffer to `ki`, i.e.
    // storing kana rather than what was typed — a larger change than this bug
    // asks for, and one that would make the composition disagree with the
    // keystrokes behind it.
    size_t RomajiLengthAfterBackspace(const std::wstring& romaji);
}
