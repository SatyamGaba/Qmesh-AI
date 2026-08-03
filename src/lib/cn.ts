type ClassValue = string | false | null | undefined;

/** Tiny classname joiner — no dependency needed for a prototype. */
export function cn(...values: ClassValue[]): string {
  return values.filter(Boolean).join(" ");
}
