/**
 * ============================================================================
 *  PII DETECTOR — regex + heuristics, fully on-device
 * ============================================================================
 * Auto-privacy needs a verdict on the newest user message *before* any bytes
 * leave the phone, so this runs synchronously in the send path: no model, no
 * network, no dependencies. It targets *structured* PII — the kinds a pattern
 * can catch. Bare names, diagnoses, and other free-text PII are out of scope
 * until an on-device NER model is wired in (see extended_ideas.md).
 *
 * Bias: over-triggering routes a harmless message to the private engine
 * (slower, still correct); under-triggering leaks PII to Remote. When a rule
 * has to choose, it errs toward matching.
 */

export type PiiKind =
  | "email"
  | "phone"
  | "card"
  | "ssn"
  | "iban"
  | "dob"
  | "address";

export interface PiiMatch {
  kind: PiiKind;
  /** The matched text, for debugging/console — never persisted or displayed. */
  value: string;
}

/** Human labels for the banner/toast, article included ("an email address"). */
export const PII_LABELS: Record<PiiKind, string> = {
  email: "an email address",
  phone: "a phone number",
  card: "a card number",
  ssn: "an SSN",
  iban: "an IBAN",
  dob: "a date of birth",
  address: "a street address",
};

/** Luhn checksum — filters card candidates so most random digit runs pass by. */
function luhnValid(digits: string): boolean {
  let sum = 0;
  let dbl = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 === 0;
}

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;

// Phone shapes are matched conservatively enough to skip years ("2024-2025"),
// versions ("1.2.3") and IPs (192.168.1.50 has no 3-3-4 grouping), while still
// catching the ways people actually type numbers in chat.
const PHONE_RES = [
  /\+\d[\d\s().-]{7,17}\d/g, // +1 408 555 1234 / +44 20 7946 0958
  /\(\d{3}\)[\s.-]?\d{3}[\s.-]?\d{4}/g, // (408) 555-1234
  /\b\d{3}[\s.-]\d{3}[\s.-]\d{4}\b/g, // 408-555-1234 / 408.555.1234
  /\b\d{10,11}\b/g, // 4085551234 — bare runs this long are usually a number
];

// 13–19 digits with optional space/dash separators, then Luhn-verified.
const CARD_RE = /\b(?:\d[ -]?){12,18}\d\b/g;

const SSN_RE = /\b\d{3}-\d{2}-\d{4}\b/g;

// Country code + 2 check digits + 10..30 alphanumerics (compact or 4-grouped).
const IBAN_RE = /\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b/g;

// Dates alone are everywhere in normal chat, so DOB requires a birth-context
// keyword right before the date.
const DATE_PART =
  String.raw`(?:\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4}` +
  String.raw`|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{2,4}` +
  String.raw`|\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+\d{2,4})`;
const DOB_RE = new RegExp(
  String.raw`\b(?:dob|date\s+of\s+birth|born(?:\s+on)?|birth\s?day|birthdate)\b[\s:,-]{0,8}${DATE_PART}`,
  "gi",
);

// House number + 1–4 words + a street suffix. Occasionally catches phrases
// like "1 great way" — an acceptable over-trigger (see file header).
const ADDRESS_RE =
  /\b\d{1,6}\s+(?:[A-Za-z][A-Za-z'.-]*\s+){1,4}(?:st|street|ave|avenue|rd|road|blvd|boulevard|ln|lane|dr|drive|ct|court|way|pl|place|ter|terrace|cir|circle|pkwy|parkway|hwy|highway)\b/gi;

function collect(
  out: PiiMatch[],
  text: string,
  kind: PiiKind,
  re: RegExp,
  accept?: (match: string) => boolean,
): void {
  re.lastIndex = 0; // shared global regexes keep state between calls
  for (const m of text.matchAll(re)) {
    if (!accept || accept(m[0])) out.push({ kind, value: m[0] });
  }
}

/** Scan one message's text. Returns every hit, deduped by kind+value. */
export function detectPii(text: string): PiiMatch[] {
  if (!text || !text.trim()) return [];

  const out: PiiMatch[] = [];
  collect(out, text, "email", EMAIL_RE);
  for (const re of PHONE_RES) {
    collect(out, text, "phone", re, (m) => {
      const digits = m.replace(/\D/g, "");
      return digits.length >= 7 && digits.length <= 15;
    });
  }
  collect(out, text, "card", CARD_RE, (m) => {
    const digits = m.replace(/\D/g, "");
    return digits.length >= 13 && digits.length <= 19 && luhnValid(digits);
  });
  collect(out, text, "ssn", SSN_RE);
  collect(out, text, "iban", IBAN_RE);
  collect(out, text, "dob", DOB_RE);
  collect(out, text, "address", ADDRESS_RE);

  const seen = new Set<string>();
  return out.filter((m) => {
    const key = `${m.kind}:${m.value}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** "an email address", "an email address and a card number", … for UI copy. */
export function describePii(matches: PiiMatch[]): string {
  const labels = [...new Set(matches.map((m) => PII_LABELS[m.kind]))];
  if (labels.length <= 1) return labels[0] ?? "";
  return `${labels.slice(0, -1).join(", ")} and ${labels[labels.length - 1]}`;
}

/** Unique labels, for persisting on the thread that got pinned. */
export function piiLabels(matches: PiiMatch[]): string[] {
  return [...new Set(matches.map((m) => PII_LABELS[m.kind]))];
}
