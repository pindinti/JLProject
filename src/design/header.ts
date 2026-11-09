import { messages } from "../locales/pt-BR";

export type GreetingPeriod = "morning" | "afternoon" | "evening";

export function getFirstName(name?: string | null, email?: string | null): string {
  const displayName = name?.trim();
  if (displayName) return displayName.split(/\s+/)[0];

  const emailName = email?.trim().split("@")[0];
  return emailName || messages.greetingFallbackName;
}

export function getGreetingPeriod(date: Date): GreetingPeriod {
  const hour = Number(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo",
    hour: "2-digit",
    hourCycle: "h23"
  }).format(date));

  if (hour < 12) return "morning";
  if (hour < 18) return "afternoon";
  return "evening";
}

export function getGreeting(firstName: string, date: Date): string {
  switch (getGreetingPeriod(date)) {
    case "morning":
      return messages.greetingMorning(firstName);
    case "afternoon":
      return messages.greetingAfternoon(firstName);
    case "evening":
      return messages.greetingEvening(firstName);
  }
}
