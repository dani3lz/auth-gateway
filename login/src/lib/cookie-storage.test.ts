import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { CookieStorage } from "./cookie-storage";

describe("CookieStorage", () => {
  beforeEach(() => {
    document.cookie.split(";").forEach((c) => {
      const eq = c.indexOf("=");
      const name = (eq > -1 ? c.slice(0, eq) : c).trim();
      document.cookie = `${name}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`;
    });
  });

  test("setItem writes a cookie scoped to the configured domain", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "v");
    expect(document.cookie).toContain("k=v");
  });

  test("getItem returns the previously set value", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "hello");
    expect(s.getItem("k")).toBe("hello");
  });

  test("removeItem clears the cookie", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "v");
    s.removeItem("k");
    expect(s.getItem("k")).toBeNull();
  });

  test("URL-encodes special characters", () => {
    const s = new CookieStorage({ domain: ".example.com", secure: false });
    s.setItem("k", "a b=c");
    expect(s.getItem("k")).toBe("a b=c");
  });
});
