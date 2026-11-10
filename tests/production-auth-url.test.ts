import { describe, expect, it } from "vitest";
import { validateProductionAuthUrl } from "../scripts/production-auth-url";

const productionUrl =
  "https://ep-tiny-union-b6r07ej7.neonauth.c-2.sa-east-1.aws.neon.tech/neondb/auth";

describe("production Auth URL validation", () => {
  it("accepts the verified production branch endpoint", () => {
    expect(validateProductionAuthUrl(productionUrl)).toBe(productionUrl);
  });

  it("rejects a URL contaminated by bundled JavaScript", () => {
    expect(() => validateProductionAuthUrl(
      `${productionUrl}\`,{adapter:Wf({fetchOptions:{credentials:\`include\`}})});async`
    )).toThrow(/VITE_NEON_AUTH_URL/);
  });

  it("rejects missing and development endpoints", () => {
    expect(() => validateProductionAuthUrl(undefined)).toThrow(/VITE_NEON_AUTH_URL/);
    expect(() => validateProductionAuthUrl(
      "https://ep-purple-breeze-b6mspyc3.neonauth.c-2.sa-east-1.aws.neon.tech/neondb/auth"
    )).toThrow(/VITE_NEON_AUTH_URL/);
  });
});
