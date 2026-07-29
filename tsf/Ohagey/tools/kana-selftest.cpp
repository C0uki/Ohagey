// Tests for romaji -> kana conversion.
//
// Unlike the engine round trip, this needs nothing running: the converter is
// deliberately free of Windows and TSF. The cases below are the ones where a
// romaji IME actually goes wrong — sokuon, a trailing n, the several spellings
// of the same kana, and backspacing into a half-typed syllable.
//
// Build and run: tsf/Ohagey/tools/build-and-run-kana.ps1

#include "../RomajiKana.h"

#include <windows.h>
#include <cstdio>
#include <string>

using namespace Ohagey;

namespace
{
    int g_failures = 0;

    std::string Utf8(const std::wstring& value)
    {
        if (value.empty()) return std::string();
        const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                                             nullptr, 0, nullptr, nullptr);
        if (size <= 0) return std::string();
        std::string utf8(static_cast<size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                            &utf8[0], size, nullptr, nullptr);
        return utf8;
    }

    void ExpectReading(const wchar_t* romaji, const wchar_t* expected)
    {
        const std::wstring got = RomajiToKana(romaji);
        const bool ok = (got == expected);
        if (!ok) ++g_failures;
        printf("  [%s] %-12s -> %-14s%s\n", ok ? "PASS" : "FAIL",
               Utf8(romaji).c_str(), Utf8(got).c_str(),
               ok ? "" : ("  expected " + Utf8(expected)).c_str());
    }

    void Expect(bool ok, const char* what)
    {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++g_failures;
    }
}

int main()
{
    SetConsoleOutputCP(CP_UTF8);

    printf("basic\n");
    ExpectReading(L"aiueo", L"あいうえお");
    ExpectReading(L"kakikukeko", L"かきくけこ");
    ExpectReading(L"henkan", L"へんかん");
    ExpectReading(L"nihongo", L"にほんご");

    printf("\nspellings that must agree\n");
    ExpectReading(L"si", L"し");
    ExpectReading(L"shi", L"し");
    ExpectReading(L"ti", L"ち");
    ExpectReading(L"chi", L"ち");
    ExpectReading(L"tu", L"つ");
    ExpectReading(L"tsu", L"つ");
    ExpectReading(L"hu", L"ふ");
    ExpectReading(L"fu", L"ふ");
    ExpectReading(L"zi", L"じ");
    ExpectReading(L"ji", L"じ");

    printf("\nyouon\n");
    ExpectReading(L"kyo", L"きょ");
    ExpectReading(L"sha", L"しゃ");
    ExpectReading(L"sya", L"しゃ");
    ExpectReading(L"ja", L"じゃ");
    ExpectReading(L"jya", L"じゃ");
    ExpectReading(L"zya", L"じゃ");
    ExpectReading(L"cha", L"ちゃ");
    ExpectReading(L"ryuu", L"りゅう");

    printf("\nsokuon\n");
    ExpectReading(L"kka", L"っか");
    ExpectReading(L"itte", L"いって");
    ExpectReading(L"gakkou", L"がっこう");
    ExpectReading(L"issho", L"いっしょ");
    ExpectReading(L"xtu", L"っ");
    ExpectReading(L"ltu", L"っ");

    printf("\nthe letter n\n");
    // A lone n is ん once nothing can continue the syllable.
    ExpectReading(L"n", L"ん");
    ExpectReading(L"nn", L"ん");
    ExpectReading(L"hon", L"ほん");
    ExpectReading(L"honn", L"ほん");
    ExpectReading(L"n'", L"ん");
    // ...but it must not swallow a following vowel or y.
    ExpectReading(L"na", L"な");
    ExpectReading(L"nya", L"にゃ");
    ExpectReading(L"hona", L"ほな");
    ExpectReading(L"honya", L"ほにゃ");
    // n before a consonant closes the syllable.
    ExpectReading(L"nka", L"んか");
    ExpectReading(L"sannin", L"さんにん");
    ExpectReading(L"kanji", L"かんじ");

    printf("\nsmall kana and punctuation\n");
    ExpectReading(L"xya", L"ゃ");
    ExpectReading(L"la", L"ぁ");
    ExpectReading(L"ra-men", L"らーめん");
    ExpectReading(L"aa.", L"ああ。");

    printf("\ncase\n");
    ExpectReading(L"KA", L"か");
    ExpectReading(L"Henkan", L"へんかん");

    printf("\npending state\n");
    {
        RomajiKana c;
        c.Append(L'k');
        Expect(c.Kana().empty(), "k alone produces no kana");
        Expect(c.Pending() == L"k", "k is held as pending");
        Expect(c.Display() == L"k", "display shows the unresolved romaji");
        Expect(c.Reading().empty(), "an unresolved consonant is not sent as a reading");

        c.Append(L'y');
        Expect(c.Pending() == L"ky", "ky is still pending");
        c.Append(L'o');
        Expect(c.Kana() == L"きょ", "kyo resolves");
        Expect(c.Pending().empty(), "nothing left pending");
    }

    printf("\nbackspace\n");
    {
        RomajiKana c;
        for (const wchar_t* p = L"kyo"; *p; ++p) c.Append(*p);
        Expect(c.Kana() == L"きょ", "kyo -> きょ");
        // Backspace steps through the romaji, not the kana: someone editing
        // `kyo` expects to get back to `ky`, not to lose the syllable.
        c.Backspace();
        Expect(c.Kana().empty() && c.Pending() == L"ky", "backspace returns to ky");
        c.Append(L'a');
        Expect(c.Kana() == L"きゃ", "and kya can be typed instead");
    }
    {
        RomajiKana c;
        for (const wchar_t* p = L"honn"; *p; ++p) c.Append(*p);
        Expect(c.Reading() == L"ほん", "honn -> ほん");
        c.Backspace();
        Expect(c.Reading() == L"ほん", "hon still reads ほん");
        c.Backspace();
        Expect(c.Reading() == L"ほ", "ho -> ほ");
    }

    printf("\nstray input\n");
    {
        // A letter that cannot start a syllable must not poison what follows.
        ExpectReading(L"qka", L"か");
        RomajiKana c;
        Expect(!c.Append(L'1'), "digits are rejected outright");
        Expect(c.IsEmpty(), "and consume nothing");
    }

    printf("\n%s (%d failure%s)\n", g_failures == 0 ? "ALL PASSED" : "FAILED",
           g_failures, g_failures == 1 ? "" : "s");
    return g_failures == 0 ? 0 : 1;
}
