// See RomajiKana.h.

#include "RomajiKana.h"

#include <cwctype>

namespace Ohagey
{
    namespace
    {
        struct Rule
        {
            const wchar_t* romaji;
            const wchar_t* kana;
        };

        // Longest entries are tried first, so `kya` wins over `ka` and `ki`.
        // Several spellings map to the same kana on purpose: people type `si`
        // and `shi`, `tu` and `tsu`, `zi` and `ji`, and an IME that only
        // accepted one of each would feel broken.
        const Rule kRules[] =
        {
            // ── youon and other three-letter forms ──────────────────────────
            {L"kya", L"きゃ"}, {L"kyi", L"きぃ"}, {L"kyu", L"きゅ"}, {L"kye", L"きぇ"}, {L"kyo", L"きょ"},
            {L"gya", L"ぎゃ"}, {L"gyi", L"ぎぃ"}, {L"gyu", L"ぎゅ"}, {L"gye", L"ぎぇ"}, {L"gyo", L"ぎょ"},
            {L"sha", L"しゃ"}, {L"shu", L"しゅ"}, {L"she", L"しぇ"}, {L"sho", L"しょ"}, {L"shi", L"し"},
            {L"sya", L"しゃ"}, {L"syi", L"しぃ"}, {L"syu", L"しゅ"}, {L"sye", L"しぇ"}, {L"syo", L"しょ"},
            {L"ja",  L"じゃ"}, {L"ju",  L"じゅ"}, {L"je",  L"じぇ"}, {L"jo",  L"じょ"}, {L"ji",  L"じ"},
            {L"jya", L"じゃ"}, {L"jyi", L"じぃ"}, {L"jyu", L"じゅ"}, {L"jye", L"じぇ"}, {L"jyo", L"じょ"},
            {L"zya", L"じゃ"}, {L"zyi", L"じぃ"}, {L"zyu", L"じゅ"}, {L"zye", L"じぇ"}, {L"zyo", L"じょ"},
            {L"cha", L"ちゃ"}, {L"chu", L"ちゅ"}, {L"che", L"ちぇ"}, {L"cho", L"ちょ"}, {L"chi", L"ち"},
            {L"cya", L"ちゃ"}, {L"cyi", L"ちぃ"}, {L"cyu", L"ちゅ"}, {L"cye", L"ちぇ"}, {L"cyo", L"ちょ"},
            {L"tya", L"ちゃ"}, {L"tyi", L"ちぃ"}, {L"tyu", L"ちゅ"}, {L"tye", L"ちぇ"}, {L"tyo", L"ちょ"},
            {L"tsu", L"つ"},
            {L"dya", L"ぢゃ"}, {L"dyi", L"ぢぃ"}, {L"dyu", L"ぢゅ"}, {L"dye", L"ぢぇ"}, {L"dyo", L"ぢょ"},
            {L"nya", L"にゃ"}, {L"nyi", L"にぃ"}, {L"nyu", L"にゅ"}, {L"nye", L"にぇ"}, {L"nyo", L"にょ"},
            {L"hya", L"ひゃ"}, {L"hyi", L"ひぃ"}, {L"hyu", L"ひゅ"}, {L"hye", L"ひぇ"}, {L"hyo", L"ひょ"},
            {L"bya", L"びゃ"}, {L"byi", L"びぃ"}, {L"byu", L"びゅ"}, {L"bye", L"びぇ"}, {L"byo", L"びょ"},
            {L"pya", L"ぴゃ"}, {L"pyi", L"ぴぃ"}, {L"pyu", L"ぴゅ"}, {L"pye", L"ぴぇ"}, {L"pyo", L"ぴょ"},
            {L"mya", L"みゃ"}, {L"myi", L"みぃ"}, {L"myu", L"みゅ"}, {L"mye", L"みぇ"}, {L"myo", L"みょ"},
            {L"rya", L"りゃ"}, {L"ryi", L"りぃ"}, {L"ryu", L"りゅ"}, {L"rye", L"りぇ"}, {L"ryo", L"りょ"},
            {L"fya", L"ふゃ"}, {L"fyu", L"ふゅ"}, {L"fyo", L"ふょ"},
            {L"vya", L"ゔゃ"}, {L"vyu", L"ゔゅ"}, {L"vyo", L"ゔょ"},

            // ── small kana ─────────────────────────────────────────────────
            {L"xya", L"ゃ"}, {L"xyu", L"ゅ"}, {L"xyo", L"ょ"},
            {L"lya", L"ゃ"}, {L"lyu", L"ゅ"}, {L"lyo", L"ょ"},
            {L"xtsu", L"っ"}, {L"ltsu", L"っ"}, {L"xtu", L"っ"}, {L"ltu", L"っ"},
            {L"xwa", L"ゎ"}, {L"lwa", L"ゎ"},
            {L"xa", L"ぁ"}, {L"xi", L"ぃ"}, {L"xu", L"ぅ"}, {L"xe", L"ぇ"}, {L"xo", L"ぉ"},
            {L"la", L"ぁ"}, {L"li", L"ぃ"}, {L"lu", L"ぅ"}, {L"le", L"ぇ"}, {L"lo", L"ぉ"},

            // ── two-letter forms ───────────────────────────────────────────
            {L"ka", L"か"}, {L"ki", L"き"}, {L"ku", L"く"}, {L"ke", L"け"}, {L"ko", L"こ"},
            {L"ga", L"が"}, {L"gi", L"ぎ"}, {L"gu", L"ぐ"}, {L"ge", L"げ"}, {L"go", L"ご"},
            {L"sa", L"さ"}, {L"si", L"し"}, {L"su", L"す"}, {L"se", L"せ"}, {L"so", L"そ"},
            {L"za", L"ざ"}, {L"zi", L"じ"}, {L"zu", L"ず"}, {L"ze", L"ぜ"}, {L"zo", L"ぞ"},
            {L"ta", L"た"}, {L"ti", L"ち"}, {L"tu", L"つ"}, {L"te", L"て"}, {L"to", L"と"},
            {L"da", L"だ"}, {L"di", L"ぢ"}, {L"du", L"づ"}, {L"de", L"で"}, {L"do", L"ど"},
            {L"na", L"な"}, {L"ni", L"に"}, {L"nu", L"ぬ"}, {L"ne", L"ね"}, {L"no", L"の"},
            {L"ha", L"は"}, {L"hi", L"ひ"}, {L"hu", L"ふ"}, {L"he", L"へ"}, {L"ho", L"ほ"},
            {L"ba", L"ば"}, {L"bi", L"び"}, {L"bu", L"ぶ"}, {L"be", L"べ"}, {L"bo", L"ぼ"},
            {L"pa", L"ぱ"}, {L"pi", L"ぴ"}, {L"pu", L"ぷ"}, {L"pe", L"ぺ"}, {L"po", L"ぽ"},
            {L"fa", L"ふぁ"}, {L"fi", L"ふぃ"}, {L"fu", L"ふ"}, {L"fe", L"ふぇ"}, {L"fo", L"ふぉ"},
            {L"ma", L"ま"}, {L"mi", L"み"}, {L"mu", L"む"}, {L"me", L"め"}, {L"mo", L"も"},
            {L"ya", L"や"}, {L"yu", L"ゆ"}, {L"yo", L"よ"}, {L"yi", L"い"}, {L"ye", L"いぇ"},
            {L"ra", L"ら"}, {L"ri", L"り"}, {L"ru", L"る"}, {L"re", L"れ"}, {L"ro", L"ろ"},
            {L"wa", L"わ"}, {L"wo", L"を"}, {L"wi", L"うぃ"}, {L"we", L"うぇ"}, {L"wu", L"う"},
            {L"va", L"ゔぁ"}, {L"vi", L"ゔぃ"}, {L"vu", L"ゔ"}, {L"ve", L"ゔぇ"}, {L"vo", L"ゔぉ"},

            // ── single letters ─────────────────────────────────────────────
            {L"a", L"あ"}, {L"i", L"い"}, {L"u", L"う"}, {L"e", L"え"}, {L"o", L"お"},
            {L"-", L"ー"}, {L",", L"、"}, {L".", L"。"}, {L"/", L"・"},
            {L"[", L"「"}, {L"]", L"」"},
        };

