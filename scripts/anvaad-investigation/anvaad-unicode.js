// VENDORED for reference only — DO NOT bundle, DO NOT execute.
//
// Source:   https://github.com/KhalisFoundation/anvaad-js
// File:     src/unicode.js (master @ 2026-06-23)
// License:  GPL-3.0 (per anvaad-js LICENSE.md)
// Purpose:  port reference for ios/GurbaniLensCore/Sources/GurbaniLensCore/AnmolLipi.swift
//
// Verbatim copy. The Swift port mirrors this file's structure 1:1 so
// reviewers can spot divergence at a glance.

const mapping = {
  a: 'ੳ',
  A: 'ਅ',
  s: 'ਸ',
  S: 'ਸ਼',
  d: 'ਦ',
  D: 'ਧ',
  f: 'ਡ',
  F: 'ਢ',
  g: 'ਗ',
  G: 'ਘ',
  h: 'ਹ',
  H: '੍ਹ',
  j: 'ਜ',
  J: 'ਝ',
  k: 'ਕ',
  K: 'ਖ',
  l: 'ਲ',
  L: 'ਲ਼',
  q: 'ਤ',
  Q: 'ਥ',
  w: 'ਾ',
  W: 'ਾਂ',
  e: 'ੲ',
  E: 'ਓ',
  r: 'ਰ',
  R: '੍ਰ',
  '®': '੍ਰ',
  t: 'ਟ',
  T: 'ਠ',
  y: 'ੇ',
  Y: 'ੈ',
  u: 'ੁ',
  ü: 'ੁ',
  U: 'ੂ',
  '¨': 'ੂ',
  i: 'ਿ',
  I: 'ੀ',
  o: 'ੋ',
  O: 'ੌ',
  p: 'ਪ',
  P: 'ਫ',
  z: 'ਜ਼',
  Z: 'ਗ਼',
  x: 'ਣ',
  X: 'ਯ',
  c: 'ਚ',
  C: 'ਛ',
  v: 'ਵ',
  V: 'ੜ',
  b: 'ਬ',
  B: 'ਭ',
  n: 'ਨ',
  ƒ: 'ਨੂੰ',
  N: 'ਂ',
  ˆ: 'ਂ',
  m: 'ਮ',
  M: 'ੰ',
  µ: 'ੰ',
  '`': 'ੱ',
  '~': 'ੱ',
  '¤': 'ੱ',
  Í: '੍ਵ',
  ç: '੍ਚ',
  '†': '੍ਟ',
  œ: '੍ਤ',
  '˜': '੍ਨ',
  '´': 'ੵ',
  Ï: 'ੵ',
  æ: '਼',
  Î: '੍ਯ',
  ì: 'ਯ',
  í: '੍ਯ',
  1: '੧',
  2: '੨',
  3: '੩',
  4: '੪',
  5: '੫',
  6: '੬',
  '^': 'ਖ਼',
  7: '੭',
  '&': 'ਫ਼',
  8: '੮',
  9: '੯',
  0: '੦',
  '\\': 'ਞ',
  '|': 'ਙ',
  '[': '।',
  ']': '॥',
  '<': 'ੴ',
  '¡': 'ੴ',
  Å: 'ੴ',
  Ú: 'ਃ',
  Ç: '☬',
  '@': 'ੑ',
  '‚': '❁',
  '•': '੶',
  ' ': ' ',
};

const asciiCorrections = [
  '@W',
  '@w',
  '@o',
  '@O',
  '@y',
  '@Y',
  '@ü',
  '@`',
  'ÍY',
  'Ry',
  'RY',
  'RM',
  'RN',
  'YN',
  'yN',
  'YM',
  'yM',
  'uN',
  'UN',
  'üN',
  'uM',
  'UM',
  'üM',
  'R`',
  'u`',
  'U`',
  'ü`',
  'Iˆ',
  'IN',
];

const halfChars = [
  'H',
  'R',
  '®',
  'Í',
  'ç',
  '†',
  'œ',
  '˜',
  '´',
  'Î',
  'Ï',
  'í',
  'æ',
];

function unicode(text = '', reverse = false, simplify = false) {
  if (text === '' || typeof text !== 'string') {
    return text;
  }

  if (reverse) {
    return ascii(text, simplify);
  }

  let convertedText = '';

  let str = text
    .replace(/>/gi, '')
    .replace(/Ø/gi, '')
    .replace(/Æ/g, '');

  asciiCorrections.forEach((e) => {
    str = str.replace(new RegExp(e.split('').reverse().join(''), 'g'), e);
  });

  const chars = str.split('');

  for (let j = 0; j < chars.length; j += 1) {
    const currentChar = chars[j];
    const nextChar = chars[j + 1];
    const nextNextChar = chars[j + 2];

    if (currentChar === 'i') {
      if (nextChar != null) {
        if (nextChar === 'e') {
          convertedText += 'ਇ';
        } else if (halfChars.includes(nextNextChar)) {
          convertedText += mapping[nextChar];
          convertedText += mapping[nextNextChar];
          convertedText += 'ਿ';
          j += 1;
        } else {
          convertedText += mapping[nextChar];
          convertedText += 'ਿ';
        }
        j += 1;
      } else {
        convertedText += mapping[currentChar];
      }
    } else if (currentChar === 'a') {
      switch (nextChar) {
        case 'u':
          convertedText += 'ਉ';
          j += 1;
          break;
        case 'U':
          convertedText += 'ਊ';
          j += 1;
          break;
        default:
          convertedText += mapping[currentChar];
      }
    } else if (currentChar === 'A') {
      switch (nextChar) {
        case 'w':
          convertedText += 'ਆ';
          j += 1;
          break;
        case 'W':
          convertedText += 'ਆਂ';
          j += 1;
          break;
        case 'Y':
          convertedText += 'ਐ';
          j += 1;
          break;
        case 'O':
          convertedText += 'ਔ';
          j += 1;
          break;
        default:
          convertedText += mapping[currentChar];
      }
    } else if (currentChar === 'e') {
      switch (nextChar) {
        case 'I':
          convertedText += 'ਈ';
          j += 1;
          break;
        case 'y':
          convertedText += 'ਏ';
          j += 1;
          break;
        default:
          convertedText += mapping[currentChar];
      }
    } else if (currentChar === '1' && nextChar === 'E' && nextNextChar === 'å') {
      convertedText += 'ੴ';
      j += 2;
    } else if (currentChar === 'u' && nextChar === 'o') {
      convertedText += 'ੋੁ';
      j += 1;
    } else if (simplify && nextChar === 'æ') {
      switch (currentChar) {
        case 's':
          convertedText += 'ਸ਼';
          j += 1;
          break;
        case 'j':
          convertedText += 'ਜ਼';
          j += 1;
          break;
        case 'K':
          convertedText += 'ਖ਼';
          j += 1;
          break;
        case 'g':
          convertedText += 'ਗ਼';
          j += 1;
          break;
        case 'P':
          convertedText += 'ਫ਼';
          j += 1;
          break;
        case 'l':
          convertedText += 'ਲ਼';
          j += 1;
          break;
        default:
          convertedText += mapping[currentChar];
      }
    } else {
      convertedText += mapping[currentChar] || currentChar;
    }
  }

  return convertedText;
}

module.exports = unicode;
