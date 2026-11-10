const productionAuthBaseUrl =
  "https://ep-tiny-union-b6r07ej7.neonauth.c-2.sa-east-1.aws.neon.tech/neondb/auth";

export function validateProductionAuthUrl(value: string | undefined): string {
  if (value !== productionAuthBaseUrl) {
    throw new Error("VITE_NEON_AUTH_URL must match the verified production Neon Auth endpoint.");
  }
  return value;
}