        const size_t kRuleCount = sizeof(kRules) / sizeof(kRules[0]);

        // Longest romaji in the table, so the prefix search knows when to stop.
        const size_t kMaxRuleLength = 4;   // "xtsu"

        bool IsVowel(wchar_t ch)
        {
            return ch == L'a' || ch == L'i' || ch == L'u' || ch == L'e' || ch == L'o';
        }

        // A consonant that doubles into っ. `n` is excluded: `nn` is ん, not っn.
        bool DoublesToSokuon(wchar_t ch)
        {
            return ch >= L'a' && ch <= L'z' && !IsVowel(ch) && ch != L'n';
        }

        const wchar_t* Lookup(const std::wstring& romaji)
        {
            for (size_t i = 0; i < kRuleCount; ++i)
            {
                if (romaji == kRules[i].romaji) return kRules[i].kana;
            }
            return nullptr;
        }

        // True when `romaji` could still grow into a rule. `ky` is a prefix of
        // `kya`; `qz` is a prefix of nothing and should not be held on to.
        bool IsPrefixOfRule(const std::wstring& romaji)
        {
            if (romaji.size() >= kMaxRuleLength) return false;
            for (size_t i = 0; i < kRuleCount; ++i)
            {
                const std::wstring rule(kRules[i].romaji);
                if (rule.size() > romaji.size() && rule.compare(0, romaji.size(), romaji) == 0)
                {
                    return true;
                }
            }
            return false;
        }

