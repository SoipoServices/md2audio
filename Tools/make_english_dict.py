#!/usr/bin/env python3
"""Builds Sources/MD2Audio/Resources/english.dict from the CMU Pronouncing Dictionary.

Each English word gets its pronunciation written with the sounds every voice has (the five vowels,
open e and o, and the common consonants), the way a speaker of Italian, Spanish or French says it:
"machine" -> maˈʃin, "deployment" -> diˈplɔiment. The app passes it to the voice as an SSML <phoneme>,
so English words are read by the same voice as the rest of the text.

    curl -LO https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict
    python3 Tools/make_english_dict.py cmudict.dict

Output: lines of "word<TAB>ipa", sorted, raw-deflate compressed.
"""
import re
import sys
import zlib
from pathlib import Path

CONSONANTS = {
    'B': 'b', 'CH': 'tʃ', 'D': 'd', 'DH': 'd', 'F': 'f', 'G': 'ɡ', 'HH': '', 'JH': 'dʒ', 'K': 'k', 'L': 'l',
    'M': 'm', 'N': 'n', 'NG': 'n', 'P': 'p', 'R': 'r', 'S': 's', 'SH': 'ʃ', 'T': 't', 'TH': 't', 'V': 'v',
    'W': 'w', 'Y': 'j', 'Z': 'z', 'ZH': 'ʒ',
}
VOWELS = {
    'AA': 'a', 'AE': 'ɛ', 'AH': 'a', 'AO': 'ɔ', 'AW': 'au', 'AY': 'ai', 'EH': 'ɛ', 'ER': 'er', 'EY': 'ei',
    'IH': 'i', 'IY': 'i', 'OW': 'o', 'OY': 'ɔi', 'UH': 'u', 'UW': 'u',
}
# Consonant pairs that start a syllable together
ONSETS = {('p', 'r'), ('p', 'l'), ('b', 'r'), ('b', 'l'), ('t', 'r'), ('d', 'r'), ('k', 'r'), ('k', 'l'),
          ('ɡ', 'r'), ('ɡ', 'l'), ('f', 'r'), ('f', 'l'), ('k', 'w'), ('t', 'w'), ('s', 'w'),
          ('s', 'p'), ('s', 't'), ('s', 'k'), ('s', 'm'), ('s', 'n'), ('s', 'l')}


def spelled_vowels(word):
    """The first letter of each group of vowel letters, when they line up with the spoken vowels."""
    groups = re.findall(r'[aeiouy]+', word)
    if len(groups) > 1 and re.search(r'[^aeiouy]e$', word):
        groups = groups[:-1]  # silent final e
    return [g[0] for g in groups]


def convert(word, phones, options):
    vowels = [p for p in phones if p[-1].isdigit()]
    letters = spelled_vowels(word)
    aligned = len(letters) == len(vowels)
    out = []       # (ipa, is_vowel, stressed)
    v = 0
    for i, phone in enumerate(phones):
        if not phone[-1].isdigit():
            ipa = CONSONANTS[phone]
            # A final -ng keeps its g: "meeting" -> mitinɡ
            if phone == 'NG' and options.get('ng', True) and (i + 1 == len(phones) or phones[i + 1] not in ('K', 'G')):
                ipa = 'nɡ'
            if ipa:
                out.append((ipa, False, False))
            continue
        base, stress = phone[:-1], phone[-1]
        letter = letters[v] if aligned else ''
        ipa = VOWELS[base]
        if base == 'AH' and stress == '0':
            # Schwa: the vowel it is written with
            ipa = {'a': 'a', 'e': 'e', 'i': 'i', 'o': 'o', 'u': 'a'}.get(letter, 'a' if i in (0, len(phones) - 1) else 'e')
        elif base == 'AA' and letter == 'o':
            ipa = 'ɔ'      # "podcast", "job": American a, but said as written
        elif base == 'ER':
            after_w = i > 0 and phones[i - 1] == 'W'
            ipa = 'ɔr' if after_w or letter == 'o' else 'ar' if letter == 'a' and stress == '0' else 'er'
        elif base == 'IH' and stress == '0' and letter == 'e' and i + 1 < len(phones):
            ipa = 'i'
        out.append((ipa, True, stress == '1'))
        v += 1

    # The stress mark goes before the consonants that start the stressed syllable
    count = sum(1 for _, is_vowel, _ in out if is_vowel)
    result = [ipa for ipa, _, _ in out]
    if count > 1 and options.get('stress', True):
        for i, (_, is_vowel, stressed) in enumerate(out):
            if not (is_vowel and stressed):
                continue
            start = i
            first_vowel = next(k for k, o in enumerate(out) if o[1])
            if i == first_vowel:
                start = 0
            elif i > 0 and not out[i - 1][1]:
                start = i - 1
                if start > 0 and not out[start - 1][1] and (out[start - 1][0], out[start][0]) in ONSETS:
                    start -= 1
                    if start > 0 and out[start - 1][0] == 's' and out[start][0] in 'ptk':
                        start -= 1
            result.insert(start, 'ˈ')
            break
    return ''.join(result)


def load(path):
    words = {}
    for line in open(path, encoding='utf-8'):
        parts = line.split('#')[0].split()
        if len(parts) < 2 or not re.fullmatch(r'[a-z]{2,}', parts[0]):
            continue  # skips alternatives "word(2)", apostrophes and abbreviations
        words[parts[0]] = parts[1:]
    return words


def main():
    words = load(sys.argv[1])
    lines = ''.join(f'{w}\t{convert(w, p, {})}\n' for w, p in sorted(words.items()))
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    data = deflate.compress(lines.encode('utf-8')) + deflate.flush()
    out = Path(__file__).resolve().parent.parent / 'Sources/MD2Audio/Resources/english.dict'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f'{len(words)} words, {len(data) // 1024} KB -> {out}')


if __name__ == '__main__':
    main()