        bool IsAccepted(wchar_t ch)
        {
            if (ch >= L'a' && ch <= L'z') return true;
            if (ch >= L'A' && ch <= L'Z') return true;
            return ch == L'-' || ch == L',' || ch == L'.' || ch == L'/'
                || ch == L'[' || ch == L']' || ch == L'\'';
        }
    }

    bool RomajiKana::Append(wchar_t ch)
    {
        if (!IsAccepted(ch)) return false;

        // Kana input is case-insensitive; upper case is how people type the
        // start of a sentence, not a different sound.
        if (ch >= L'A' && ch <= L'Z')
        {
            ch = static_cast<wchar_t>(ch - L'A' + L'a');
        }

        _romaji.push_back(ch);
        Rebuild();
        return true;
    }

    void RomajiKana::Backspace()
    {
        if (_romaji.empty()) return;
        _romaji.pop_back();
        Rebuild();
    }

    void RomajiKana::Clear()
    {
        _romaji.clear();
        _kana.clear();
        _pending.clear();
    }

    std::wstring RomajiKana::Reading() const
    {
        if (_pending == L"n") return _kana + L"ん";
        return _kana;
    }

    std::wstring RomajiKana::Display() const
    {
        if (_pending == L"n") return _kana + L"ん";
        return _kana + _pending;
    }

    void RomajiKana::Rebuild()
    {
        _kana.clear();
        _pending.clear();

        // Scans the whole romaji with an index rather than resolving each
        // keystroke as it arrives. The difference matters for `n`, which cannot
        // be decided without seeing what comes after it — see the `nn` case.
        const size_t size = _romaji.size();
        size_t i = 0;

        while (i < size)
        {
            // ── ん ──────────────────────────────────────────────────────────
            if (_romaji[i] == L'n' && i + 1 < size)
            {
                const wchar_t next = _romaji[i + 1];

                if (next == L'n')
                {
                    // `nn` usually spells ん and consumes both letters. But if a
                    // vowel or `y` follows, the second `n` is the start of the
                    // next syllable: someone typing `sannin` means さんにん,
                    // and consuming both here would give さんいん.
                    const bool secondStartsSyllable =
                        i + 2 < size && (IsVowel(_romaji[i + 2]) || _romaji[i + 2] == L'y');
                    _kana += L"ん";
                    i += secondStartsSyllable ? 1 : 2;
                    continue;
                }
                if (next == L'\'')
                {
                    // The apostrophe exists only to end the syllable.
                    _kana += L"ん";
                    i += 2;
                    continue;
                }
                if (!IsVowel(next) && next != L'y')
                {
                    // A consonant that cannot continue `n` closes it.
                    _kana += L"ん";
                    i += 1;
                    continue;
                }
                // Otherwise `n` still belongs to な行 or にゃ行; fall through.
            }

            // ── っ ──────────────────────────────────────────────────────────
            if (i + 1 < size && _romaji[i] == _romaji[i + 1] && DoublesToSokuon(_romaji[i]))
            {
                _kana += L"っ";
                i += 1;
                continue;
            }

            // ── longest match ───────────────────────────────────────────────
            bool matched = false;
            size_t maxLength = size - i;
            if (maxLength > kMaxRuleLength) maxLength = kMaxRuleLength;
            for (size_t length = maxLength; length >= 1; --length)
            {
                if (const wchar_t* kana = Lookup(_romaji.substr(i, length)))
                {
                    _kana += kana;
                    i += length;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;

            // Nothing matched. If what is left could still grow into a rule it
            // is the user mid-syllable; otherwise it is a stray keystroke that
            // must not poison everything typed after it.
            const std::wstring tail = _romaji.substr(i);
            if (IsPrefixOfRule(tail))
            {
                _pending = tail;
                return;
            }
            i += 1;
        }
    }

    namespace
    {
        RomajiKana Feed(const std::wstring& romaji)
        {
            RomajiKana converter;
            for (size_t i = 0; i < romaji.size(); ++i)
            {
                converter.Append(romaji[i]);
            }
            return converter;
        }
    }

    std::wstring RomajiToKana(const std::wstring& romaji)
    {
        return Feed(romaji).Reading();
    }

    std::wstring RomajiToDisplay(const std::wstring& romaji)
    {
        return Feed(romaji).Display();
    }
}

namespace
{
    // Where the unresolved romaji starts: the trailing run of ASCII. Kana are
    // not ASCII, so the split needs no extra state to be kept in step.
    size_t PendingStart(const std::wstring& buffer)
    {
        size_t i = buffer.size();
        while (i > 0 && buffer[i - 1] < 0x80)
        {
            --i;
        }
        return i;
    }
}

std::wstring Ohagey::BufferAfterKeystroke(const std::wstring& buffer, wchar_t ch)
{
    const size_t split = PendingStart(buffer);
    const std::wstring settled = buffer.substr(0, split);
    const std::wstring pending = buffer.substr(split);

    // Replayed rather than appended to: `t` + `t` becomes っt, and only the
    // converter knows that. Feeding it the whole unresolved tail each time
    // keeps that knowledge in one place.
    RomajiKana converter;
    bool accepted = true;
    for (wchar_t c : pending + std::wstring(1, ch))
    {
        if (!converter.Append(c)) { accepted = false; }
    }
    if (!accepted)
    {
        // Something the converter will not take. Left as it came so the caller
        // sees the keystroke rather than losing it silently.
        return buffer + std::wstring(1, ch);
    }

    return settled + converter.Kana() + converter.Pending();
}

std::wstring Ohagey::BufferDisplay(const std::wstring& buffer)
{
    const size_t split = PendingStart(buffer);
    return buffer.substr(0, split) + RomajiToDisplay(buffer.substr(split));
}

std::wstring Ohagey::BufferReading(const std::wstring& buffer)
{
    const size_t split = PendingStart(buffer);
    return buffer.substr(0, split) + RomajiToKana(buffer.substr(split));
}
